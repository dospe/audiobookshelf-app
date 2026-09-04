package com.audiobookshelf.app.player

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import androidx.media.AudioAttributesCompat
import androidx.media.AudioFocusRequestCompat
import androidx.media.AudioManagerCompat
import com.audiobookshelf.app.data.TTSBook
import java.util.Locale

/**
 * Native read aloud (TTS) playback engine speaking a TTSBook with the device
 * system voices. Runs inside PlayerNotificationService so playback continues
 * with the screen off. Mirrors the WebView loop in mixins/ttsPlayer.js:
 * paragraphs are spoken in sentence-sized chunks guarded by a session id.
 *
 * See docs/native-tts-player-design.md (A.2)
 */
class TTSPlaybackEngine(val context: Context, val listener: Listener) {

  enum class TTSState(val value: String) {
    STOPPED("stopped"), PLAYING("playing"), PAUSED("paused")
  }

  interface Listener {
    fun onTTSStateChange(state: TTSState)
    fun onTTSParagraph(chapterIndex: Int, paragraphIndex: Int, location: String?, progress: Double)
    fun onTTSError(message: String)
  }

  companion object {
    const val MAX_CHUNK_LENGTH = 300
    const val CHARS_PER_SECOND = 15.0 // rough speaking speed at 1x for time estimates
  }

  private val tag = "TTSPlaybackEngine"
  private val mainHandler = Handler(Looper.getMainLooper())

  private var tts: TextToSpeech? = null
  private var ttsReady = false
  private var pendingOnReady: (() -> Unit)? = null
  // Incremented on every (re)creation so init callbacks of replaced instances are ignored
  private var ttsGeneration = 0

  var book: TTSBook? = null
    private set
  var chapterIndex = 0
    private set
  var paragraphIndex = 0
    private set
  var state: TTSState = TTSState.STOPPED
    private set
  var rate: Float = 1f
    private set
  var language: String = "en-US"
    private set
  var enginePackage: String = "" // "" = system default engine
    private set
  var voiceName: String = "" // "" = engine default voice for the language
    private set
  // Page skips (media session next/previous): pages per skip and characters per displayed page
  var pageStep: Int = TTSBook.DEFAULT_PAGE_STEP
    private set
  var pageChars: Int = TTSBook.DEFAULT_PAGE_CHARS
    private set

  private var chunks: List<String> = emptyList()
  private var chunkIndex = 0
  // Incremented on every interruption so stale utterance callbacks are ignored
  private var sessionId = 0

  private val audioManager by lazy { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
  private var hasAudioFocus = false
  private var resumeOnFocusGain = false

  // Ducked speech is unintelligible, so a transient loss pauses and gain resumes
  private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
    mainHandler.post {
      when (change) {
        AudioManager.AUDIOFOCUS_LOSS -> {
          resumeOnFocusGain = false
          pause()
          abandonAudioFocus()
        }
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
          if (state == TTSState.PLAYING) {
            resumeOnFocusGain = true
            pause()
          }
        }
        AudioManager.AUDIOFOCUS_GAIN -> {
          if (resumeOnFocusGain) {
            resumeOnFocusGain = false
            play()
          }
        }
      }
    }
  }

  private val audioFocusRequest: AudioFocusRequestCompat by lazy {
    AudioFocusRequestCompat.Builder(AudioManagerCompat.AUDIOFOCUS_GAIN)
      .setAudioAttributes(
        AudioAttributesCompat.Builder()
          .setUsage(AudioAttributesCompat.USAGE_MEDIA)
          .setContentType(AudioAttributesCompat.CONTENT_TYPE_SPEECH)
          .build()
      )
      .setOnAudioFocusChangeListener(audioFocusListener)
      .build()
  }

  /**
   * Media audio focus - besides pausing other audio apps, Android Auto only
   * opens the car media stream for the focus holder (without it the engine
   * speaks into the projection sink but the car stays silent)
   */
  private fun requestAudioFocus(): Boolean {
    if (hasAudioFocus) return true
    val result = AudioManagerCompat.requestAudioFocus(audioManager, audioFocusRequest)
    hasAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    if (!hasAudioFocus) Log.w(tag, "Audio focus request denied")
    return hasAudioFocus
  }

  private fun abandonAudioFocus() {
    if (!hasAudioFocus) return
    hasAudioFocus = false
    AudioManagerCompat.abandonAudioFocusRequest(audioManager, audioFocusRequest)
  }
  // Position stays on the last paragraph when the book ends; this makes progress report 100%
  var endOfBookReached = false
    private set

  val currentLocation: String?
    get() = book?.chapters?.getOrNull(chapterIndex)?.paragraphs?.getOrNull(paragraphIndex)?.location

  val progress: Double
    get() {
      val currentBook = book ?: return 0.0
      if (endOfBookReached) return 1.0
      if (currentBook.totalChars <= 0) return 0.0
      return currentBook.charsBefore(chapterIndex, paragraphIndex).toDouble() / currentBook.totalChars
    }

  /** Estimated total duration in ms from character count and speaking rate, for media session metadata */
  val estimatedDurationMs: Long
    get() {
      val currentBook = book ?: return 0L
      return (currentBook.totalChars / (CHARS_PER_SECOND * rate) * 1000).toLong()
    }

  /** Estimated position in ms of the current paragraph start, for media session playback state */
  val estimatedPositionMs: Long
    get() {
      val currentBook = book ?: return 0L
      return (currentBook.charsBefore(chapterIndex, paragraphIndex) / (CHARS_PER_SECOND * rate) * 1000).toLong()
    }

  /** Seek from an estimated time position (media session seek bar) to the nearest paragraph */
  fun seekToPositionMs(positionMs: Long) {
    val currentBook = book ?: return
    val targetChars = (positionMs / 1000.0 * CHARS_PER_SECOND * rate).toInt()
    var chars = 0
    currentBook.chapters.forEachIndexed { ci, chapter ->
      chapter.paragraphs.forEachIndexed { pi, paragraph ->
        chars += paragraph.chars
        if (chars > targetChars) {
          seekTo(ci, pi)
          return
        }
      }
    }
    val lastChapterIndex = maxOf(0, currentBook.chapters.size - 1)
    seekTo(lastChapterIndex, maxOf(0, (currentBook.chapters.lastOrNull()?.paragraphs?.size ?: 1) - 1))
  }

  fun prepare(newBook: TTSBook) {
    // Preparing a different book while a session is active ends that session
    // first, while `book` still points at the old one: the STOPPED transition
    // syncs the old book's final progress and resets the notification/media
    // session, and the play() that follows raises PLAYING again so the
    // service and the client both see the book switch
    if (state != TTSState.STOPPED && book?.libraryItemId != newBook.libraryItemId) {
      stop()
    }
    interrupt()
    book = newBook
    language = newBook.language
    rate = newBook.rate
    // null = keep current engine/voice (native Android Auto extraction path).
    // No resume here - play() follows and initializes the new engine lazily
    newBook.ttsEngine?.let {
      if (it != enginePackage) {
        enginePackage = it
        shutdownTTSInstance()
      }
    }
    newBook.voice?.let { voiceName = it }
    setPageStep(newBook.pageStep, newBook.pageChars)
    chapterIndex = 0
    paragraphIndex = 0
    chunks = emptyList()
    chunkIndex = 0
    endOfBookReached = false
  }

  fun play(startChapterIndex: Int? = null, startParagraphIndex: Int? = null) {
    val currentBook = book
    if (currentBook == null) {
      listener.onTTSError("No book prepared")
      return
    }
    if (startChapterIndex != null) {
      chapterIndex = startChapterIndex.coerceIn(0, currentBook.chapters.size - 1)
      paragraphIndex = (startParagraphIndex ?: 0).coerceIn(0, maxOf(0, currentBook.chapters[chapterIndex].paragraphs.size - 1))
      chunks = emptyList()
      chunkIndex = 0
      endOfBookReached = false
    }

    if (!requestAudioFocus()) {
      listener.onTTSError("Audio focus denied")
      return
    }

    interrupt()
    setState(TTSState.PLAYING)
    withTTS {
      applyConfig()
      if (chunks.isEmpty()) {
        loadCurrentParagraph()
      }
      speakCurrentChunk()
    }
  }

  fun pause() {
    if (state != TTSState.PLAYING) return
    interrupt()
    setState(TTSState.PAUSED)
  }

  fun stop() {
    if (state == TTSState.STOPPED) return
    interrupt()
    setState(TTSState.STOPPED)
  }

  fun release() {
    resumeOnFocusGain = false
    abandonAudioFocus()
    interrupt()
    state = TTSState.STOPPED
    tts?.shutdown()
    tts = null
    ttsReady = false
  }

  fun seekTo(newChapterIndex: Int, newParagraphIndex: Int) {
    val currentBook = book ?: return
    chapterIndex = newChapterIndex.coerceIn(0, currentBook.chapters.size - 1)
    paragraphIndex = newParagraphIndex.coerceIn(0, maxOf(0, currentBook.chapters[chapterIndex].paragraphs.size - 1))
    chunks = emptyList()
    chunkIndex = 0
    endOfBookReached = false
    if (state == TTSState.PLAYING) {
      interrupt()
      setState(TTSState.PLAYING) // re-notify for notification/position updates
      withTTS {
        loadCurrentParagraph()
        speakCurrentChunk()
      }
    }
  }

  fun seekParagraph(delta: Int) {
    val currentBook = book ?: return
    var ci = chapterIndex
    var pi = paragraphIndex + delta
    while (pi < 0 && ci > 0) {
      ci--
      pi += currentBook.chapters[ci].paragraphs.size
    }
    while (ci < currentBook.chapters.size && pi >= currentBook.chapters[ci].paragraphs.size) {
      pi -= currentBook.chapters[ci].paragraphs.size
      ci++
    }
    if (ci >= currentBook.chapters.size) return // past the end, ignore
    seekTo(ci, maxOf(0, pi))
  }

  fun seekChapter(delta: Int) {
    seekTo(chapterIndex + delta, 0)
  }

  /**
   * Pages per media session skip and the reader's characters-per-page
   * estimate; values <= 0 keep the defaults
   */
  fun setPageStep(newPageStep: Int, newPageChars: Int) {
    pageStep = if (newPageStep > 0) newPageStep else TTSBook.DEFAULT_PAGE_STEP
    pageChars = if (newPageChars > 0) newPageChars else TTSBook.DEFAULT_PAGE_CHARS
  }

  /**
   * Skip `delta` steps of [pageStep] pages (media session next/previous).
   * A pdf chapter is one page, so pdfs skip by chapters; other formats move
   * by [pageChars] characters per page to the paragraph at the target,
   * always at least one paragraph in the requested direction. The reader,
   * when open, follows through the paragraph event.
   */
  fun seekPages(delta: Int) {
    val currentBook = book ?: return
    if (delta == 0) return
    val steps = delta * pageStep

    if (currentBook.ebookFormat == "pdf") {
      val target = (chapterIndex + steps).coerceIn(0, currentBook.chapters.size - 1)
      if (target == chapterIndex && delta > 0) return // already on the last page
      seekTo(target, 0)
      return
    }

    val currentChars = currentBook.charsBefore(chapterIndex, paragraphIndex)
    val targetChars = currentChars + steps * pageChars
    if (targetChars <= 0) {
      seekTo(0, 0)
      return
    }
    if (targetChars >= currentBook.totalChars) {
      if (delta > 0) seekParagraph(1) // near the end: just move on, past the end is ignored
      return
    }
    val (ci, pi) = currentBook.positionForProgress(targetChars.toDouble() / currentBook.totalChars)
    if (ci == chapterIndex && pi == paragraphIndex) {
      // Target landed in the current (long) paragraph - still move one paragraph
      seekParagraph(if (delta > 0) 1 else -1)
      return
    }
    seekTo(ci, pi)
  }

  fun setPlaybackRate(newRate: Float) {
    rate = newRate
    restartCurrentChunkIfPlaying()
  }

  fun setLanguage(newLanguage: String) {
    language = newLanguage
    restartCurrentChunkIfPlaying()
  }

  fun setEngine(newEnginePackage: String) {
    if (newEnginePackage == enginePackage) return
    enginePackage = newEnginePackage
    voiceName = "" // voices are engine-specific; the client sends setVoice right after
    reinitTTS()
  }

  fun setVoice(newVoiceName: String) {
    if (newVoiceName == voiceName) return
    voiceName = newVoiceName
    restartCurrentChunkIfPlaying()
  }

  /** The engine cannot change on a live TextToSpeech instance - shutdown and lazily re-init */
  private fun reinitTTS() {
    val wasPlaying = state == TTSState.PLAYING
    shutdownTTSInstance()
    if (wasPlaying) {
      // State stays PLAYING through the swap so the notification/media session
      // are untouched; playback resumes on the current chunk once ready
      withTTS {
        applyConfig()
        speakCurrentChunk()
      }
    }
  }

  private fun shutdownTTSInstance() {
    interrupt()
    tts?.shutdown()
    tts = null
    ttsReady = false
    pendingOnReady = null
    ttsGeneration++ // invalidate any init still in flight
  }

  // ---------------------------------------------------------------- internal

  private fun createTTS() {
    val generation = ++ttsGeneration
    val initListener = TextToSpeech.OnInitListener { status -> handleTTSInit(generation, status) }
    tts = if (enginePackage.isEmpty()) TextToSpeech(context, initListener)
          else TextToSpeech(context, initListener, enginePackage)
  }

  private fun handleTTSInit(generation: Int, status: Int) {
    mainHandler.post {
      // Init of an instance that was already replaced (engine switched mid-init)
      if (generation != ttsGeneration) return@post
      if (status == TextToSpeech.SUCCESS) {
        Log.d(tag, "TextToSpeech engine ready")
        ttsReady = true
        tts?.setOnUtteranceProgressListener(utteranceListener)
        pendingOnReady?.invoke()
      } else {
        Log.e(tag, "TextToSpeech engine failed to initialize (status=$status)")
        listener.onTTSError("TTS engine failed to initialize")
        setState(TTSState.STOPPED)
      }
      pendingOnReady = null
    }
  }

  /** Run the block once the TTS engine is initialized (lazy init on first use) */
  private fun withTTS(block: () -> Unit) {
    if (ttsReady) {
      block()
      return
    }
    pendingOnReady = block
    if (tts == null) {
      createTTS()
    }
  }

  private fun applyConfig() {
    val engine = tts ?: return
    engine.setSpeechRate(rate)
    val result = engine.setLanguage(Locale.forLanguageTag(language))
    if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
      Log.w(tag, "Language $language not supported by the TTS engine")
      listener.onTTSError("Language $language is not supported")
    }
    if (voiceName.isNotEmpty()) {
      // Broken engines can throw from the voices getter
      val voice = try { engine.voices } catch (e: Exception) { null }?.find { it.name == voiceName }
      if (voice != null) {
        engine.setVoice(voice)
      } else {
        // Silent fallback - setLanguage above already selected a working default
        Log.w(tag, "Voice $voiceName not found, using language default")
      }
    }
  }

  private fun setState(newState: TTSState) {
    if (state == newState) return
    state = newState
    // Every stop path (user stop, end of book, speech errors) releases the focus
    if (newState == TTSState.STOPPED) {
      resumeOnFocusGain = false
      abandonAudioFocus()
    }
    listener.onTTSStateChange(newState)
  }

  /** Stop speaking without changing state; invalidates in-flight utterance callbacks */
  private fun interrupt() {
    sessionId++
    tts?.stop()
  }

  private fun restartCurrentChunkIfPlaying() {
    if (state != TTSState.PLAYING) return
    interrupt()
    withTTS {
      applyConfig()
      speakCurrentChunk()
    }
  }

  private fun loadCurrentParagraph() {
    val paragraph = book?.chapters?.getOrNull(chapterIndex)?.paragraphs?.getOrNull(paragraphIndex)
    chunks = if (paragraph == null) emptyList() else splitTextChunks(paragraph.text)
    chunkIndex = 0
    if (paragraph != null) {
      listener.onTTSParagraph(chapterIndex, paragraphIndex, paragraph.location, progress)
    }
  }

  private fun speakCurrentChunk() {
    if (state != TTSState.PLAYING) return
    val chunk = chunks.getOrNull(chunkIndex)
    if (chunk == null) {
      advance()
      return
    }
    val engine = tts
    if (engine == null) {
      listener.onTTSError("TTS engine not available")
      setState(TTSState.STOPPED)
      return
    }
    val utteranceId = sessionId.toString()
    val result = engine.speak(chunk, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
    if (result != TextToSpeech.SUCCESS) {
      Log.e(tag, "TTS speak failed (result=$result)")
      listener.onTTSError("Speech failed")
      setState(TTSState.STOPPED)
    }
  }

  private fun advance() {
    val currentBook = book ?: return
    // Next paragraph, moving across chapter boundaries (empty chapters are
    // not produced by the extractor but guard anyway)
    var ci = chapterIndex
    var pi = paragraphIndex + 1
    while (ci < currentBook.chapters.size && pi >= currentBook.chapters[ci].paragraphs.size) {
      ci++
      pi = 0
    }
    if (ci >= currentBook.chapters.size) {
      Log.d(tag, "Reached the end of the book")
      endOfBookReached = true
      setState(TTSState.STOPPED)
      return
    }
    chapterIndex = ci
    paragraphIndex = pi
    loadCurrentParagraph()
    speakCurrentChunk()
  }

  private val utteranceListener = object : UtteranceProgressListener() {
    override fun onStart(utteranceId: String?) {}

    override fun onDone(utteranceId: String?) {
      mainHandler.post {
        if (utteranceId != sessionId.toString() || state != TTSState.PLAYING) return@post
        chunkIndex++
        speakCurrentChunk()
      }
    }

    @Deprecated("Deprecated in Java")
    override fun onError(utteranceId: String?) {
      onError(utteranceId, -1)
    }

    override fun onError(utteranceId: String?, errorCode: Int) {
      mainHandler.post {
        if (utteranceId != sessionId.toString() || state != TTSState.PLAYING) return@post
        Log.e(tag, "TTS utterance error (code=$errorCode)")
        listener.onTTSError("Speech failed")
        setState(TTSState.STOPPED)
      }
    }
  }

  /**
   * Split text into sentence-sized chunks - same algorithm as
   * splitTextChunks in mixins/ttsPlayer.js
   */
  fun splitTextChunks(text: String, maxLength: Int = MAX_CHUNK_LENGTH): List<String> {
    val chunks = mutableListOf<String>()
    val sentenceRegex = Regex("[^.!?…]+[.!?…]+[\"'”’)]*\\s*|[^.!?…]+$")
    val sentences = sentenceRegex.findAll(text).map { it.value }.toList().ifEmpty { listOf(text) }
    var current = ""
    for (sentence in sentences) {
      if (current.isNotEmpty() && current.length + sentence.length > maxLength) {
        chunks.add(current)
        current = ""
      }
      if (sentence.length > maxLength) {
        var remaining = sentence.trim()
        while (remaining.length > maxLength) {
          var cut = remaining.lastIndexOf(' ', maxLength)
          if (cut <= 0) cut = maxLength
          chunks.add(remaining.substring(0, cut))
          remaining = remaining.substring(cut)
        }
        current = remaining
      } else {
        current += sentence
      }
    }
    if (current.isNotEmpty()) chunks.add(current)
    return chunks.map { it.trim() }.filter { it.isNotEmpty() }
  }
}
