# Audiobookshelf Mobile App (fork with ebook read aloud)

A fork of the official [Audiobookshelf mobile app](https://github.com/advplyr/audiobookshelf-app) for Android and iOS. It keeps everything the upstream app does (audiobook and podcast streaming, downloads, Android Auto, Chromecast, sleep timer, ebook reader) and adds a **native read aloud (text-to-speech) player for ebooks**, more ebook formats, ebooks in Android Auto, per-book reader settings, a library scan action and ready-to-install test builds for both platforms.

Audiobookshelf is a self-hosted audiobook and podcast server. **The app requires an Audiobookshelf server to connect to.** A few fork features (per-device appearance of a book, the read aloud language stored with the book) need the companion server fork [dospe/audiobookshelf](https://github.com/dospe/audiobookshelf); everything else works with a stock server.

Upstream project: [github.com/advplyr/audiobookshelf](https://github.com/advplyr/audiobookshelf) · site [audiobookshelf.org](https://audiobookshelf.org) · [Discord](https://discord.gg/pJsjuNCKRq)

<img alt="Screenshot" src="https://github.com/advplyr/audiobookshelf-app/raw/master/screenshots/DeviceDemoScreens.png" />

## Getting the app

This fork is not published in the app stores. Every push to `master` builds test apps and attaches them to two GitHub pre-releases, so the newest build is always a click away:

| Platform | Where | Notes |
| --- | --- | --- |
| Android 7+ | Release [`latest`](https://github.com/dospe/audiobookshelf-app/releases/tag/latest) → `audiobookshelf-<date>-<commit>.apk` | Debug build: installs next to the store app as **ABS Debug** (package `com.audiobookshelf.app.debug`). Allow installs from unknown sources. Signed with a shared debug key, so every build updates the previous one. |
| iOS / iPadOS 14+ | Release [`latest-ios`](https://github.com/dospe/audiobookshelf-app/releases/tag/latest-ios) → `audiobookshelf-ios.ipa` + `sidestore-source.json` | Unsigned IPA, sideloaded with SideStore (free Apple ID, no Mac needed after the first install). Full guide: [docs/ios-sideload.md](docs/ios-sideload.md). |

Builds of other branches and pull requests are available as workflow artifacts (`audiobookshelf-apk`, `audiobookshelf-ipa`) on the Actions tab.

The official app is on the [Google Play Store](https://play.google.com/store/apps/details?id=com.audiobookshelf.app) and, for iOS, on [TestFlight](https://testflight.apple.com/join/wiic7QIW) (the beta is full; updates are posted on Discord).

## Features added by this fork

### Read aloud (text-to-speech) for ebooks

- **Read aloud bar in the ebook reader** for EPUB, MOBI/AZW3, PDF and document formats: play/pause, stop, skip back/forward by a configurable number of pages, speed, language and voice. The bar is a single row and can be placed on the left or right for one-handed use.
- **Native player on Android and iOS.** The reading loop runs in the native layer (a text-to-speech engine inside the media service), so it keeps going with the screen off and in the background, shows a media notification, and responds to lock screen, headset and Bluetooth controls. On iOS it also appears in Control Center and on the CarPlay "Now Playing" screen. A WebView fallback stays in place for the web build and older native builds.
- **Follow-along:** the open reader turns pages to the paragraph being spoken, and the reader opens at the spoken position when a session is running or paused in the background. Play after a pause continues from the page you paged to.
- **Speech engine and voice selection** (engine on Android only; iOS has one engine), a shortcut to the system speech settings, and a per-language voice memory. Offered read aloud languages: Czech and English.
- **Per-book read aloud language**, defaulting from the book metadata (Audiobookshelf language, then the EPUB `dc:language`), with "Use for all books" to promote a choice to the default.
- **Reading position sync:** the native player writes `ebookLocation`/`ebookProgress` to the local database and to the server every 15 seconds, in the same format the reader uses, so reading and listening continue from the same spot on every device.

### Ebooks in Android Auto

- An **Ebooks** category with every book cached for read aloud, an **Ebooks** node in each book library (EPUBs are downloaded and extracted natively, no phone interaction needed), and in-progress ebooks in **Continue**.
- Selecting a book in the car resumes read aloud from the last saved position (the newer of server and local progress), and an empty "play" from the steering wheel resumes the most recent audiobook or ebook.
- Progress is refreshed when the car connects, so what you read on the phone is where the car picks up.

### More ebook formats and reader settings

- **Document reader** for `doc`, `docx`, `rtf` and `pdb` (Palm) files with a table of contents built from headings, read aloud support and a **text encoding** option for legacy files. Downloads and local folders recognise the new formats too.
- **EPUB:** two-page spread on wide screens, cached location index for progress-based resume, tolerance for spine entries with missing manifest items.
- **MOBI:** text decoding honours the header encoding.
- **Reader and read aloud defaults in Settings** (theme, font, size, line spacing, boldness, layout, encoding, volume key navigation, keep screen awake, read aloud options), stored in native preferences so they survive WebView storage cleanups.
- **Per-book settings:** the appearance is remembered for each book *per device* (the font size for an iPad is not the one for a phone), the read aloud language per book. Requires the companion server fork; with a stock server the per-device appearance lives only in the local cache.

### Library

- **Scan library** action in the side drawer (admin users). Progress and results are shown as toasts, the shelves reload when the scan finishes, and a fallback poll catches scans that finished while the app was in the background.

### Builds, CI and developer tooling

- **Test builds on every push:** `Build APK` (workflow artifact), `Publish Test App` (the `latest` release, master only) and `Build iOS IPA` (artifact plus the `latest-ios` release with a SideStore source feed, master only).
- **Shared debug keystore** (`android/app/debug.keystore`) so CI and local debug builds install over each other; the debug build is labelled **ABS Debug** to tell it apart from the store app in Android Auto.
- **Setup scripts:** `scripts/setup-macos-dev.sh` (macOS, Android toolchain by default, iOS with `SETUP_IOS=1`) and `scripts/setup-wsl-dev.sh` (WSL/Ubuntu), both idempotent. `scripts/run-dhu.sh` starts the Android Auto Desktop Head Unit from WSL.
- Toolchain aligned with Capacitor 7: Node.js 20, JDK 21, Android compile/target SDK 36, minimum Android 7 (API 24).

## Documentation

- [docs/ios-sideload.md](docs/ios-sideload.md) — installing the iOS build on your own iPhone or iPad with a free Apple ID (SideStore, iloader), updates from the source feed, limits and troubleshooting.
- [docs/native-tts-player-design.md](docs/native-tts-player-design.md) — design and implementation status of the native read aloud player (architecture, plugin contract, Android and iOS engines, Android Auto integration, progress sync, test plan).

## Contributing

This application is built using [NuxtJS](https://nuxtjs.org/) and [Capacitor](https://capacitorjs.com/) in order to run on both iOS and Android on the same code base.

Fork-specific changes live in this repository; changes that make sense for everyone are best sent upstream to [advplyr/audiobookshelf-app](https://github.com/advplyr/audiobookshelf-app).

### Localization

Thank you to [Weblate](https://hosted.weblate.org/engage/audiobookshelf/) for hosting the localization infrastructure of the upstream project pro-bono. Upstream strings arrive through Weblate; the strings added by this fork are currently maintained in `strings/en-us.json` and `strings/cs.json` only. <a href="https://hosted.weblate.org/engage/audiobookshelf/"> <img src="https://hosted.weblate.org/widget/audiobookshelf/abs-mobile-app/horizontal-auto.svg" alt="Translation status" /> </a>

### Quick setup with the scripts

On macOS:

```shell
./scripts/setup-macos-dev.sh              # Android toolchain, emulator and an AVD
SETUP_IOS=1 ./scripts/setup-macos-dev.sh  # also Xcode + CocoaPods
```

On WSL (Ubuntu/Debian):

```shell
./scripts/setup-wsl-dev.sh
```

Both scripts install Node.js 20, JDK 21 and the Android SDK, run `npm install`, build the web assets and sync the native projects. The manual steps below do the same.

### Windows Environment Setup for Android

Required Software:

- [Git](https://git-scm.com/downloads)
- [Node.js](https://nodejs.org/en/) (version 20)
- JDK 21 (Android Studio bundles one)
- Code editor of choice ([VSCode](https://code.visualstudio.com/download), etc)
- [Android Studio](https://developer.android.com/studio)
- [Android SDK](https://developer.android.com/studio) (compile SDK 36)

<details>
<summary>Install the required software with <a href="https://docs.microsoft.com/en-us/windows/package-manager/winget/#production-recommended">winget</a></summary>

<p>
Note: This requires a PowerShell prompt with winget installed.  You should be able to copy and paste the code block to install.  If you use an elevated PowerShell prompt, UAC will not pop up during the installs.

```PowerShell
winget install -e --id Git.Git; `
winget install -e --id Microsoft.VisualStudioCode; `
winget install -e --id  Google.AndroidStudio; `
winget install -e --id OpenJS.NodeJS --version 20.11.0;
```

![](/screenshots/dev_setup_windows_winget.png)

</p>
</details>
<br>

Your Windows environment should now be set up and ready to proceed!

### Mac Environment Setup for Android

Required Software:

- [Android Studio](https://developer.android.com/studio)
- [Node.js](https://nodejs.org/en/) (version 20)
- JDK 21
- [Cocoapods](https://guides.cocoapods.org/using/getting-started.html#installation)
- [Android SDK](https://developer.android.com/studio) (compile SDK 36)

<details>
<summary>Install the required software with <a href="https://brew.sh/">homebrew</a></summary>

<p>

```zsh
brew install android-studio node@20 openjdk@21 cocoapods
```

</p>
</details>

### Start working on the Android app

Clone or fork the project from terminal or powershell and `cd` into the project directory.

Install the required node packages:

```shell
npm install
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_android_npm_install.png)

</details>
<br>

Generate static web app:

```shell
npm run generate
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_android_npm_run.png)

</details>
<br>

Copy web app into native android/ios folders:

```shell
npx cap sync
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_android_cap_sync.png)

</details>
<br>

Open Android Studio:

```shell
npx cap open android
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_cap_android.png)

</details>
<br>

Start coding!

After making changes to the JS layer you need to rebuild the nuxt pages and sync them to the native shells:

```shell
npm run sync
```

Build a debug APK from the command line and run the Android unit tests:

```shell
./android/gradlew assembleDebug -p android
./android/gradlew testDebugUnitTest -p android
```

### Mac Environment Setup for iOS

Required Software:

- [Xcode](https://developer.apple.com/xcode/)
- [Node.js](https://nodejs.org/en/) (version 20)
- [Cocoapods](https://guides.cocoapods.org/using/getting-started.html#installation)

### Start working on the iOS app

Clone or fork the project in the terminal and `cd` into the project directory.

Install the required node packages:

```shell
npm install
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_ios_npm_install.png)

</details>
<br>

Generate static web app:

```shell
npm run generate
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_ios_npm_generate.png)

</details>
<br>

Copy web app into native android/ios folders:

```shell
npx cap sync
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_ios_cap_sync.png)

</details>
<br>

Open Xcode:

```shell
npx cap open ios
```

<details>
<summary>Expand for screenshot</summary>

![](/screenshots/dev_setup_ios_cap_open.png)

</details>
<br>

Start coding!

After making changes to the JS layer you need to rebuild the nuxt pages and sync them to the native shells:

```shell
npm run sync
```

To run the app on your own iPhone without a paid developer account, see the Xcode section of [docs/ios-sideload.md](docs/ios-sideload.md#11-alternative-build-and-install-from-xcode).

### Testing Android Auto without a car

Use the Desktop Head Unit (DHU) from the Android SDK. With current Android Auto versions the DHU only works in USB accessory mode (`desktop-head-unit --usb`, phone on a cable with USB debugging on). `scripts/run-dhu.sh` wraps the launch from WSL; the details and the test matrix are in [docs/native-tts-player-design.md](docs/native-tts-player-design.md#a9-f1-test-plan).
