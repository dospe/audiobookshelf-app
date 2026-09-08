<template>
  <div v-if="show" :data-theme="ereaderTheme" class="group fixed top-0 left-0 right-0 layout-wrapper w-full z-40 pt-8 data-[theme=black]:bg-black data-[theme=black]:text-white data-[theme=dark]:bg-[#232323] data-[theme=dark]:text-white data-[theme=light]:bg-white data-[theme=light]:text-black" :class="{ 'reader-player-open': isPlayerOpen }">
    <!-- toolbar -->
    <div class="w-full px-2 fixed top-0 left-0 z-30 transition-transform bg-bg text-fg" :class="`${showingToolbar ? 'translate-y-0' : '-translate-y-36'} ${isIos ? 'pt-14 h-36' : 'pt-10 h-32'}`" :style="{ boxShadow: showingToolbar ? '0px 8px 8px #11111155' : '' }" @touchstart.stop @mousedown.stop @touchend.stop @mouseup.stop>
      <div class="flex items-center mb-2">
        <button type="button" class="inline-flex mx-2" @click.stop="show = false">
          <span class="material-symbols text-3xl text-fg">chevron_left</span>
        </button>
        <div class="flex-grow" />
        <button v-if="isComic || isEpub || isDocument" type="button" class="inline-flex mx-2" @click.stop="clickTOCBtn">
          <span class="material-symbols text-2xl text-fg">format_list_bulleted</span>
        </button>
        <button v-if="ttsAvailable" type="button" class="inline-flex mx-2" @click.stop="clickTTSBtn">
          <span class="material-symbols text-2xl" :class="showTTSBar ? 'text-warning' : 'text-fg'">record_voice_over</span>
        </button>
        <button v-if="isEpub || isDocument" type="button" class="inline-flex mx-2" @click.stop="clickSettingsBtn">
          <span class="material-symbols text-2xl text-fg">settings</span>
        </button>
        <button v-if="comicHasMetadata" type="button" class="inline-flex mx-2" @click.stop="clickMetadataBtn">
          <span class="material-symbols text-2xl text-fg">more</span>
        </button>
      </div>

      <p class="text-center truncate">{{ title }}</p>
    </div>

    <!-- ereader -->
    <component v-if="readerComponentName && progressReady" ref="readerComponent" :is="readerComponentName" :url="ebookUrl" :library-item="selectedLibraryItem" :is-local="isLocal" :keep-progress="keepProgress" :showing-toolbar="showingToolbar" :ebook-format="ebookFormat" @touchstart="touchstart" @touchend="touchend" @loaded="readerLoaded" @hook:mounted="readerMounted" @tts-state="ttsStateChanged" />
    <div v-else-if="readerComponentName" class="w-full h-full flex items-center justify-center">
      <ui-loading-indicator />
    </div>
    <div v-else class="w-full h-full flex items-center justify-center px-8">
      <p class="text-center text-fg-muted">{{ $getString('MessageUnsupportedEbookFormat', [ebookFormat || '']) }}</p>
    </div>

    <!-- read aloud (TTS) bar -->
    <!-- One row: playback controls on the side set in the reader settings (under the thumb when holding the phone one-handed), settings on the other side. Language and rate live in the settings dialog. -->
    <div v-if="showTTSBar && ttsAvailable" class="fixed left-0 w-full z-30 px-2 py-1.5 flex items-center bg-bg text-fg" :class="ttsControlsOnRight ? 'flex-row-reverse' : ''" :style="{ bottom: ttsBarBottom, boxShadow: '0px -8px 8px #11111155' }" @touchstart.stop @mousedown.stop @touchend.stop @mouseup.stop>
      <div class="flex items-center">
        <button type="button" :aria-label="$strings.ButtonSkipBack" class="tts-bar-btn" :class="{ 'opacity-40': ttsSkipInProgress }" :disabled="ttsSkipInProgress" @click.stop="clickTTSSkip(-1)">
          <span class="material-symbols text-4xl leading-none">fast_rewind</span>
        </button>
        <button type="button" :aria-label="$strings.ButtonPlay" class="tts-bar-btn" @click.stop="clickTTSPlayPause">
          <span class="material-symbols fill text-4xl leading-none">{{ ttsState === 'playing' ? 'pause_circle' : 'play_circle' }}</span>
        </button>
        <button type="button" :aria-label="$strings.ButtonSkipForward" class="tts-bar-btn" :class="{ 'opacity-40': ttsSkipInProgress }" :disabled="ttsSkipInProgress" @click.stop="clickTTSSkip(1)">
          <span class="material-symbols text-4xl leading-none">fast_forward</span>
        </button>
        <button type="button" :aria-label="$strings.ButtonStop" class="tts-bar-btn" :class="{ 'opacity-40': ttsState === 'stopped' }" :disabled="ttsState === 'stopped'" @click.stop="clickTTSStop">
          <span class="material-symbols text-4xl leading-none">stop</span>
        </button>
      </div>
      <div class="flex-grow" />
      <!-- Current language and rate at a glance; tap opens the settings -->
      <button type="button" :aria-label="$strings.HeaderReadAloudSettings" class="tts-bar-btn w-auto px-2" @click.stop="showTTSSettingsDialog = true">
        <span class="text-xs font-semibold text-fg-muted mr-1.5">{{ ttsLanguageLabel }} · {{ ereaderSettings.ttsRate }}×</span>
        <span class="material-symbols text-3xl leading-none">tune</span>
      </button>
    </div>

    <!-- table of contents modal -->
    <modals-fullscreen-modal v-model="showTOCModal" :theme="ereaderTheme">
      <div class="flex items-end justify-between h-20 px-4 pb-2">
        <h1 class="text-lg">{{ $strings.HeaderTableOfContents }}</h1>
        <button class="flex" @click.stop="showTOCModal = false">
          <span class="material-symbols">close</span>
        </button>
      </div>

      <!-- chapters list -->
      <div class="w-full overflow-y-auto overflow-x-hidden h-full max-h-[calc(100vh-85px)]">
        <div class="w-full h-full px-4">
          <ul>
            <li v-for="chapter in chapters" :key="chapter.id" class="py-1">
              <a :href="chapter.href" class="opacity-80 hover:opacity-100" @click.prevent="goToChapter(chapter.href)">{{ chapter.label }}</a>
              <ul v-if="chapter.subitems.length">
                <li v-for="subchapter in chapter.subitems" :key="subchapter.id" class="py-1 pl-4">
                  <a :href="subchapter.href" class="opacity-80 hover:opacity-100" @click.prevent="goToChapter(subchapter.href)">{{ subchapter.label }}</a>
                </li>
              </ul>
            </li>
          </ul>
          <div v-if="!chapters.length" class="flex h-full items-center justify-center">
            <p class="text-xl">{{ $strings.MessageNoChapters }}</p>
          </div>
        </div>
      </div>
    </modals-fullscreen-modal>

    <!-- ereader settings modal -->
    <modals-fullscreen-modal v-model="showSettingsModal" :theme="ereaderTheme" threeQuartersScreen>
      <div style="box-shadow: 0px -8px 8px #11111155">
        <div class="flex items-end justify-between h-14 px-4 pb-2 mb-6">
          <h1 class="text-lg">{{ $strings.HeaderEreaderSettings }}</h1>
          <button class="flex" @click="showSettingsModal = false">
            <span class="material-symbols">close</span>
          </button>
        </div>
        <div class="w-full overflow-y-auto overflow-x-hidden h-[calc(75vh-85px)] min-h-[320px] short:min-h-0 short:h-[calc(100vh-85px)]">
          <div class="w-full h-full px-4">
            <!-- Appearance and read aloud language are the settings of this book, the rest changes the defaults for all books -->
            <readers-ereader-settings-form :settings="ereaderSettings" :is-epub="isEpub" :is-document="isDocument" :tts-available="ttsAvailable" :language-hint="ttsLanguageHint" @change="settingChanged" @open-tts-settings="showTTSSettingsDialog = true">
              <div class="flex items-center mb-6">
                <div class="w-32">
                  <p class="text-sm">{{ $strings.LabelBookSettings }}</p>
                </div>
                <div>
                  <p class="text-xs text-fg-muted mb-2">{{ hasBookSettingsOverride ? $strings.MessageBookSettingsSaved : $strings.MessageBookSettingsDefault }}</p>
                  <ui-btn small :disabled="!hasBookSettingsOverride" @click="setBookSettingsAsDefault">{{ $strings.ButtonUseForAllBooks }}</ui-btn>
                </div>
              </div>
            </readers-ereader-settings-form>
          </div>
        </div>
      </div>
    </modals-fullscreen-modal>

    <!-- read aloud (TTS) engine/voice picker -->
    <modals-tts-settings-dialog v-model="showTTSSettingsDialog" :language="ereaderSettings.ttsLanguage" :language-items="ttsLanguageItems" :rate="ereaderSettings.ttsRate" :tts-engine="ereaderSettings.ttsEngine" :tts-voices="ereaderSettings.ttsVoices" :controls-side="ereaderSettings.ttsControlsSide" :page-step="ttsPageStep" :is-native="isNativeTTS" @update:language="setTTSLanguage" @update:rate="setTTSRateValue" @update:engine="setTTSEngine" @update:voice="setTTSVoice" @update:controlsSide="setTTSControlsSide" @update:pageStep="setTTSPageStep" />
  </div>
</template>

<script>
import { Capacitor } from '@capacitor/core'
import { VolumeButtons } from '@capacitor-community/volume-buttons'
import { KeepAwake } from '@capacitor-community/keep-awake'
import { isNativeTTSPlayerAvailable } from '@/plugins/capacitor/AbsTTSPlayer'
import { DEFAULT_EREADER_SETTINGS, ttsLanguageItems, ttsLanguageForBookLanguage, withTtsVoice } from '@/utils/ereaderSettings'

// Settings that are remembered per book (on the server) when they differ from
// the defaults of the book - the global defaults (store module `ereader`,
// edited on the app settings page) with the read aloud language taken from
// the book metadata when it is one of the offered languages. The rest (TTS
// rate and voice, volume buttons, ...) is global only: changing it in the
// reader changes the defaults.
const BOOK_SETTING_KEYS = ['theme', 'font', 'fontScale', 'lineSpacing', 'textStroke', 'spread', 'legacyEncoding', 'ttsLanguage']

export default {
  data() {
    return {
      touchstartX: 0,
      touchstartY: 0,
      touchendX: 0,
      touchendY: 0,
      touchstartTime: 0,
      touchIdentifier: null,
      showingToolbar: false,
      showTOCModal: false,
      showSettingsModal: false,
      showTTSBar: false,
      showTTSSettingsDialog: false,
      ttsState: 'stopped',
      ttsSkipInProgress: false,
      comicHasMetadata: false,
      chapters: [],
      isInittingWatchVolume: false,
      // The reader component mounts once the progress of the book is up to date (refreshItemProgress)
      progressReady: false,
      progressRefreshToken: 0,
      // True when the server copy of the progress in the store was fetched for this opening
      serverProgressRefreshed: false,
      // Global defaults as they were when the book was opened (see BOOK_SETTING_KEYS)
      globalEreaderSettings: null,
      // Per-book settings saved for the open book as loaded (server or cache), and the current diff from the book defaults
      bookSettingsLoaded: null,
      bookSettingsOverride: null,
      bookSettingsSaveTimeout: null,
      // Language declared by the ebook file itself, reported by the reader once it parsed the book
      ebookLanguage: null,
      ereaderSettings: { ...DEFAULT_EREADER_SETTINGS, ttsVoices: {} }
    }
  },
  watch: {
    show: {
      handler(newVal) {
        if (newVal) {
          this.comicHasMetadata = false
          this.ebookLanguage = null
          this.progressReady = false
          this.registerListeners()
          this.hideToolbar()
          this.prepareReader()
        } else {
          this.progressReady = false
          this.progressRefreshToken++
          this.unregisterListeners()
          this.$showHideStatusBar(true)
          this.showTTSBar = false
          this.ttsState = 'stopped'
        }
      }
    },
    isPlayerOpen(newVal, oldVal) {
      // Closed player
      if (!newVal && oldVal) {
        this.initWatchVolume()
      }
    }
  },
  computed: {
    show: {
      get() {
        return this.$store.state.showReader
      },
      set(val) {
        this.$store.commit('setShowReader', val)
      }
    },
    isIos() {
      return this.$platform === 'ios'
    },
    title() {
      return this.mediaMetadata.title || 'No Title'
    },
    selectedLibraryItem() {
      return this.$store.state.selectedLibraryItem
    },
    media() {
      return this.selectedLibraryItem?.media || null
    },
    mediaMetadata() {
      return this.media?.metadata || {}
    },
    ereaderTheme() {
      if (this.isEpub || this.isDocument) return this.ereaderSettings.theme
      return document.documentElement.dataset.theme || 'dark'
    },
    ttsLanguageLabel() {
      const item = this.ttsLanguageItems.find((i) => i.value === this.ereaderSettings.ttsLanguage)
      return item?.text || (this.ereaderSettings.ttsLanguage || '').split('-')[0].toUpperCase()
    },
    ttsLanguageItems() {
      return ttsLanguageItems()
    },
    /**
     * Read aloud language of the open book from its metadata: the library item
     * metadata (editable on the server) first, then the language the ebook
     * file declares. Null when unknown or not one of the offered languages.
     * @returns {string|null}
     */
    bookTtsLanguage() {
      return ttsLanguageForBookLanguage(this.mediaMetadata.language) || ttsLanguageForBookLanguage(this.ebookLanguage)
    },
    /** Defaults of the open book the per-book settings are compared against */
    bookDefaultSettings() {
      const defaults = { ...(this.globalEreaderSettings || this.$store.getters['ereader/getSettings']) }
      if (this.bookTtsLanguage) defaults.ttsLanguage = this.bookTtsLanguage
      return defaults
    },
    ttsLanguageHint() {
      if (!this.bookTtsLanguage || this.bookTtsLanguage !== this.ereaderSettings.ttsLanguage) return ''
      return this.$strings.MessageReadAloudLanguageFromBook
    },
    ttsControlsOnRight() {
      return this.ereaderSettings.ttsControlsSide !== 'left'
    },
    ttsPageStep() {
      const step = parseInt(this.ereaderSettings.ttsPageStep)
      return step > 0 ? step : 3
    },
    ttsBarBottom() {
      const playerOffset = this.isPlayerOpen ? 120 : 0
      // Epub and pdf readers show a bottom progress strip the bar sits above
      const progressStripOffset = this.isEpub || this.isPdf || this.isDocument ? 32 : 0
      return `${playerOffset + progressStripOffset}px`
    },
    readerComponentName() {
      if (this.ebookType === 'epub') return 'readers-epub-reader'
      else if (this.ebookType === 'mobi') return 'readers-mobi-reader'
      else if (this.ebookType === 'comic') return 'readers-comic-reader'
      else if (this.ebookType === 'pdf') return 'readers-pdf-reader'
      else if (this.ebookType === 'document') return 'readers-document-reader'
      return null
    },
    ebookFile() {
      if (!this.media) return null
      // ebook file id is passed when reading a supplementary ebook
      if (this.ebookFileId) {
        return this.selectedLibraryItem.libraryFiles.find((lf) => lf.ino === this.ebookFileId)
      }
      return this.media.ebookFile
    },
    ebookFormat() {
      if (!this.ebookFile) return null
      // Use file extension for supplementary ebook
      if (!this.ebookFile.ebookFormat) {
        return this.ebookFile.metadata.ext.toLowerCase().slice(1)
      }
      return this.ebookFile.ebookFormat
    },
    ebookType() {
      if (this.isMobi) return 'mobi'
      else if (this.isEpub) return 'epub'
      else if (this.isPdf) return 'pdf'
      else if (this.isComic) return 'comic'
      else if (this.isDocument) return 'document'
      return null
    },
    isEpub() {
      return this.ebookFormat == 'epub'
    },
    isMobi() {
      return this.ebookFormat == 'mobi' || this.ebookFormat == 'azw3'
    },
    isPdf() {
      return this.ebookFormat == 'pdf'
    },
    isComic() {
      return this.ebookFormat == 'cbz' || this.ebookFormat == 'cbr'
    },
    isDocument() {
      return ['doc', 'docx', 'rtf', 'pdb'].includes(this.ebookFormat)
    },
    ttsAvailable() {
      return this.isEpub || this.isMobi || this.isPdf || this.isDocument
    },
    isNativeTTS() {
      return isNativeTTSPlayerAvailable()
    },
    isLocal() {
      return !!this.ebookFile?.isLocal || !!this.ebookFile?.localFileId
    },
    localContentUrl() {
      return this.ebookFile?.contentUrl
    },
    ebookUrl() {
      if (!this.ebookFile) return null
      if (this.localContentUrl) {
        return Capacitor.convertFileSrc(this.localContentUrl)
      }

      if (this.ebookFileId) {
        return `/api/items/${this.selectedLibraryItem.id}/ebook/${this.ebookFileId}`
      }
      return `/api/items/${this.selectedLibraryItem.id}/ebook`
    },
    isPlayerOpen() {
      return this.$store.getters['getIsPlayerOpen']
    },
    keepProgress() {
      return this.$store.state.ereaderKeepProgress
    },
    /** Downloaded copy of the book, null when reading a streamed book that is not downloaded */
    localLibraryItem() {
      if (!this.selectedLibraryItem) return null
      if (this.isLocal) return this.selectedLibraryItem
      return this.selectedLibraryItem.localLibraryItem || null
    },
    /**
     * Server library item id the progress and the per-book settings are stored
     * under, null for local-only items or items of another server (same mapping
     * as the readers use)
     */
    serverLibraryItemId() {
      if (!this.selectedLibraryItem) return null
      if (!this.isLocal) return this.selectedLibraryItem.id
      if (!this.selectedLibraryItem.serverAddress || !this.selectedLibraryItem.libraryItemId) return null
      if (this.$store.getters['user/getServerAddress'] === this.selectedLibraryItem.serverAddress) {
        return this.selectedLibraryItem.libraryItemId
      }
      return null
    },
    bookSettingsServerId() {
      return this.serverLibraryItemId
    },
    bookSettingsCacheKey() {
      const id = this.bookSettingsServerId || this.selectedLibraryItem?.id
      return id ? `ereaderBookSettings:${id}` : null
    },
    hasBookSettingsOverride() {
      return !!this.bookSettingsOverride && Object.keys(this.bookSettingsOverride).length > 0
    },
    ebookFileId() {
      return this.$store.state.ereaderFileId
    }
  },
  methods: {
    settingsUpdated() {
      this.applyEreaderSettings()
      this.saveGlobalEreaderSettings()
      this.saveBookSettings()
    },
    /** Edit from the settings form */
    settingChanged(key, value) {
      if (!(key in this.ereaderSettings) || this.ereaderSettings[key] === value) return
      this.ereaderSettings[key] = value
      this.settingsUpdated()
    },
    applyEreaderSettings() {
      // Pass a copy so the reader component can detect which settings changed
      this.$refs.readerComponent?.updateSettings?.({ ...this.ereaderSettings })

      this.initWatchVolume()
      this.initKeepScreenAwake()
    },
    /**
     * Global settings are the defaults for every book. Per-book keys keep the
     * value they had when the book was opened, everything else is stored as is.
     */
    saveGlobalEreaderSettings() {
      const global = { ...this.ereaderSettings }
      if (this.globalEreaderSettings) {
        for (const key of BOOK_SETTING_KEYS) {
          if (this.globalEreaderSettings[key] !== undefined) global[key] = this.globalEreaderSettings[key]
        }
      }
      this.globalEreaderSettings = global
      this.$store.dispatch('ereader/save', global).catch((error) => {
        console.error('[Reader] Failed to save the ereader settings', error)
      })
    },
    /** Per-book settings that differ from the defaults of the book, or null */
    getBookSettingsDiff() {
      if (!this.globalEreaderSettings) return null
      const defaults = this.bookDefaultSettings
      const diff = {}
      for (const key of BOOK_SETTING_KEYS) {
        const value = this.ereaderSettings[key]
        if (value === undefined || value === null) continue
        if (value !== defaults[key]) diff[key] = value
      }
      return Object.keys(diff).length ? diff : null
    },
    saveBookSettings() {
      const diff = this.getBookSettingsDiff()
      const changed = JSON.stringify(diff) !== JSON.stringify(this.bookSettingsOverride)
      this.bookSettingsOverride = diff
      if (!changed) return
      this.cacheBookSettings(diff)

      clearTimeout(this.bookSettingsSaveTimeout)
      this.bookSettingsSaveTimeout = setTimeout(() => this.sendBookSettings(diff), 1000)
    },
    cacheBookSettings(diff) {
      if (!this.bookSettingsCacheKey) return
      try {
        if (diff) localStorage.setItem(this.bookSettingsCacheKey, JSON.stringify(diff))
        else localStorage.removeItem(this.bookSettingsCacheKey)
      } catch (error) {
        console.error('Failed to cache book settings', error)
      }
    },
    sendBookSettings(diff) {
      if (!this.bookSettingsServerId) return
      this.$nativeHttp.patch(`/api/me/progress/${this.bookSettingsServerId}`, { ebookSettings: diff }).catch((error) => {
        console.error('Failed to save book settings', error)
      })
    },
    /**
     * Per-book settings saved for the current book: from the server progress
     * when available, otherwise from the local cache (offline / local items).
     */
    loadBookSettingsOverride() {
      const serverProgress = this.bookSettingsServerId ? this.$store.getters['user/getUserMediaProgress'](this.bookSettingsServerId) : null
      const serverSettings = serverProgress?.ebookSettings && typeof serverProgress.ebookSettings === 'object' ? serverProgress.ebookSettings : null
      if (serverSettings) {
        this.cacheBookSettings(serverSettings)
        return serverSettings
      }
      // The store copy of the progress can lag behind the server (socket events
      // are lost while the app is in the background), so "no settings" in it
      // only counts when the progress was fetched for this opening - otherwise
      // it would wipe the settings saved a moment ago and reopen the book with
      // the global defaults
      if (serverProgress && serverProgress.ebookSettings === null && this.serverProgressRefreshed) {
        this.cacheBookSettings(null)
        return null
      }
      if (!this.bookSettingsCacheKey) return null
      try {
        const cached = localStorage.getItem(this.bookSettingsCacheKey)
        return cached ? JSON.parse(cached) : null
      } catch (error) {
        return null
      }
    },
    /** Make the current appearance settings and read aloud language the default for all books */
    setBookSettingsAsDefault() {
      const global = { ...(this.globalEreaderSettings || this.ereaderSettings) }
      for (const key of BOOK_SETTING_KEYS) global[key] = this.ereaderSettings[key]
      this.globalEreaderSettings = global
      this.$store.dispatch('ereader/save', global).catch((error) => {
        console.error('[Reader] Failed to save the ereader settings', error)
      })
      this.saveBookSettings()
    },
    goToChapter(href) {
      this.showTOCModal = false
      this.$refs.readerComponent?.goToChapter(href)
    },
    /**
     * Mount the reader once the progress of the book is up to date and the
     * global ereader settings are loaded (loadEreaderSettings reads them
     * synchronously when the reader mounts)
     */
    async prepareReader() {
      const token = ++this.progressRefreshToken
      const settingsLoad = this.$store.dispatch('ereader/load').catch((error) => {
        console.error('[Reader] Failed to load the ereader settings', error)
      })
      try {
        await this.refreshItemProgress(token)
      } catch (error) {
        console.error('[Reader] Failed to refresh the item progress', error)
      }
      await settingsLoad
      if (token === this.progressRefreshToken && this.show) this.progressReady = true
    },
    /**
     * Bring the progress of the book up to date before the reader mounts.
     *
     * The store only hears about progress written elsewhere - native read
     * aloud with the screen off, the car, another device - through socket
     * events, and those are lost while the WebView sits in the background. The
     * reader would then open at a stale position and mistake the stale copy of
     * the progress for "no per-book settings saved". Local progress is re-read
     * from the db (read aloud writes it directly), the server copy is fetched
     * with a short timeout, and a downloaded book takes over a newer reading
     * position from the server.
     * @param {number} token - aborts when the reader was closed or reopened meanwhile
     */
    async refreshItemProgress(token) {
      this.serverProgressRefreshed = false
      const localLibraryItem = this.localLibraryItem
      const serverLibraryItemId = this.serverLibraryItemId

      if (localLibraryItem) {
        await this.$store.dispatch('globals/loadLocalMediaProgress')
        if (token !== this.progressRefreshToken) return
      }

      if (!serverLibraryItemId || !this.$store.state.user.user || !this.$store.state.networkConnected) return

      const serverProgress = await this.$nativeHttp.get(`/api/me/progress/${serverLibraryItemId}`, { connectTimeout: 3000, readTimeout: 3000 }).catch((error) => {
        // 404 when the book was never opened on the server, otherwise offline or a slow server
        console.warn('[Reader] Could not refresh the server progress:', error?.message || error)
        return null
      })
      if (token !== this.progressRefreshToken) return
      if (!serverProgress?.libraryItemId || serverProgress.libraryItemId !== serverLibraryItemId) return

      this.serverProgressRefreshed = true
      this.$store.commit('user/updateUserMediaProgress', serverProgress)

      if (!localLibraryItem || !this.keepProgress) return
      // Downloaded book: the reader resumes from the local progress, so a newer
      // reading position on the server (read aloud in the car, another device)
      // is copied into it. Only the ebook position is taken over - audio
      // progress is reconciled by the player through its own paths.
      const serverHasEbookPosition = !!serverProgress.ebookLocation || Number(serverProgress.ebookProgress) > 0
      if (!serverHasEbookPosition) return
      const localProgress = this.$store.getters['globals/getLocalMediaProgressById'](localLibraryItem.id)
      if (localProgress && localProgress.lastUpdate >= serverProgress.lastUpdate) return
      if (localProgress && localProgress.ebookLocation === serverProgress.ebookLocation && localProgress.ebookProgress === serverProgress.ebookProgress) return

      const localResponse = await this.$db
        .updateLocalEbookProgress({
          localLibraryItemId: localLibraryItem.id,
          ebookLocation: serverProgress.ebookLocation || '',
          ebookProgress: Number(serverProgress.ebookProgress) || 0
        })
        .catch((error) => {
          console.error('[Reader] Failed to copy the server reading position to the local item', error)
          return null
        })
      if (localResponse?.localMediaProgress) {
        this.$store.commit('globals/updateLocalMediaProgress', localResponse.localMediaProgress)
      }
    },
    readerMounted() {
      // All readers need the settings for TTS; the epub reader also uses them for styling
      this.loadEreaderSettings()
    },
    readerLoaded(data) {
      if (this.isComic) {
        this.comicHasMetadata = data.hasMetadata
      }
      if (data?.language) this.ebookLanguageLoaded(data.language)
    },
    /**
     * The language the ebook file declares arrives once the reader parsed the
     * book, after the settings were loaded. A book without a read aloud
     * language of its own (library metadata or saved for the book) follows it.
     */
    ebookLanguageLoaded(language) {
      this.ebookLanguage = language
      if (!this.globalEreaderSettings || this.bookSettingsLoaded?.ttsLanguage) return
      const bookLanguage = this.bookTtsLanguage
      if (!bookLanguage || bookLanguage === this.ereaderSettings.ttsLanguage) return
      console.log(`[Reader] Read aloud language ${bookLanguage} from the ebook language "${language}"`)
      this.ereaderSettings.ttsLanguage = bookLanguage
      this.bookSettingsOverride = this.getBookSettingsDiff()
      this.applyEreaderSettings()
    },
    clickMetadataBtn() {
      this.$refs.readerComponent?.clickShowInfoMenu()
    },
    clickTOCBtn() {
      this.hideToolbar()
      if (this.isComic) {
        this.$refs.readerComponent?.clickShowPageMenu?.()
      } else {
        this.chapters = this.$refs.readerComponent?.chapters || []
        this.showTOCModal = true
      }
    },
    clickSettingsBtn() {
      this.hideToolbar()
      this.showSettingsModal = true
    },
    clickTTSBtn() {
      this.hideToolbar()
      if (this.showTTSBar) {
        this.$refs.readerComponent?.stopTTS?.()
        this.showTTSBar = false
      } else {
        this.showTTSBar = true
      }
    },
    clickTTSPlayPause() {
      const reader = this.$refs.readerComponent
      if (!reader?.startTTS) return
      if (this.ttsState === 'playing') {
        reader.pauseTTS()
      } else if (this.ttsState === 'paused') {
        reader.resumeTTS()
      } else {
        reader.startTTS()
      }
    },
    clickTTSStop() {
      this.$refs.readerComponent?.stopTTS?.()
    },
    /** Rewind (-1) / forward (1) by the configured number of pages, keeping the read aloud position in sync */
    async clickTTSSkip(direction) {
      const reader = this.$refs.readerComponent
      if (!reader?.ttsSkipPages || this.ttsSkipInProgress) return
      this.ttsSkipInProgress = true
      try {
        await reader.ttsSkipPages(direction)
      } finally {
        this.ttsSkipInProgress = false
      }
    },
    setTTSControlsSide(side) {
      this.ereaderSettings.ttsControlsSide = side === 'left' ? 'left' : 'right'
      this.settingsUpdated()
    },
    setTTSPageStep(pages) {
      const step = parseInt(pages)
      if (!(step > 0)) return
      this.ereaderSettings.ttsPageStep = step
      this.settingsUpdated()
    },
    setTTSEngine(engine) {
      this.ereaderSettings.ttsEngine = engine
      this.settingsUpdated()
    },
    setTTSVoice(voice) {
      // Voices are stored per language so the CZ/EN toggle keeps its own pick
      this.ereaderSettings.ttsVoices = withTtsVoice(this.ereaderSettings, voice).ttsVoices
      this.settingsUpdated()
    },
    setTTSRate(delta) {
      this.setTTSRateValue(Math.round((this.ereaderSettings.ttsRate + delta) * 100) / 100)
    },
    setTTSRateValue(rate) {
      const newRate = Number(rate)
      if (!(newRate >= 0.5 && newRate <= 2.5)) return
      this.ereaderSettings.ttsRate = newRate
      this.settingsUpdated()
    },
    setTTSLanguage(lang) {
      if (!lang || lang === this.ereaderSettings.ttsLanguage) return
      this.ereaderSettings.ttsLanguage = lang
      this.settingsUpdated()
    },
    ttsStateChanged(state) {
      this.ttsState = state
      // A read aloud session of this book picked up from the background gets
      // its controls shown right away instead of after another tap
      if (state !== 'stopped') this.showTTSBar = true
    },
    next() {
      if (this.$refs.readerComponent && this.$refs.readerComponent.next) {
        this.$refs.readerComponent.next()
      }
    },
    prev() {
      if (this.$refs.readerComponent && this.$refs.readerComponent.prev) {
        this.$refs.readerComponent.prev()
      }
    },
    handleGesture() {
      // Touch must be less than 1s. Must be > 60px drag and X distance > Y distance
      const touchTimeMs = Date.now() - this.touchstartTime
      if (touchTimeMs >= 1000) {
        return
      }

      const touchDistanceX = Math.abs(this.touchendX - this.touchstartX)
      const touchDistanceY = Math.abs(this.touchendY - this.touchstartY)
      const touchDistance = Math.sqrt(Math.pow(this.touchstartX - this.touchendX, 2) + Math.pow(this.touchstartY - this.touchendY, 2))
      if (touchDistance < 30) {
        if (this.showSettingsModal) {
          this.showSettingsModal = false
        } else {
          this.toggleToolbar()
        }
        return
      }

      if (touchDistanceX < 60 || touchDistanceY > touchDistanceX) {
        return
      }
      this.hideToolbar()
      if (!this.isEpub) {
        if (this.touchendX < this.touchstartX) {
          this.next()
        }
        if (this.touchendX > this.touchstartX) {
          this.prev()
        }
      }
    },
    showToolbar() {
      this.showingToolbar = true
      this.$showHideStatusBar(true)
    },
    hideToolbar() {
      this.showingToolbar = false
      this.$showHideStatusBar(false)
    },
    toggleToolbar() {
      if (this.showingToolbar) this.hideToolbar()
      else this.showToolbar()
    },
    touchstart(e) {
      // Ignore rapid touch
      if (this.touchstartTime && Date.now() - this.touchstartTime < 250) {
        return
      }

      this.touchstartX = e.touches[0].screenX
      this.touchstartY = e.touches[0].screenY
      this.touchstartTime = Date.now()
      this.touchIdentifier = e.touches[0].identifier
    },
    touchend(e) {
      if (this.touchIdentifier !== e.changedTouches[0].identifier) {
        return
      }

      this.touchendX = e.changedTouches[0].screenX
      this.touchendY = e.changedTouches[0].screenY
      this.handleGesture()
    },
    closeEvt() {
      this.show = false
    },
    loadEreaderSettings() {
      // The global defaults were loaded into the store before the reader mounted (prepareReader)
      const global = this.$store.getters['ereader/getSettings']
      for (const key in this.ereaderSettings) {
        if (global[key] === undefined) continue
        this.ereaderSettings[key] = key === 'ttsVoices' ? { ...global[key] } : global[key]
      }
      this.globalEreaderSettings = { ...this.ereaderSettings }

      // Defaults of this book: the read aloud language of the book metadata
      if (this.bookTtsLanguage) this.ereaderSettings.ttsLanguage = this.bookTtsLanguage

      // Apply the settings remembered for this book on top of the defaults
      clearTimeout(this.bookSettingsSaveTimeout)
      const override = this.loadBookSettingsOverride()
      this.bookSettingsLoaded = override
      this.bookSettingsOverride = null
      if (override) {
        for (const key of BOOK_SETTING_KEYS) {
          if (override[key] !== undefined && override[key] !== null) this.ereaderSettings[key] = override[key]
        }
        this.bookSettingsOverride = this.getBookSettingsDiff()
      }
      console.log(`[Reader] Read aloud language ${this.ereaderSettings.ttsLanguage} (book ${this.bookTtsLanguage || '-'}, default ${global.ttsLanguage})`)
      this.applyEreaderSettings()
    },
    async initWatchVolume() {
      if (this.isInittingWatchVolume || !(this.isEpub || this.isDocument)) return
      this.isInittingWatchVolume = true
      const isWatching = await VolumeButtons.isWatching()

      if (this.ereaderSettings.navigateWithVolume !== 'none' && (this.ereaderSettings.navigateWithVolumeWhilePlaying || !this.isPlayerOpen)) {
        if (!isWatching.value) {
          const options = {
            disableSystemVolumeHandler: true,
            suppressVolumeIndicator: true
          }
          await VolumeButtons.watchVolume(options, this.volumePressed)
        }
      } else if (isWatching.value) {
        await VolumeButtons.clearWatch().catch((error) => {
          console.error('Failed to clear volume watch', error)
        })
      }

      this.isInittingWatchVolume = false
    },
    async initKeepScreenAwake() {
      try {
        if (this.ereaderSettings.keepScreenAwake) {
          await KeepAwake.keepAwake()
          console.log('Reader keep screen awake enabled')
        } else {
          await KeepAwake.allowSleep()
          console.log('Reader keep screen awake disabled')
        }
      } catch (error) {
        console.error('Failed to init keep screen awake', error)
      }
    },
    registerListeners() {
      this.$eventBus.$on('close-ebook', this.closeEvt)
      document.body.addEventListener('touchstart', this.touchstart)
      document.body.addEventListener('touchend', this.touchend)
      this.initWatchVolume()
      this.initKeepScreenAwake()
    },
    unregisterListeners() {
      this.$eventBus.$on('close-ebook', this.closeEvt)
      document.body.removeEventListener('touchstart', this.touchstart)
      document.body.removeEventListener('touchend', this.touchend)
      VolumeButtons.clearWatch().catch((error) => {
        console.error('Failed to clear volume watch', error)
      })
      KeepAwake.allowSleep().catch((error) => {
        console.error('Failed to allow sleep', error)
      })
    },
    volumePressed(e) {
      if (this.ereaderSettings.navigateWithVolume == 'enabled') {
        if (e.direction == 'up') {
          this.prev()
        } else {
          this.next()
        }
      } else if (this.ereaderSettings.navigateWithVolume == 'mirrored') {
        if (e.direction == 'down') {
          this.prev()
        } else {
          this.next()
        }
      }
    }
  },
  beforeDestroy() {
    this.unregisterListeners()
  }
}
</script>

<style scoped>
/* Read aloud bar buttons: equal round tap targets with same-size icons */
.tts-bar-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 3rem;
  height: 3rem;
  border-radius: 9999px;
  color: rgb(var(--color-fg));
}
.tts-bar-btn:active {
  background-color: rgb(var(--color-fg) / 0.1);
}
</style>
