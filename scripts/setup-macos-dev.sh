#!/usr/bin/env bash
#
# Development environment setup for the Audiobookshelf mobile app on macOS.
#
# Assumes a fresh machine with git/gh and your editor already installed.
# Installs everything else the project currently needs:
#   - Homebrew
#   - Node.js 20 (readme requirement, Nuxt 2 + Capacitor 7 CLI)
#   - OpenJDK 21 (required by the Capacitor 7 / AGP 8.8 Android build)
#   - Android command line tools + SDK (platform-tools, API 35, build-tools 35)
#   - Android emulator + API 35 system image + a ready-to-use AVD
#     (skip with SKIP_EMULATOR=1)
#   - project npm dependencies, web asset build and Capacitor sync
#
# Development currently targets Android only, so the iOS toolchain
# (full Xcode + CocoaPods) is NOT set up by default - opt in with SETUP_IOS=1.
# Android Studio is NOT installed by default either (any editor + the command
# line workflow below is enough). Opt in with INSTALL_ANDROID_STUDIO=1.
#
# The script is idempotent - safe to re-run.
#
# Usage: ./scripts/setup-macos-dev.sh
#        SKIP_EMULATOR=1 ./scripts/setup-macos-dev.sh
#        INSTALL_ANDROID_STUDIO=1 ./scripts/setup-macos-dev.sh
#        SETUP_IOS=1 ./scripts/setup-macos-dev.sh

set -euo pipefail

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS only." && exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

ARCH="$(uname -m)"   # arm64 (Apple Silicon) or x86_64 (Intel)

# ---------------------------------------------------------------- Homebrew
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# Make brew available in this shell (Apple Silicon vs Intel path)
if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
if [[ -x /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
log "Homebrew $(brew --version | head -1) ready"

# ---------------------------------------------------------------- Node.js 20
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]]; then
  log "Installing Node.js 20"
  brew install node@20
  brew link --overwrite node@20
else
  log "Node.js $(node -v) already installed"
fi

# ---------------------------------------------------------------- OpenJDK 21
# Capacitor 7 pins the Android build to Java 21 (capacitor.build.gradle).
log "Installing OpenJDK 21 (required by the Android Gradle build)"
brew list openjdk@21 >/dev/null 2>&1 || brew install openjdk@21
JAVA_HOME_21="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export JAVA_HOME="$JAVA_HOME_21"

# ---------------------------------------------------------------- Android SDK
log "Installing Android command line tools"
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_HOME
mkdir -p "$ANDROID_HOME"

SDKMANAGER="$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"
# Prefer the copy installed inside the SDK once it exists (kept current by itself)
[[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]] && SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -x "$SDKMANAGER" ]]; then
  SDKMANAGER="$(command -v sdkmanager || true)"
fi

if [[ -x "$SDKMANAGER" ]]; then
  log "Installing Android SDK packages (API 35 - matches android/variables.gradle)"
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
    "cmdline-tools;latest" \
    "platform-tools" \
    "platforms;android-35" \
    "build-tools;35.0.0" >/dev/null

  if [[ "${SKIP_EMULATOR:-0}" != "1" ]]; then
    log "Installing Android emulator + API 35 system image (SKIP_EMULATOR=1 to skip)"
    if [[ "$ARCH" == "arm64" ]]; then
      SYS_IMAGE="system-images;android-35;google_apis;arm64-v8a"
    else
      SYS_IMAGE="system-images;android-35;google_apis;x86_64"
    fi
    "$SDKMANAGER" --sdk_root="$ANDROID_HOME" "emulator" "$SYS_IMAGE" >/dev/null || warn "emulator/system image install failed"

    AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
    AVD_NAME="audiobookshelf-dev"
    if [[ -x "$AVDMANAGER" && ! -d "$HOME/.android/avd/$AVD_NAME.avd" ]]; then
      log "Creating Android virtual device '$AVD_NAME' (Pixel 7, API 35)"
      echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYS_IMAGE" -d pixel_7 >/dev/null \
        || warn "AVD creation failed - create one manually with avdmanager"
    fi
  fi
else
  warn "sdkmanager not found - install SDK 35 manually (Android Studio SDK Manager or android-commandlinetools)"
fi

if [[ "${INSTALL_ANDROID_STUDIO:-0}" == "1" ]]; then
  log "Installing Android Studio (INSTALL_ANDROID_STUDIO=1)"
  brew list --cask android-studio >/dev/null 2>&1 || brew install --cask android-studio
fi

# local.properties points gradle at the SDK independent of shell env vars
if [[ ! -f "$REPO_DIR/android/local.properties" ]]; then
  log "Writing android/local.properties (sdk.dir)"
  echo "sdk.dir=$ANDROID_HOME" > "$REPO_DIR/android/local.properties"
fi

# ---------------------------------------------------------------- iOS toolchain
# Off by default - development currently targets Android only. SETUP_IOS=1
# opts in; Capacitor 7 then needs full Xcode 16+ (App Store), not just the
# Command Line Tools.
HAS_XCODE=0
if [[ "${SETUP_IOS:-0}" == "1" ]]; then
  XCODE_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$XCODE_DEV_DIR" == *"Xcode"*.app* ]] && command -v xcodebuild >/dev/null 2>&1; then
    HAS_XCODE=1
    log "Xcode found: $(xcodebuild -version | head -1)"
    log "Installing CocoaPods"
    brew list cocoapods >/dev/null 2>&1 || brew install cocoapods
  else
    warn "SETUP_IOS=1 but full Xcode not found (only Command Line Tools or nothing) - skipping iOS."
    warn "Install Xcode from the App Store, run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer',"
    warn "accept the license with 'sudo xcodebuild -license accept', then re-run with SETUP_IOS=1."
  fi
fi

# ---------------------------------------------------------------- shell env
# Persist environment for future shells
SHELL_RC="$HOME/.zshrc"
touch "$SHELL_RC"
# migrate JAVA_HOME from the JDK 17 this script used to install
sed -i '' 's|export JAVA_HOME=".*openjdk@17.*"|export JAVA_HOME="'"$JAVA_HOME_21"'"|' "$SHELL_RC" 2>/dev/null || true
if ! grep -q "ANDROID_HOME" "$SHELL_RC" 2>/dev/null; then
  log "Adding ANDROID_HOME and JAVA_HOME to $SHELL_RC"
  {
    echo ''
    echo '# Audiobookshelf app dev environment'
    echo "export ANDROID_HOME=\"$ANDROID_HOME\""
    echo "export JAVA_HOME=\"$JAVA_HOME_21\""
    echo 'export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$PATH"'
  } >> "$SHELL_RC"
fi

# ---------------------------------------------------------------- project
log "Installing npm dependencies"
npm ci

log "Building web assets (nuxt generate - takes a few minutes)"
npm run generate

log "Syncing Capacitor Android project"
npx cap sync android || warn "cap sync android failed - check the Android SDK setup"

if [[ "$HAS_XCODE" == "1" ]]; then
  log "Syncing Capacitor iOS project (runs pod install)"
  npx cap sync ios || warn "cap sync ios failed - check Xcode/CocoaPods setup"
fi

log "Done"
cat <<EOT

Open a NEW terminal (so PATH/JAVA_HOME are picked up), then:

Web dev server (browser):
  npm run dev                     # http://localhost:1337

Android - command line workflow:
  npm run generate && npx cap sync android    # after JS changes (or: npm run sync)
  cd android && ./gradlew assembleDebug
  # APK: android/app/build/outputs/apk/debug/app-debug.apk
  adb install -r android/app/build/outputs/apk/debug/app-debug.apk

Android - emulator / live reload:
  emulator -avd audiobookshelf-dev &
  npx cap run android             # pick the emulator or a USB device
  npm run dev & npx cap run android -l --external    # live reload

iOS toolchain is not set up by default (Android-only development);
re-run with SETUP_IOS=1 once there is a way to test on iOS.

Android Studio was not installed (INSTALL_ANDROID_STUDIO=1 to add it);
open the android/ folder in it if you prefer, or just use your editor
with the command line workflow above.
EOT
