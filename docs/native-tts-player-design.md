# Design: Native TTS ebook player (with Android Auto support)

Status: design for discussion · Builds on: WebView read aloud in the reader (`mixins/ttsPlayer.js`)

## 1. Motivation

The current read aloud (v1) runs in the WebView: the reader's JavaScript
extracts the text and calls the native `@capacitor-community/text-to-speech`
plugin sentence by sentence. The speaking itself is native, but **the control
loop lives in JS**, which means:

- **Screen off / background:** iOS suspends the WKWebView once the phone is
  locked — reading stops after the current sentence. The Android WebView
  usually keeps running, but without a foreground service the system can
  suspend it at any time (Doze, battery optimisation).
- **No media session:** read aloud has no notification with controls, does
  not react to Bluetooth buttons and does not exist for Android Auto or
  CarPlay.
- **No book selection in the car:** the Android Auto browse tree
  (`BrowseTree.kt`) only knows audio items.

Goal of v2: move the TTS control loop into the native layer as a full
"player" living in the same infrastructure as the audiobook player.

## 2. What the app already has (what we build on)

| Component | File | Role |
| --- | --- | --- |
| `PlayerNotificationService` | `android/.../player/PlayerNotificationService.kt` | `MediaBrowserServiceCompat`: ExoPlayer/Cast, MediaSession, notification, audio focus, Android Auto root |
| `BrowseTree` + `MediaManager` | `android/.../player/BrowseTree.kt`, `android/.../media/MediaManager.kt` | content for Android Auto (libraries, continue listening, …) |
| `MediaProgressSyncer` | `android/.../media/MediaProgressSyncer.kt` | saving/syncing progress to the server |
| `AbsAudioPlayer` | `android/.../plugins/AbsAudioPlayer.kt`, `ios/App/Shared/plugins/AbsAudioPlayer.swift` | Capacitor bridge WebView ↔ native player |
| `AudioPlayer` (iOS) | `ios/App/Shared/player/AudioPlayer.swift` | AVPlayer, `MPNowPlayingInfoCenter`, remote commands, background audio (`UIBackgroundModes: audio` is already in Info.plist) |
| TTS mixin (v1) | `mixins/ttsPlayer.js` | text extraction from EPUB/MOBI/PDF, chunking by sentences |

Key observation: **text extraction already works in JS** (epub.js, mobi
parser, pdf.js) and rewriting it natively for three formats makes no sense.
The native layer therefore receives already structured text.

## 3. Target architecture

```
┌────────────────────────── WebView (Nuxt) ──────────────────────────┐
│ reader (EpubReader/MobiReader/PdfReader)                           │
│   └─ text extraction (existing mixin hooks)                        │
│        └─ TTSBook payload ────────────┐                            │
│ reader UI listens to events (onParagraph, onStateChange)           │
└───────────────────────────────────────┼────────────────────────────┘
                                        ▼
                          Capacitor plugin AbsTTSPlayer
                                        │
        ┌───────────────────────────────┴───────────────────────────┐
        ▼                                                           ▼
  Android: TTS playback engine                          iOS: TTS playback engine
  in PlayerNotificationService                          in the AudioPlayer layer
  - android.speech.tts.TextToSpeech                     - AVSpeechSynthesizer
  - MediaSession (play/pause/seek/rate)                 - MPNowPlayingInfoCenter
  - foreground notification                             - MPRemoteCommandCenter
  - audio focus (shared with ExoPlayer)                 - AVAudioSession (playback)
  - Android Auto: BrowseTree category                   - CarPlay later
  - TTSBook cache on disk (JSON)                        - TTSBook cache on disk
  - MediaProgressSyncer (progress to server)            - progress sync (existing path)
```

### 3.1 Data model `TTSBook`

A single payload passed from JS to the native layer and cached on disk (JSON
in app storage, e.g. `tts-cache/<libraryItemId>.json`):

```ts
interface TTSBook {
  libraryItemId: string        // server or local id
  serverAddress?: string
  title: string
  author: string
  coverPath?: string           // local path/URL of the cover
  language: string             // default read aloud language ('cs-CZ' | 'en-US' | …)
  ebookFormat: 'epub' | 'mobi' | 'pdf'
  chapters: TTSChapter[]
  totalChars: number           // for the estimated "length" and percentage
  pageStep?: number            // pages per next/prev skip (reader setting, default 3)
  pageChars?: number           // estimated characters per displayed page from the reader (0 = unknown)
}

interface TTSChapter {
  title: string
  startLocation: string        // epub spine href / pdf page / mobi anchor
  startCfi?: string            // chapter start as an epub cfi – fallback position for the reader
  paragraphs: TTSParagraph[]
}

interface TTSParagraph {
  text: string
  location?: string            // cfi / page number – for progress and follow-along
  chars: number
}
```

- Chunking by sentences (today `splitTextChunks`) moves to the native layer —
  a Kotlin/Swift version of the same algorithm; JS sends whole paragraphs.
- The "time" in the media session is estimated from the character count and
  the rate (heuristic ~15 characters/s at 1.0×). It does not have to be exact
  — it serves the progress bar in the notification/car and relative seeking.

### 3.2 Capacitor plugin `AbsTTSPlayer`

```ts
interface AbsTTSPlayerPlugin {
  // preparation: stores the TTSBook in the cache and prepares the session (without starting)
  prepareBook(book: TTSBook): Promise<void>
  // starts/resumes read aloud from a position
  play(options?: { libraryItemId?: string, chapterIndex?: number, paragraphIndex?: number }): Promise<void>
  pause(): Promise<void>
  stop(): Promise<void>       // ends the session, dismisses the notification
  seekTo(options: { chapterIndex: number, paragraphIndex: number }): Promise<void>
  nextChapter(): Promise<void>
  prevChapter(): Promise<void>
  // skip by pageStep pages (delta -1 back / 1 forward), see A.3
  seekPages(options: { delta: number }): Promise<void>
  setPageStep(options: { pageStep: number, pageChars: number }): Promise<void>
  setRate(options: { rate: number }): Promise<void>
  setLanguage(options: { lang: string }): Promise<void>
  getState(): Promise<TTSPlayerState>
  removeCachedBook(options: { libraryItemId: string }): Promise<void>
  listCachedBooks(): Promise<{ books: TTSBookSummary[] }>

  // events to the WebView
  addListener(event: 'onParagraph', cb: (p: { chapterIndex: number, paragraphIndex: number, location?: string }) => void)
  addListener(event: 'onStateChange', cb: (s: TTSPlayerState) => void)
}
```

Behaviour of the WebView reader:

- An open reader listens to `onParagraph` → follow-along (page turn / scroll)
  through the existing `ttsFollowParagraph` hooks. The control bar from v1
  stays, it just calls the plugin instead of the local loop.
- App/reader closed: the native service keeps running on its own; progress is
  synced natively.

### 3.3 Android

**Where:** an extension of `PlayerNotificationService` (no second service —
one media session per app is also an Android Auto requirement).

- **`TTSPlaybackEngine`** (new class in `player/`): holds the `TextToSpeech`
  instance, the chunk queue of the current paragraph, the position
  (chapter/paragraph) and the rate. Speaks through `TextToSpeech#speak` with
  an `UtteranceProgressListener` to move to the next chunk. Implements the
  same "session guard" as JS v1.
- **Source switching:** the service gets an internal mode `AUDIO | TTS`.
  Starting a TTS session stops ExoPlayer (and vice versa) — one media session,
  one audio focus (`AudioFocusRequest`, `AUDIOFOCUS_GAIN`), ducking unchanged.
- **MediaSession mapping:** play/pause → engine; seek forward/back →
  ±paragraph; next/prev → ±N pages (the step from the reader settings,
  `pageStep` × `pageChars` in `TTSBook`); `setPlaybackSpeed` → TTS rate;
  metadata from `TTSBook` (title, author, cover, chapter as the "track").
- **Notification:** the existing `PlayerNotificationListener` path; only a
  different MediaDescription adapter for the TTS mode.
- **Android Auto:** a new **"Ebooks"** category in `BrowseTree`, filled from
  `listCachedBooks()` (i.e. books the user has opened in the reader at least
  once / explicitly "prepared for listening"). Selection in the car →
  `prepareBook` from the cache → `play`. Requires the cache to hold metadata
  and the cover as well — that is why the cache is filled on `prepareBook`,
  not only on `play`.
- **Doze/battery:** a foreground service of type `mediaPlayback` (already
  exists) — this removes the suspension problem of v1.

### 3.4 iOS

- **`TTSPlayer`** (new class next to `AudioPlayer.swift`): `AVSpeechSynthesizer`
  + `AVSpeechSynthesisVoice(language:)`, audio session `.playback` /
  `.spokenAudio` (same as audiobooks). The background audio mode is already
  on — synthesis keeps running with the screen locked as long as the session
  stays active.
- **Lock screen / controls:** `MPNowPlayingInfoCenter` (title, author, cover,
  time estimate) + `MPRemoteCommandCenter` (play/pause, skip ±paragraph, rate).
- **CarPlay (separate phase):** requires the CarPlay audio entitlement from
  Apple (an approval process!) and `CPTemplateApplicationSceneDelegate` +
  `CPListTemplate` for browsing. The app has no CarPlay today at all — it
  makes sense to do CarPlay for audiobooks first and add ebooks as a category.

### 3.5 Progress sync

- After every paragraph the native engine knows the `location` (cfi/page) and
  the cumulative `chars` → `ebookLocation` + `ebookProgress` (character ratio)
  to the existing endpoint `PATCH /api/me/progress/:id` (Android through
  `MediaProgressSyncer`, iOS through the existing API layer). The same format
  the reader saves today — opening the reader continues where read aloud
  stopped, and vice versa.

## 4. Implementation phases

| Phase | Content | Estimate |
| --- | --- | --- |
| **F1** | Plugin `AbsTTSPlayer` + Android `TTSPlaybackEngine` in `PlayerNotificationService`, notification, media session, cache, progress sync. Reader switched from the v1 loop to the plugin (the mixin hooks stay for extraction and follow-along). | the biggest piece of work |
| **F2** | Android Auto: "Ebooks" category in `BrowseTree`, selection and control from the car. | small to medium (builds on F1) |
| **F3** | iOS `TTSPlayer` + Now Playing + remote commands (background/locked screen on iOS). **Implemented** (see A.10), sideload build through `build-ios.yml` and `docs/ios-sideload.md`; not yet verified on a device. | medium |
| **F4** | CarPlay: entitlement, scene, templates (ideally including audiobooks). **Postponed indefinitely** — Apple grants the CarPlay audio entitlement only to a paid account on request, and a sideloaded build (free Apple ID) cannot carry it. Without it only the CarPlay "Now Playing" screen works (controls, no browsing). | medium + external dependency on Apple |

Fallback: the WebView loop from v1 stays in the code as a backup for when the
native layer is not available (e.g. an old build) and for immediate reading
without `prepareBook`.

## 5. Risks and open questions

- **Latency and voice availability:** `TextToSpeech` init is asynchronous and
  the engine may not have a Czech voice (handled with `isLanguageSupported` +
  a toast, possibly a link to install voices — the plugin has `openInstall()`).
- **Time semantics:** the media session requires duration/position — the
  estimate from characters is inexact; the car UI may show an "approximate"
  time. Alternative: show the position as "chapter X, paragraph Y/Z".
- **Coexistence with an audiobook:** it must be clearly defined that starting
  TTS stops audio playback (and vice versa) — one session, never two audio
  sources.
- **Cache size:** the full text of a book is hundreds of KB to a few MB of
  JSON — a limit on the number of cached books + LRU eviction (like the epub
  locations cache).
- **PDFs without a text layer** still will not work (OCR is out of scope).
- **The CarPlay entitlement** can take weeks and Apple may not grant it for
  TTS content — that is why CarPlay is the last phase and no earlier phase
  depends on it.
- **Upstream:** if this is meant as a contribution to upstream
  `advplyr/audiobookshelf-app`, the design should be discussed with the
  maintainer beforehand (touch points: `PlayerNotificationService`,
  `BrowseTree` — areas under active development).

---

## Appendix A: Implementation specification of phase F1 (+ F2)

Goal of F1: read aloud runs in a native service on Android — survives the
screen turning off, has a notification with controls and a media session. F2
builds on it with a category in Android Auto.

### A.1 List of changes by file

**JavaScript (shared by both platforms):**

| File | Change |
| --- | --- |
| `plugins/capacitor/AbsTTSPlayer.js` | **new** — `registerPlugin('AbsTTSPlayer')` + web/fallback implementation: when the native plugin is not available, delegates to today's JS loop from the mixin (keeps old builds working) |
| `plugins/capacitor/index.js` | export of the new plugin |
| `mixins/ttsPlayer.js` | the control loop is replaced by `AbsTTSPlayer` calls; the hooks for extraction and follow-along stay; `ttsExtractBook()` is added — extraction of the **whole book** (not just the current unit) into the `TTSBook` payload |
| `components/readers/EpubReader.vue` | `ttsExtractBook()`: walk the spine with `book.spine.each` + `section.load()` (without rendering — no need to display, the DOM is enough), paragraphs + cfi per section |
| `components/readers/MobiReader.vue` | `ttsExtractBook()`: the whole document = one chapter (possibly split by `h1/h2`) |
| `components/readers/PdfReader.vue` | `ttsExtractBook()`: `getTextContent()` of all pages; chapter = page |
| `components/readers/Reader.vue` | no UI changes; the bar calls the same methods (the mixin redirects them to the plugin) |

**Android:**

| File | Change |
| --- | --- |
| `plugins/AbsTTSPlayer.kt` | **new** — Capacitor bridge: `prepareBook`, `play`, `pause`, `stop`, `seekTo`, `nextChapter`, `prevChapter`, `setRate`, `setLanguage`, `getState`, `listCachedBooks`, `removeCachedBook`; events `onParagraph`, `onStateChange` through `notifyListeners` |
| `player/TTSPlaybackEngine.kt` | **new** — the engine itself (see A.2) |
| `player/TTSBookCache.kt` | **new** — JSON cache + LRU (see A.4) |
| `data/TTSBook.kt` | **new** — Jackson data classes `TTSBook/TTSChapter/TTSParagraph` (same style as `DeviceClasses.kt`) |
| `player/PlayerNotificationService.kt` | `AUDIO / TTS` mode; starting TTS stops ExoPlayer and vice versa; playback state + metadata from the engine |
| `player/MediaSessionCallback.kt` | routing of callbacks to the engine in TTS mode; `onPlayFromMediaId` for `ebook__` ids (F2) |
| `player/BrowseTree.kt` | (F2) "Ebooks" category from `TTSBookCache.list()` |
| `MainActivity.kt` | `registerPlugin(AbsTTSPlayer::class.java)` |

**iOS (F3):** `App/plugins/AbsTTSPlayer.swift` (`CAPBridgedPlugin`),
`Shared/player/TTSPlayer.swift` — the same plugin contract; files and
behaviour in A.10.

### A.2 `TTSPlaybackEngine` (Kotlin) — class outline

```kotlin
class TTSPlaybackEngine(
  val context: Context,
  val listener: Listener            // implemented by PlayerNotificationService
) : TextToSpeech.OnInitListener {

  interface Listener {
    fun onTTSStateChange(state: TTSState)          // → media session + notification + JS event
    fun onTTSParagraph(chapterIdx: Int, paragraphIdx: Int, location: String?)
  }

  private var tts: TextToSpeech? = null            // lazy init, onInit -> READY
  private var book: TTSBook? = null
  private var chapterIndex = 0
  private var paragraphIndex = 0
  private var chunkQueue: ArrayDeque<String> = ArrayDeque()  // sentences of the current paragraph
  private var sessionId = 0                        // the same "session guard" as in JS v1
  var rate: Float = 1f
  var language: String = "en-US"
  var state: TTSState = STOPPED                    // STOPPED | PLAYING | PAUSED

  fun prepare(book: TTSBook, startChapter: Int, startParagraph: Int)
  fun play(); fun pause(); fun stop()
  fun seekTo(chapter: Int, paragraph: Int)
  fun seekParagraph(delta: Int)                    // for skip ± from the notification/BT
  fun setPlaybackRate(r: Float)                    // tts.setSpeechRate + time recalculation

  // internal flow:
  // speakNextChunk(): utteranceId = "$sessionId-$chapterIndex-$paragraphIndex-$chunkIdx"
  //   tts.speak(chunk, QUEUE_FLUSH, params, utteranceId)
  // UtteranceProgressListener.onDone(id):
  //   - id does not belong to the current session -> ignore (guard)
  //   - next chunk / next paragraph (emit onTTSParagraph) / next chapter / end -> stop
  // chunking: port of splitTextChunks() from mixins/ttsPlayer.js (~300 characters, sentence boundaries)

  // time estimate for the media session (A.3):
  // positionMs = (charsSpokenBefore / CHARS_PER_SEC / rate) * 1000
  // durationMs = (book.totalChars / CHARS_PER_SEC / rate) * 1000, CHARS_PER_SEC ≈ 15
}
```

Principles:

- `TextToSpeech` init is async — a `play()` call before `onInit` is queued
  and executed after READY; an init error → JS event + toast.
- Language: `tts.setLanguage(Locale.forLanguageTag(language))`; the return
  codes `LANG_MISSING_DATA / LANG_NOT_SUPPORTED` → event
  `onStateChange(error=…)`, JS shows the existing `MessageReadAloudNoVoice`
  toast.
- The engine draws nothing and syncs nothing itself — it only speaks and
  reports the position.

### A.3 Media session mapping (TTS mode)

| MediaSession callback | Engine action |
| --- | --- |
| `onPlay` / `onPause` | `play()` / `pause()` |
| `onStop` | `stop()` + end of the TTS session (back to AUDIO mode) |
| `onSkipToNext` / `onSkipToPrevious` | `seekPages(+1)` / `seekPages(-1)` — skip by `pageStep` pages (pdf: chapter = page; otherwise `pageChars` characters per page, estimated by the reader) |
| `onFastForward` / `onRewind` | `seekParagraph(+1)` / `seekParagraph(-1)` |
| `onSeekTo(pos)` | pos → characters → nearest paragraph → `seekTo` |
| `onSetPlaybackSpeed(speed)` | `setPlaybackRate` |

Metadata: `METADATA_KEY_TITLE` = book title, `ARTIST` = author,
`ALBUM` = chapter title, `ART` = cover from the cache, `DURATION` = estimate (A.2).
`PlaybackState` switches `STATE_PLAYING/PAUSED/STOPPED` according to the engine.

### A.4 `TTSBookCache`

- Directory `filesDir/tts-cache/`, file `<libraryItemId>.json` (serialised
  `TTSBook`) + `<libraryItemId>.meta.json` (title, author, cover path,
  totalChars, lastAccessed — for fast listing without loading the whole book).
- `prepareBook` overwrites both parts and updates `lastAccessed`.
- LRU limit: max ~20 books or 50 MB (configurable constants) — when exceeded
  the oldest `lastAccessed` is deleted (the same principle as the epub
  locations cache in JS).
- Cover: copied into the cache (Android Auto needs it even without the server).

### A.5 Key flows

**Start from the reader:** the reader's `ttsExtractBook()` → `prepareBook(book)`
(stores the cache, prepares the session) → `play({chapterIndex, paragraphIndex})` →
the service switches to TTS mode (stops any audio), foreground notification,
the engine speaks → `onParagraph` events → the open reader follows along.

**Screen off:** the WebView is suspended, the engine in the foreground service
keeps running; after unlocking the reader catches up on the position from
`getState()`.

**Start from Android Auto (F2):** browse "Ebooks" → `onPlayFromMediaId("ebook__<id>")`
→ `TTSBookCache.load(id)` → `prepare` from the last position (from the saved
progress) → `play`. The app does not have to be open.

**End of the book:** engine `stop()` + `onStateChange(STOPPED, endOfBook=true)` →
progress 100 %, the notification disappears, the service returns to AUDIO mode.

### A.6 Progress sync

After every paragraph the engine computes `ebookLocation` (the paragraph's
location) and `ebookProgress = charsSpokenTotal / totalChars`; written locally
(Realm/DB like `updateLocalEbookProgress`) and to the server with
`PATCH /api/me/progress/:id` — **throttled to 15 s** as for audio (the
`MediaProgressSyncer` pattern). The format is identical to what the reader
saves → reading and listening continue from each other in both directions.

A paragraph without its own location (native epub extraction — paragraph cfis
need a rendered DOM) is saved as the chapter's `startCfi`, i.e. still a valid
epub cfi; a bare spine href is the last resort. Without a location the old
`ebookLocation` is **not overwritten** — an empty value would send the reader
back to the start of the book. The epub reader then resolves the position in
this order: paragraph cfi → chapter (chapter cfi or spine href) refined by the
character ratio from `ebookProgress` when it falls into the same chapter → the
character ratio alone (`locations.cfiFromPercentage`).

### A.7 Fallback rules in JS

```js
const useNative = Capacitor.getPlatform() === 'android'   // F1
  && Capacitor.isPluginAvailable('AbsTTSPlayer')
// otherwise: today's WebView loop (mixin) — iOS until F3, old builds, web
```

The mixin API towards the readers and the `Reader.vue` bar does not change —
the switch is transparent.

### A.8 F1 implementation status

The first slice of F1 is in the code (commit "Implement F1 slice…"):

- [x] JS: `plugins/capacitor/AbsTTSPlayer.js`, `ttsExtractBook()` in all three
  readers, the mixin delegates to the native plugin, follow-along from
  `onParagraph` events, state re-sync when the reader opens (`getState`)
- [x] Android: `TTSBook.kt`, `TTSBookCache.kt` (LRU), `TTSPlaybackEngine.kt`
  (TextToSpeech + session guard + chunker), `AbsTTSPlayer.kt` bridge, the
  TTS section in `PlayerNotificationService` (pausing audio, foreground
  MediaStyle notification with play/pause/stop actions), registration in
  `MainActivity`
- [x] Build and the basic scenarios verified on a device (Pixel 8 Pro):
  playback, screen off, lock screen controls; **the full manual matrix A.9
  (Doze 30+ min, interruption by a call, …) has not been run yet**
- [x] Media session takeover — with an active TTS session the shared media
  session switches to the engine (the MediaSessionConnector disconnected,
  PlaybackState and metadata from the TTSBook, routing per A.3 including
  BT/headset buttons and the seek bar); verified on a device (lock screen,
  Android 14+)
- [x] Native progress sync per A.6 — `TTSProgressSyncer` (15 s timer, flush on
  pause/stop/end of book): local items through `DbManager` + an event to the
  WebView, server `PATCH /api/me/progress/:id` (local items linked to a
  server as well as streamed ones; on a metered network after 60 s like
  `MediaProgressSyncer`); the end of the book reports 100 %
  (`endOfBookReached`); **not yet verified on a device**
- [x] F2: "Ebooks" category in `BrowseTree` (shown when `TTSBookCache` has
  content) + items from `TTSBookCache.list()` in `onLoadChildren` (media id
  `ebook__<libraryItemId>`, progress bar from the saved `ebookProgress`,
  works without a server like Downloads); `onPlayFromMediaId` routes
  `ebook__` ids to `playTTS`, which restores the last position from the saved
  progress (`ebookLocation`, fallback the character ratio from
  `ebookProgress`; local items from the DB, streamed ones from the progress
  loaded for Android Auto); `notifyEbooksChanged()` (`notifyChildrenChanged`)
  is called after `prepareBook`/`removeCachedBook`, otherwise Android Auto
  keeps a stale browse cache; the debug build is labelled "ABS Debug" so it
  can be told apart from the production app in the car; **verified on the
  DHU** (browse, selection, resume from the last position, now-playing
  metadata, list refresh after another book is cached)
- [x] Audio focus for the TTS engine (`AudioFocusRequestCompat`,
  USAGE_MEDIA/CONTENT_TYPE_SPEECH, requested on play, released on every stop
  including the end of the book and errors): without holding the focus
  Android Auto does not open the media stream to the car — TTS spoke into
  the projection sink (Remote Submix) but the car stayed silent until an
  audiobook took the focus; a transient loss pauses and resumes after GAIN,
  a permanent loss stops; side benefit: TTS no longer talks over other
  playing apps
- [x] F2+: ebooks in the Android Auto libraries and in Continue:
  - `EpubTextExtractor` — native text extraction from an EPUB (without the
    WebView): container.xml → OPF (spine, metadata, toc) through
    XmlPullParser; the content XHTML documents are deliberately not parsed as
    XML (real-world EPUBs break well-formedness — undeclared entities and the
    like), the text is obtained by stripping tags, where the closing of a
    block element forms a paragraph boundary; entities decoded (numeric +
    the common named ones), encoding per BOM/XML declaration. Paragraphs have
    no CFI (that would need a DOM) — `location=null`, resume in the reader
    through the chapter href (`startLocation`), resume of TTS through the
    character ratio from `ebookProgress`
  - an "Ebooks" node in every library of type book (`__LIBRARY__<id>__EBOOKS`,
    server filter `ebooks.<b64>`, epub only — other formats cannot be
    extracted natively); a tap on a book not yet cached → download of
    `/api/items/<id>/ebook` to a temporary file → extraction → storing in
    `TTSBookCache` → playback from the saved progress; the media session
    shows STATE_BUFFERING during the download and STATE_ERROR on failure
    (`downloadAndPlayTTS` in `PlayerNotificationService`)
  - the Continue category includes ebooks in progress from the TTS cache
    (0 < ebookProgress < 1) under an "Ebooks" heading; the category is shown
    even without audiobooks in progress; cache changes call
    `notifyChildrenChanged(CONTINUE_ROOT)`
  - `BrowseTree` no longer hides libraries without audio files when it is a
    book library with items (ebook-only libraries); cached ebooks carry the
    downloaded icon in the lists (EXTRA_DOWNLOAD_STATUS) and the cover art
    from the server (offline fallback to the book icon); an ebook-only
    library thereby also appears in "Recent" — the recently added shelf
    offers epub items as `ebook__` (read aloud) and hides the other formats
  - **not yet verified on the DHU**
- [x] TTS engine and voice selection:
  - New plugin methods `getEngines`, `getVoices({ engine, language })`,
    `setEngine`, `setVoice` and `openTTSSettings` (the system screen
    `com.android.settings.TTS_SETTINGS`); enumeration through a short-lived
    `TextToSpeech` instance owned by the plugin (resolved from the init
    callback, works without a prepared book)
  - `TTSPlaybackEngine`: fields `enginePackage`/`voiceName`, the voice is
    applied in `applyConfig()` (a missing voice = silent fallback to the
    language default); switching the engine requires shutdown + a new
    instance (`reinitTTS`) — the state stays PLAYING, the generation counter
    `ttsGeneration` discards init callbacks of replaced instances
  - `TTSBook` carries `ttsEngine`/`voice` (null = keep the current one); the
    choices arrive in the `prepareBook` payload and persist in the TTS cache
  - UI: dialog `TtsSettingsDialog.vue` (tune icon in the TTS bar + a row in
    the reader settings); keys `ttsEngine` and `ttsVoices` (a map per
    language) in `ereaderSettings`; the web fallback only supports the voice
    (a numeric index into `getSupportedVoices()`, resolved fresh), the engine
    choice is hidden
  - Limitation: a cold start from Android Auto of a book never started from
    the reader uses the last applied engine and the default voice (the
    per-language voice lives in the WebView, the same limitation as
    `ttsLanguageForBook`)
- [x] Reader/read aloud defaults and the language per book:
  - The global settings (`ereaderSettings`) live in the store module
    `store/ereader.js` and are saved through `@capacitor/preferences`
    (`$localStore.setEreaderSettings`), not in the WebView localStorage,
    which the system may discard — losing the settings silently reset read
    aloud to the built-in default language. The old localStorage value is
    migrated on first load; a missing language is derived from the app
    language.
  - Edited in the app Settings (section "Ebook reader and read aloud")
    through the shared form `components/readers/EreaderSettingsForm.vue`,
    which the settings modal in the reader uses as well.
  - The read aloud language is per book (`BOOK_SETTING_KEYS` in
    `Reader.vue`): the default comes from the book metadata — ABS metadata,
    then the epub's `dc:language` (the reader's `loaded` event), mapping
    `ttsLanguageForBookLanguage` in `utils/ereaderSettings.js` — otherwise
    the global default. A manual change in the reader is saved as a per-book
    override (`ebookSettings.ttsLanguage`), "Use for all books" promotes it
    to the default.
  - The appearance per book is per device (the font size from an iPad does
    not fit a phone and vice versa): `ebookSettings` on the server carries
    the shared keys of the book (`ttsLanguage`, `legacyEncoding`) and a map
    `devices[deviceId]` with the appearance (`theme`, `font`, `fontScale`,
    `lineSpacing`, `textStroke`, `spread` — `BOOK_DEVICE_SETTING_KEYS` in
    `utils/ereaderSettings.js`, helpers `bookSettingsForDevice` /
    `withDeviceBookSettings`). A top-level appearance (older app versions,
    the web client) is not used but is kept when saving, as are the entries
    of other devices. The device id is returned by the native layer in
    `getDeviceData` (Android ID, iOS `identifierForVendor`); without it one
    is generated once and stored in preferences (`ereaderDeviceId`); it is
    held by `store/ereader.js` (`ereader/getDeviceId`, loaded with the global
    settings). The local cache `ereaderBookSettings:<id>` carries the whole
    saved object. The server (fork, `MediaProgress.sanitizeEbookSettings`)
    must let `devices` and `ttsLanguage` through — on an older server the
    per-device appearance survives only in the local cache until the next
    load of the progress from the server.
  - Native safeguards against switching to English: `applyConfig()` after a
    failed `setLanguage` tries the language without a region and then a voice
    of that language from `engine.voices`; a saved voice of a different
    language is ignored (Android `applyConfig`, iOS `resolveVoice`),
    languages are compared through `TTSPlaybackEngine.sameLanguage` (2- and
    3-letter voice codes). `ttsLanguageForBook` normalises a language name
    ("Czech") to a tag.
- [x] Position sync between the phone and the car (a book partly read on the
  phone → listening to the same book in the car):
  - The data for Android Auto (`serverUserMediaProgress`,
    `serverItemsInProgress`) used to be loaded once per service lifetime and
    never refreshed — whatever the user read or listened to on the phone in
    the meantime did not reach the car. `MediaManager.refreshServerProgress()`
    reloads it when the car connects (`onGetRoot`) and when the Continue
    category is opened; a 10 s throttle and a fingerprint comparison of the
    data prevent a `notifyChildrenChanged` loop. A failed request leaves the
    existing cache alone (the Continue list must not empty because of one
    outage).
  - `playTTS` for a selection in the car (without an explicit position)
    **always** restores the position from the saved progress — even when the
    engine already holds the same book. Previously the seek happened only
    when loading a different book, so after a `prepareBook` from the reader
    (the position resets to the start) the car read the book from the
    beginning. Before resuming, the item's position is fetched from the
    server (`GET /api/me/progress/:id`, 3 s pingClient timeout, on error it
    continues with the cache).
  - `savedEbookProgress` takes the newer of (server progress, local DB) by
    `lastUpdate` — a downloaded book read offline on the phone and a streamed
    book read on another device thus lead to the same position. The whole
    local progress table is read from disk, so the lists pass it along once
    instead of per item.
  - An empty "play" from the car (steering wheel, "play an audiobook") plays
    the most recently listened item, or the most recently read ebook when it
    is newer — instead of `getFirstItem()` (the first random item in the
    cache). Applies to `onPrepare`, `onPlayFromMediaId` without an id and a
    search without a query in `MediaSessionCallback` as well as
    `MediaSessionPlaybackPreparer`.
  - **not yet verified on the DHU / in a car**
- [x] Sync of the reader with a running / paused read aloud session and with
  the server after time in the background (a regression reported after the
  per-book settings):
  - The WebView learns about progress written elsewhere (native read aloud
    with the screen off, the car, another device) only from socket events
    (`user_updated`, `user_item_progress_updated`) and those are lost in the
    background; `user.mediaProgress` is otherwise loaded only at login. The
    reader then opened at the old position and `loadBookSettingsOverride`
    took a stale `ebookSettings: null` for "nothing saved" and deleted the
    local cache — the book opened with the default font size. `Reader.vue`
    now, before mounting the reader component (`progressReady`), reloads the
    local progress from the DB and fetches `GET /api/me/progress/:id` (3 s
    timeout) into the store; for a downloaded book it copies the newer
    position from the server into the local progress (only
    `ebookLocation`/`ebookProgress`). "No settings" in the store counts only
    after this fresh load, otherwise the local cache is used.
  - The mixin in `created()` detects a running/paused session of the same
    book through `getState()` (`ttsNativeSessionState`); the readers use it
    as the opening target (epub: paragraph cfi → chapter refined by the
    character ratio → the ratio alone, pdf: page, mobi/document: paragraph
    index) instead of the saved progress, so after opening the reader does
    not "catch up" with read aloud by flipping pages. The read aloud bar
    shows itself when a session is taken over.
  - Play after a pause: when the user has paged elsewhere in the meantime
    (hook `ttsIsParagraphVisible`), read aloud continues from the first
    paragraph of the visible page (`ttsSeekToVisiblePage`), not from the
    pause spot. Native and WebView paths alike.
  - Server (fork, `MediaProgress.applyProgressUpdate`): a PATCH carrying only
    `ebookSettings` saves silently (`save({ silent: true })`), so it does not
    bump `updatedAt`/`lastUpdate` — otherwise an older server position "won"
    over a newer local one (`syncLocalMediaProgressForUser`,
    `savedEbookProgress` for Android Auto). Android:
    `updateFromServerMediaProgress` does not overwrite the local position in
    a book with a server progress without a position (e.g. a row created by
    the settings alone); iOS the same in `LocalMediaProgress.swift`.
  - The position format, for completeness: `ebookLocation` is an epub CFI (an
    address in the DOM, independent of the font size and pagination),
    `ebookProgress` a ratio 0–1 (the reader from the epubjs locations every
    100 characters, read aloud from the character ratio). Changing the font
    size does not move the position, it only re-paginates.
  - **not yet verified on a device**
- [x] F3: iOS engine (see A.10); **not yet verified on a device**
- [ ] F4: CarPlay — **postponed indefinitely** (requires the CarPlay audio
  entitlement from Apple, i.e. a paid account + approval; a sideload build
  cannot carry it)

### A.9 F1 test plan

- **Unit (Kotlin):** the chunker (parity with the JS `splitTextChunks` on a
  set of Czech and English texts including abbreviations and long
  sentences), position/time estimate computation, the LRU cache.
- **Manual matrix:** screen off 30+ min / Doze (`adb shell dumpsys
  deviceidle force-idle`) / BT controls / switching audio↔TTS / changing the
  rate and language while running / a book without a Czech voice / empty
  chapters / service restart by the system (`onStartCommand` recovery).
- **Android Auto (F2):** Desktop Head Unit (DHU) — browse, selection,
  controls, metadata, recovery after a disconnect. Note: with Android Auto
  17.x the DHU only works in **USB accessory mode** (`desktop-head-unit
  --usb`, the phone on a cable, USB debugging on; on Windows manually assign
  the WinUSB driver to "Android Accessory Interface" in Device Manager). The
  head unit server over `adb forward tcp:5277` is a dead end — the server
  accepts the connection but never reads the handshake. Launch the DHU with
  its own console (`Start-Process`); it exits on a closed stdin.
- **Regression:** audiobook playback (focus, notification, Cast) must not be
  affected by the TTS mode.

### A.10 F3 implementation status (iOS)

A port of F1 to iOS with the same plugin contract — the JS layer does not
change, only `isNativeTTSPlayerAvailable()` accepts the `ios` platform too.

| File | Role |
| --- | --- |
| `ios/App/App/plugins/AbsTTSPlayer.swift` | Capacitor bridge (`CAPBridgedPlugin`), the same methods and events as the Kotlin plugin; registered in `MyViewController.capacitorDidLoad` |
| `ios/App/Shared/player/TTSPlayer.swift` | engine: `AVSpeechSynthesizer`, chunker (port of `splitTextChunks`), session guard through the current utterance, seeking by paragraphs/chapters/pages, audio session `.playback/.spokenAudio` (an interruption by a call pauses and resumes when it ends, unplugging headphones pauses), `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (mapping per A.3: previous/next = pages, seek = paragraph, scrubber = time estimate, rate change) |
| `ios/App/Shared/player/TTSProgressSyncer.swift` | progress sync per A.6: 15 s timer, local `LocalMediaProgress` (Realm) + an event to the WebView through `AbsAudioPlayer.onLocalMediaProgressUpdate`, server `PATCH api/me/progress/:id` (metered network after 60 s) |
| `ios/App/Shared/player/TTSBookCache.swift` | JSON cache + LRU (A.4) in Application Support/`tts-cache` |
| `ios/App/Shared/models/TTSBook.swift` | `Codable` model `TTSBook/TTSChapter/TTSParagraph/TTSBookSummary` with tolerant decoding of the payload from JS |
| `ios/App/Shared/player/PlayerHandler.swift` | starting an audiobook ends a running TTS session (shared audio output and Now Playing) and conversely TTS pauses the audio player |

Differences from Android:

- **Engine/voice:** iOS has a single engine — `getEngines()` returns an empty
  list and the settings dialog hides the engine row; `setEngine()` is a
  no-op. Voices (`getVoices`) use the stable `identifier` as `name` (names
  repeat across qualities) and a displayed `label` (e.g. "Zuzana
  (Enhanced)"). `openTTSSettings()` opens the Settings app — voices are
  downloaded in Accessibility → Spoken Content → Voices.
- **Rate:** `AVSpeechUtterance.rate` is not a multiplier; the mapping is
  `0.5 * multiplier` below 1× and `0.5 + (multiplier − 1) · 0.25` above 1×
  (2× ≈ 0.75).
- **Pause:** as on Android, after a pause speaking restarts from the
  beginning of the current chunk (max ~300 characters).
- **No Android Auto equivalent:** no browse tree, native epub extraction or
  Continue category; `play({ libraryItemId })` for a book other than the
  prepared one takes it from the cache and resumes from the saved position
  (local DB / server, the newer wins) — used only when restoring a session
  from the reader.
- **No CarPlay** (F4) — the CarPlay "Now Playing" screen does show and
  control a running read aloud like any other audio, though.

Build and distribution: `.github/workflows/build-ios.yml` (unsigned IPA
`audiobookshelf-ios.ipa` + SideStore source feed `sidestore-source.json` from
`scripts/make-sidestore-source.py`, release `latest-ios`), installation steps
through iloader/SideStore in `docs/ios-sideload.md`.

Not verified on a device: the whole manual matrix A.9 for iOS (locked screen
30+ min, interruption by a call, headphones, switching audio↔TTS, a book
without a Czech voice, progress sync).
