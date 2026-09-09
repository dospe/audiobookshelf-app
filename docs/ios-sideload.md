# iOS build for your own iPhone (free Apple ID, SideStore, iloader)

The iOS app is built in GitHub Actions (`.github/workflows/build-ios.yml`)
as an **unsigned IPA**. Signing happens on the phone: **SideStore** signs the
app with your (free) Apple ID and renews the signature every week by itself.
No paid Apple Developer Program and no Mac for every install — a MacBook is
needed only once, to install SideStore.

The steps follow the official SideStore documentation (docs.sidestore.io, as
of 2026): installation through **iloader**, VPN **LocalDevVPN**. Older guides
built around AltServer, jitterbugpair, WireGuard or StosVPN are outdated for
SideStore.

Contents:

1. [How it all works](#1-how-it-all-works)
2. [What you need](#2-what-you-need)
3. [What to install on the MacBook](#3-what-to-install-on-the-macbook)
4. [Preparing the iPhone](#4-preparing-the-iphone)
5. [Installing SideStore with iloader](#5-installing-sidestore-with-iloader)
6. [Installing and updating Audiobookshelf](#6-installing-and-updating-audiobookshelf)
7. [Signature renewal (7 days)](#7-signature-renewal-7-days)
8. [Limits of a free Apple ID](#8-limits-of-a-free-apple-id)
9. [Troubleshooting](#9-troubleshooting)
10. [Alternative: AltStore + AltServer on the Mac](#10-alternative-altstore--altserver-on-the-mac)
11. [Alternative: build and install from Xcode](#11-alternative-build-and-install-from-xcode)
12. [What CI and the "IPA server" (source feed) do](#12-what-ci-and-the-ipa-server-source-feed-do)

## 1. How it all works

- **CI** (a macOS runner on GitHub, free for a public repository) builds an
  unsigned `audiobookshelf-ios.ipa` from every push. A push to `master` also
  attaches it to the **`latest-ios`** pre-release together with
  `sidestore-source.json` (the "source feed" — a list of apps and versions
  that SideStore understands).
- **SideStore** on the iPhone signs the IPA with the developer certificate of
  your Apple ID and installs it. The certificate of a free account is valid
  for **7 days**; SideStore renews it in the background (it needs LocalDevVPN
  switched on and Wi‑Fi to do so).
- Once the source feed is added to SideStore, every new build from `master`
  shows up as an **Update** and installs with one tap.
- **iloader** on the MacBook is used only once: it installs SideStore and
  stores a so-called pairing file on the phone (the file that lets SideStore
  "talk" to the system as if a computer were connected).

What the iOS build does and does not include:

- Included: the ebook reader with **native read aloud** (keeps running with
  the screen off, controls on the lock screen, in Control Center, from
  headphones and on the CarPlay "Now Playing" screen), reading position sync
  with the local database and the server, voice selection (voices are
  downloaded in Settings → Accessibility → Spoken Content → Voices). There is
  no engine selection on iOS; the system has only one.
- Not included and not planned: browsing and starting books from CarPlay (the
  Android Auto tree does not carry over). A CarPlay audio app needs an
  entitlement that Apple grants to paid accounts, and a sideloaded build
  cannot carry it.

## 2. What you need

| What | Note |
| --- | --- |
| iPhone with iOS/iPadOS **15.0+** and a passcode set | per the SideStore prerequisites; Developer Mode on iOS 16+ |
| MacBook (macOS High Sierra+) | only for the first SideStore install; everything else works without a computer |
| USB cable Mac ↔ iPhone | for iloader during the install and when renewing the pairing file |
| Apple ID | a free account is enough; SideStore recommends a **separate Apple ID** just for sideloading (the account is used as a developer account, there is no reason to risk your main one) |
| Wi‑Fi | installing and renewing signatures require Wi‑Fi, mobile data is not enough |
| ~30 minutes | for the first install including possible troubleshooting |

## 3. What to install on the MacBook

### 3.1 iloader (required)

**iloader** is the official SideStore installer (idevice project / nab138).
Download it **only** from the official places: <https://iloader.app> or
<https://github.com/nab138/iloader/releases> (the macOS file). Do not use
other sites offering an "iloader".

1. Download the macOS package from the releases, open it and drag `iloader`
   into Applications.
2. On first launch macOS may complain about an unverified developer — allow
   it in System Settings → Privacy & Security ("Open Anyway").
3. Nothing else is needed: on macOS there is no need for iTunes (Finder sees
   the device) or for any pairing file tool — iloader takes care of that.

### 3.2 Optional: AltServer

Only if you want the classic **AltStore** instead of SideStore (chapter 10).
SideStore does **not** need AltServer. Download from <https://altstore.io>;
requires macOS 11+ (version 1.6.2 for macOS 10.14/10.15). Since version 1.7
it no longer needs the Mail plug‑in.

### 3.3 Optional: tools for a local build

Only if you want to build the IPA yourself instead of using CI (chapter 11):
Xcode from the App Store, Node.js 20 and CocoaPods — the steps are in
`readme.md` under "Mac Environment Setup for iOS" (`brew install node
cocoapods`).

## 4. Preparing the iPhone

1. Install **LocalDevVPN** from the App Store (publisher Coxson Engineering
   LLC; <https://apps.apple.com/app/id6755608044>). It is a free app with a
   local VPN tunnel entitlement, through which SideStore installs and renews
   apps without a computer.
2. Open LocalDevVPN, tap connect, allow adding the VPN configuration (iOS asks
   for the passcode) and **leave the VPN on** for the whole time you install,
   update or renew signatures.
3. **Developer Mode** (iOS 16+): Settings → Privacy & Security → Developer
   Mode → turn on → the phone restarts → confirm. The item only appears after
   the first connection to iloader / the first developer app install; if you
   do not see it, come back to it after step 5.
4. Settings → General → Background App Refresh: allow it (globally and later
   for SideStore), otherwise signatures will not renew on their own.

## 5. Installing SideStore with iloader

On the MacBook:

1. Connect the iPhone with the cable, unlock it and confirm **Trust This
   Computer** on the phone (enter the passcode).
2. Launch **iloader**. Sign in with the Apple ID (the password goes only to
   Apple; the credentials are **case-sensitive**). With two-factor
   authentication, type in the code from the phone.
3. Select the device and choose **Install SideStore (Stable)**. iloader
   uploads SideStore, registers the App ID and places the pairing file.
   (Support for iloader is provided by the idevice project's Discord, not
   SideStore's.)

On the iPhone:

4. Settings → General → **VPN & Device Management** → under "Developer App"
   tap your Apple ID → **Trust**. On iOS 18+ it offers "Allow & Restart" —
   confirm with the passcode, the phone restarts.
5. If **Developer Mode** has appeared (step 4.3), turn it on.
6. Turn on **LocalDevVPN**.
7. Open **SideStore** and sign in with the same Apple ID as in iloader.
8. **My Apps** tab → tap the **"7 DAYS"** counter next to SideStore → the
   first refresh runs. When it asks about certificate management, confirm
   "Yes" / "Refresh Now".

SideStore is now ready and the Mac is no longer needed (except for renewing
the pairing file after an iOS update or a reset — chapter 9).

## 6. Installing and updating Audiobookshelf

Always: **LocalDevVPN** on and **Wi‑Fi**.

### 6.1 Through the source feed (recommended — one-tap updates)

The feed is the `sidestore-source.json` file in the `latest-ios` release:

```
https://github.com/dospe/audiobookshelf-app/releases/download/latest-ios/sidestore-source.json
```

Adding it to SideStore:

- **With one link:** in Safari on the iPhone paste
  `sidestore://source?url=https://github.com/dospe/audiobookshelf-app/releases/download/latest-ios/sidestore-source.json`
  into the address bar and confirm opening in SideStore. (The link is also in
  the release notes; GitHub shows it as plain text, so copy it.)
- **Manually:** SideStore → **Browse** tab → **Sources** (top left) → **+**
  → paste the feed URL → Add.

Then: Browse → source "Audiobookshelf (dospe)" → **Audiobookshelf** →
**Install** (sign in with the Apple ID, wait a moment). The app appears on the
home screen.

**Updates:** after every push to `master` CI replaces the release with a new
build carrying a higher version number (`<major>.<minor>.<run number>`,
currently `0.14.<run number>`). The next time SideStore is opened (or checks
in the background) it shows **Update** next to the app (My Apps / Browse) —
tap Update. App data (login, downloaded books, progress) is kept.

### 6.2 Direct link to the IPA

In Safari paste
`sidestore://install?url=https://github.com/dospe/audiobookshelf-app/releases/download/latest-ios/audiobookshelf-ios.ipa`
— SideStore downloads and installs the IPA. Updates work the same way, except
that SideStore does not know about new versions by itself.

### 6.3 Manually from a file

1. In Safari open the releases → `latest-ios` → download
   `audiobookshelf-ios.ipa` (it ends up in Files → Downloads). For a build of a
   specific branch download the `audiobookshelf-ipa` artifact from the
   workflow run (it is a zip with the IPA and the feed inside).
2. SideStore → **My Apps** → **+** (top left) → pick the IPA in Files. Or
   long-press the IPA in Files → Share → **SideStore**.

Installing over the existing app = an update, the data is kept.

### 6.4 iPad

The same IPA installs on an iPad as well (the project targets both iPhone and
iPad, all orientations, Split View / Stage Manager). The interface is the
phone layout stretched to the width; the EPUB reader shows two pages side by
side on a wide display (the reader "spread" setting, default auto). The
SideStore steps are identical, iPadOS 15+.

**Two devices with one free Apple ID:** a free account has a single developer
certificate. Installing or refreshing SideStore on the second device renews
it and invalidates the signatures on the first — the apps there will not
launch until they are refreshed again, and the two devices can keep taking
the certificate from each other (SideStore issue #978, AltStore #1597). The
simplest approach is a **separate free Apple ID for each device**; each then
also has its own limits from chapter 8.

## 7. Signature renewal (7 days)

- The signature (and with it the ability to launch) expires **7 days** after
  signing. SideStore renews it **in the background** — conditions: LocalDevVPN
  on, Wi‑Fi, Background App Refresh allowed, and SideStore opened now and then
  (iOS does not schedule background work reliably for an app you have not
  launched in a long time).
- **Manually:** SideStore → My Apps → **Refresh All** (or tap the day counter
  next to a specific app). I recommend doing this once a week when opening
  SideStore.
- When the signature **expires**: the app will not launch ("Unable to Verify
  App" / the icon dims). The data is **not lost** — a Refresh in SideStore is
  enough. When SideStore itself has expired too, refreshing through it is not
  possible: install it again with iloader (Install SideStore, without
  uninstalling), then Refresh All.

## 8. Limits of a free Apple ID

| Limit | Impact |
| --- | --- |
| **3 sideloaded apps** at a time, **including SideStore** | Audiobookshelf plus one more; LocalDevVPN comes from the App Store and does not count |
| **10 App IDs per 7 days** | every (re)installed app takes an App ID for a week; on "Maximum number of App IDs" wait, overview in My Apps → View App IDs |
| **7 days** of signature validity | chapter 7 |
| No restricted entitlements | CarPlay, push notifications through APNs and the like are not possible; background audio (`UIBackgroundModes`) is a regular mode and works |
| Pairing file | must be renewed after an **iOS update or a reset**, occasionally it expires on its own (chapter 9) |

## 9. Troubleshooting

- **iloader does not see the iPhone:** unlock the phone, confirm "Trust", try
  another cable/port; the device must be visible in Finder.
- **Apple ID sign-in fails in SideStore:** check the letter case; change the
  **Anisette URL** in SideStore → Settings (older public anisette servers
  caused Apple ID lockouts, keep the official one). The two-factor code is
  entered at sign-in.
- **Refresh / install fails, "minimuxer" or connection errors:** turn on
  LocalDevVPN (not WireGuard/StosVPN from the old guides), be on Wi‑Fi, turn
  off DNS blockers, restart SideStore and the phone. If it persists: renew
  the pairing file (below).
- **Renewing the pairing file** (after an iOS update, a reset, or when
  SideStore reports an invalid pairing): connect the iPhone to the Mac, launch
  iloader → **Delete Stored Pairing** → select the device → Trust on the phone
  → **Manage Pairing File** → next to SideStore (and any other apps) **Place**
  → the message "Pairing file placed successfully!".
- **Install "hangs":** update SideStore, Settings → clear cache, change the
  Anisette server, reset `adi.pb`, restart, a new pairing file, or reinstall
  SideStore through iloader.
- **The app will not launch ("Untrusted Developer"):** Settings → General →
  VPN & Device Management → trust; on iOS 16+ turn on Developer Mode.
- **I do not see the update in the feed:** SideStore checks the sources when
  the Browse tab is opened (pull to refresh); check that the `latest-ios`
  release carries a new build (the version number in the release title).
- **Error codes:** docs.sidestore.io → Troubleshooting → Error codes. Support:
  the SideStore Discord (SideStore) and the idevice Discord (iloader).

## 10. Alternative: AltStore + AltServer on the Mac

The classic AltStore renews signatures through **AltServer running on a Mac on
the same Wi‑Fi** — so the Mac has to be on and within reach, otherwise the
apps lock after 7 days. For a MacBook that gets closed and carried away,
SideStore is the better fit.

If you still want AltStore:

1. Download AltServer from <https://altstore.io>, drag `AltServer.app` into
   Applications and launch it — it appears in the menu bar. Requires macOS 11+.
2. In Finder select the iPhone → enable **"Show this iPhone when on Wi‑Fi"**
   (Wi‑Fi syncing), so that AltServer works without the cable.
3. Connect the iPhone with the cable, unlock it, trust the computer. AltServer
   icon → **Install AltStore** → select the device → enter the Apple ID.
   (AltServer 1.7+ does not need the Mail plug‑in; if an older version asks
   for it, follow its dialog.)
4. On the iPhone trust the developer app (Settings → General → VPN & Device
   Management) and turn on Developer Mode (iOS 16+).
5. Install the IPA either in AltStore (My Apps → +) or from the Mac: hold
   **⌥ Option** and click the AltServer icon → **Sideload .ipa…** → pick
   `audiobookshelf-ios.ipa`.
6. The source feed from chapter 6.1 works in AltStore too (Sources → +); the
   link `altstore://source?url=…` is the counterpart of `sidestore://`.
7. Let AltServer start at login so the background renewal keeps running.

## 11. Alternative: build and install from Xcode

Without CI, straight from the MacBook (Xcode, Node 20 and CocoaPods required):

```bash
npm ci && npm run generate && npx cap sync ios
open ios/App/App.xcworkspace
```

In Xcode: target `Audiobookshelf` → Signing & Capabilities → Team = your
personal team (the free Apple ID added in Xcode → Settings → Accounts); change
the Bundle Identifier if Apple reports a collision. Connect the iPhone
(Developer Mode), select it as the destination and **Run**. The signature is
valid for 7 days and only renews with another run from Xcode — for everyday
use SideStore is more convenient.

## 12. What CI and the "IPA server" (source feed) do

The workflow `.github/workflows/build-ios.yml` (`macos-15`, ~5 minutes):

1. `npm ci && npm run generate && npx cap sync ios` (including `pod install`).
2. `xcodebuild archive` without signing (`CODE_SIGNING_ALLOWED=NO`), Release
   configuration, bundle id `com.audiobookshelf.app`. The version number is
   `<major>.<minor>.<run number>` from the `MARKETING_VERSION` in the Xcode
   project and the build number is the run number, so every build has a
   different version (SideStore uses it to detect an update; it is visible in
   the app's Settings → About).
3. Packs `Payload/Audiobookshelf.app` into `audiobookshelf-ios.ipa` and
   generates `sidestore-source.json` with the script
   `scripts/make-sidestore-source.py` (AltSource format: `name`,
   `bundleIdentifier`, `versions[]` with `version`, `buildVersion`, `date`,
   `downloadURL`, `size`, `sha256`; without `marketplaceID`, which SideStore
   would reject).
4. Uploads both files as the `audiobookshelf-ipa` artifact; on `master` it
   also deletes and recreates the **`latest-ios`** pre-release with both files
   and `sidestore://` links in the notes. That gives the IPA and the feed a
   **stable URL** that SideStore watches.

So the "IPA server" is nothing running on your side — it is GitHub Releases.
Should the feed ever need to be hosted elsewhere (your own site, GitHub
Pages), copying `sidestore-source.json` and adjusting `downloadURL` is
enough; the format stays the same. The feed can also carry several versions
(add entries to `versions`); CI currently keeps only the latest build.

Useful links: SideStore docs <https://docs.sidestore.io>, iloader
<https://iloader.app>, LocalDevVPN <https://apps.apple.com/app/id6755608044>,
AltStore FAQ <https://faq.altstore.io>, source format
<https://faq.altstore.io/developers/make-a-source>.
