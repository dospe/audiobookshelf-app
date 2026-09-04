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
    <component v-if="readerComponentName" ref="readerComponent" :is="readerComponentName" :url="ebookUrl" :library-item="selectedLibraryItem" :is-local="isLocal" :keep-progress="keepProgress" :showing-toolbar="showingToolbar" :ebook-format="ebookFormat" @touchstart="touchstart" @touchend="touchend" @loaded="readerLoaded" @hook:mounted="readerMounted" @tts-state="ttsStateChanged" />
    <div v-else class="w-full h-full flex items-center justify-center px-8">
      <p class="text-center text-fg-muted">{{ $getString('MessageUnsupportedEbookFormat', [ebookFormat || '']) }}</p>
    </div>

    <!-- read aloud (TTS) bar -->
    <!-- Playback controls sit on the side set in the reader settings so they stay under the thumb when holding the phone one-handed -->
    <div v-if="showTTSBar && ttsAvailable" class="fixed left-0 w-full z-30 px-3 py-2 flex flex-col bg-bg text-fg" :style="{ bottom: ttsBarBottom, boxShadow: '0px -8px 8px #11111155' }" @touchstart.stop @mousedown.stop @touchend.stop @mouseup.stop>
      <!-- Language, rate and voice settings; mirrored so they stay away from the playback controls -->
      <div class="flex items-center mb-1" :class="ttsControlsOnRight ? '' : 'flex-row-reverse'">
        <ui-toggle-btns v-model="ereaderSettings.ttsLanguage" name="tts-language" :items="ttsLanguageItems" @input="settingsUpdated" />
        <div class="flex items-center mx-3">
          <button type="button" class="inline-flex" @click.stop="setTTSRate(-0.25)">
            <span class="material-symbols text-2xl text-fg">remove</span>
          </button>
          <p class="text-sm w-10 text-center">{{ ereaderSettings.ttsRate }}×</p>
          <button type="button" class="inline-flex" @click.stop="setTTSRate(0.25)">
            <span class="material-symbols text-2xl text-fg">add</span>
          </button>
        </div>
        <button type="button" :aria-label="$strings.HeaderReadAloudSettings" class="inline-flex" @click.stop="showTTSSettingsDialog = true">
          <span class="material-symbols text-2xl text-fg">tune</span>
        </button>
      </div>
      <!-- Playback controls on the side set in the reader settings so they are under the thumb when holding the phone one-handed -->
      <div class="flex items-center" :class="ttsControlsOnRight ? 'justify-end' : 'justify-start'">
        <button type="button" :aria-label="$strings.ButtonSkipBack" class="inline-flex flex-col items-center mx-1" :class="ttsSkipInProgress ? 'opacity-40' : ''" :disabled="ttsSkipInProgress" @click.stop="clickTTSSkip(-1)">
          <span class="material-symbols text-4xl leading-none text-fg">fast_rewind</span>
          <span class="text-[10px] font-semibold leading-tight">{{ ttsPageStep }}</span>
        </button>
        <button type="button" :aria-label="$strings.ButtonPlay" class="inline-flex mx-1" @click.stop="clickTTSPlayPause">
          <span class="material-symbols fill text-6xl leading-none text-fg">{{ ttsState === 'playing' ? 'pause_circle' : 'play_circle' }}</span>
        </button>
        <button type="button" :aria-label="$strings.ButtonSkipForward" class="inline-flex flex-col items-center mx-1" :class="ttsSkipInProgress ? 'opacity-40' : ''" :disabled="ttsSkipInProgress" @click.stop="clickTTSSkip(1)">
          <span class="material-symbols text-4xl leading-none text-fg">fast_forward</span>
          <span class="text-[10px] font-semibold leading-tight">{{ ttsPageStep }}</span>
        </button>
        <button type="button" :aria-label="$strings.ButtonStop" class="inline-flex mx-1" :class="ttsState === 'stopped' ? 'opacity-40' : ''" :disabled="ttsState === 'stopped'" @click.stop="clickTTSStop">
          <span class="material-symbols text-4xl leading-none text-fg">stop</span>
        </button>
      </div>
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
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelTheme }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.theme" name="theme" :items="themeItems" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelFontFamily }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.font" name="font" :items="fontItems" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelFontScale }}</p>
              </div>
              <ui-range-input v-model="ereaderSettings.fontScale" :min="5" :max="300" :step="5" input-width="180px" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelLineSpacing }}</p>
              </div>
              <ui-range-input v-model="ereaderSettings.lineSpacing" :min="100" :max="300" :step="5" input-width="180px" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelFontBoldness }}</p>
              </div>
              <ui-range-input v-model="ereaderSettings.textStroke" :min="0" :max="300" :step="5" input-width="180px" @input="settingsUpdated" />
            </div>
            <div v-if="isEpub" class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelLayout }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.spread" name="spread" :items="spreadItems" @input="settingsUpdated" />
            </div>
            <div v-if="isDocument" class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelTextEncoding }}</p>
              </div>
              <ui-dropdown v-model="ereaderSettings.legacyEncoding" :items="legacyEncodingItems" small class="flex-grow max-w-[200px]" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelNavigateWithVolume }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.navigateWithVolume" name="navigate-volume" :items="navigateWithVolumeItems" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelNavigateWithVolumeWhilePlaying }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.navigateWithVolumeWhilePlaying" name="navigate-volume-playing" :items="onOffToggleButtonItems" @input="settingsUpdated" />
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelKeepScreenAwake }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.keepScreenAwake" name="keep-awake" :items="onOffToggleButtonItems" @input="settingsUpdated" />
            </div>
            <div v-if="ttsAvailable" class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelReadAloudControlsSide }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.ttsControlsSide" name="tts-controls-side" :items="ttsControlsSideItems" @input="settingsUpdated" />
            </div>
            <div v-if="ttsAvailable" class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelReadAloudPageStep }}</p>
              </div>
              <ui-toggle-btns v-model="ereaderSettings.ttsPageStep" name="tts-page-step" :items="ttsPageStepItems" @input="settingsUpdated" />
            </div>
            <div v-if="ttsAvailable" class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelReadAloudVoice }}</p>
              </div>
              <ui-btn small @click="showTTSSettingsDialog = true">{{ $strings.HeaderReadAloudSettings }}</ui-btn>
            </div>
            <div class="flex items-center mb-6">
              <div class="w-32">
                <p class="text-sm">{{ $strings.LabelBookSettings }}</p>
              </div>
              <div>
                <p class="text-xs text-fg-muted mb-2">{{ hasBookSettingsOverride ? $strings.MessageBookSettingsSaved : $strings.MessageBookSettingsDefault }}</p>
                <ui-btn small :disabled="!hasBookSettingsOverride" @click="setBookSettingsAsDefault">{{ $strings.ButtonUseForAllBooks }}</ui-btn>
              </div>
            </div>
          </div>
        </div>
      </div>
    </modals-fullscreen-modal>

    <!-- read aloud (TTS) engine/voice picker -->
    <modals-tts-settings-dialog v-model="showTTSSettingsDialog" :language="ereaderSettings.ttsLanguage" :tts-engine="ereaderSettings.ttsEngine" :tts-voices="ereaderSettings.ttsVoices" :controls-side="ereaderSettings.ttsControlsSide" :page-step="ttsPageStep" :is-native="isNativeTTS" @update:engine="setTTSEngine" @update:voice="setTTSVoice" @update:controlsSide="setTTSControlsSide" @update:pageStep="setTTSPageStep" />
  </div>
</template>

<script>
import { Capacitor } from '@capacitor/core'
import { VolumeButtons } from '@capacitor-community/volume-buttons'
import { KeepAwake } from '@capacitor-community/keep-awake'
import { isNativeTTSPlayerAvailable } from '@/plugins/capacitor/AbsTTSPlayer'

// Settings that are remembered per book (on the server) when they differ from
// the global defaults. The rest (TTS voice, volume buttons, ...) is global only.
const BOOK_SETTING_KEYS = ['theme', 'font', 'fontScale', 'lineSpacing', 'textStroke', 'spread', 'legacyEncoding']

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
      globalEreaderSettings: null,
      bookSettingsOverride: null,
      bookSettingsSaveTimeout: null,
      ereaderSettings: {
        theme: 'dark',
        font: 'serif',
        fontScale: 100,
        lineSpacing: 115,
        spread: 'auto',
        textStroke: 0,
        legacyEncoding: '',
        navigateWithVolume: 'enabled',
        navigateWithVolumeWhilePlaying: false,
        keepScreenAwake: false,
        ttsLanguage: 'en-US',
        ttsRate: 1,
        ttsEngine: '',
        ttsVoices: {},
        // Read aloud bar: playback controls side ('left' | 'right') and pages per rewind/forward step
        ttsControlsSide: 'right',
        ttsPageStep: 3
      }
    }
  },
  watch: {
    show: {
      handler(newVal) {
        if (newVal) {
          this.comicHasMetadata = false
          this.registerListeners()
          this.hideToolbar()
        } else {
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
    spreadItems() {
      return [
        {
          text: this.$strings.LabelLayoutSinglePage,
          value: 'none'
        },
        {
          text: this.$strings.LabelLayoutAuto,
          value: 'auto'
        }
      ]
    },
    navigateWithVolumeItems() {
      return [
        {
          text: this.$strings.LabelOn,
          value: 'enabled'
        },
        {
          text: this.$strings.LabelNavigateWithVolumeMirrored,
          value: 'mirrored'
        },
        {
          text: this.$strings.LabelOff,
          value: 'none'
        }
      ]
    },
    ttsLanguageItems() {
      return [
        {
          text: 'CZ',
          value: 'cs-CZ'
        },
        {
          text: 'EN',
          value: 'en-US'
        }
      ]
    },
    ttsControlsOnRight() {
      return this.ereaderSettings.ttsControlsSide !== 'left'
    },
    ttsPageStep() {
      const step = parseInt(this.ereaderSettings.ttsPageStep)
      return step > 0 ? step : 3
    },
    ttsControlsSideItems() {
      return [
        {
          text: this.$strings.LabelLeft,
          value: 'left'
        },
        {
          text: this.$strings.LabelRight,
          value: 'right'
        }
      ]
    },
    ttsPageStepItems() {
      return [1, 2, 3, 5, 10].map((pages) => ({ text: String(pages), value: pages }))
    },
    ttsBarBottom() {
      const playerOffset = this.isPlayerOpen ? 120 : 0
      // Epub and pdf readers show a bottom progress strip the bar sits above
      const progressStripOffset = this.isEpub || this.isPdf || this.isDocument ? 32 : 0
      return `${playerOffset + progressStripOffset}px`
    },
    onOffToggleButtonItems() {
      return [
        {
          text: this.$strings.LabelOn,
          value: true
        },
        {
          text: this.$strings.LabelOff,
          value: false
        }
      ]
    },
    themeItems() {
      return [
        {
          text: this.$strings.LabelThemeBlack,
          value: 'black'
        },
        {
          text: this.$strings.LabelThemeDark,
          value: 'dark'
        },
        {
          text: this.$strings.LabelThemeLight,
          value: 'light'
        }
      ]
    },
    fontItems() {
      return [
        {
          text: this.$strings.LabelFontFamilySans,
          value: 'sans-serif'
        },
        {
          text: this.$strings.LabelFontFamilySerif,
          value: 'serif'
        }
      ]
    },
    legacyEncodingItems() {
      return [
        { text: this.$strings.LabelTextEncodingAuto, value: '' },
        { text: 'Windows-1250 (CE)', value: 'windows-1250' },
        { text: 'Windows-1252 (West)', value: 'windows-1252' },
        { text: 'Windows-1251 (Cyrillic)', value: 'windows-1251' },
        { text: 'ISO-8859-2', value: 'iso-8859-2' },
        { text: 'UTF-8', value: 'utf-8' }
      ]
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
    /** Server library item id used to store per-book reader settings, null for local-only items */
    bookSettingsServerId() {
      if (!this.selectedLibraryItem) return null
      if (!this.isLocal) return this.selectedLibraryItem.id
      if (!this.selectedLibraryItem.serverAddress || !this.selectedLibraryItem.libraryItemId) return null
      if (this.$store.getters['user/getServerAddress'] === this.selectedLibraryItem.serverAddress) {
        return this.selectedLibraryItem.libraryItemId
      }
      return null
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
      localStorage.setItem('ereaderSettings', JSON.stringify(global))
    },
    /** Per-book settings that differ from the global defaults, or null */
    getBookSettingsDiff() {
      if (!this.globalEreaderSettings) return null
      const diff = {}
      for (const key of BOOK_SETTING_KEYS) {
        const value = this.ereaderSettings[key]
        if (value === undefined || value === null) continue
        if (value !== this.globalEreaderSettings[key]) diff[key] = value
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
      if (serverProgress && serverProgress.ebookSettings !== undefined) {
        const override = serverProgress.ebookSettings && typeof serverProgress.ebookSettings === 'object' ? serverProgress.ebookSettings : null
        this.cacheBookSettings(override)
        return override
      }
      if (!this.bookSettingsCacheKey) return null
      try {
        const cached = localStorage.getItem(this.bookSettingsCacheKey)
        return cached ? JSON.parse(cached) : null
      } catch (error) {
        return null
      }
    },
    /** Make the current appearance settings the default for all books */
    setBookSettingsAsDefault() {
      const global = { ...(this.globalEreaderSettings || this.ereaderSettings) }
      for (const key of BOOK_SETTING_KEYS) global[key] = this.ereaderSettings[key]
      this.globalEreaderSettings = global
      localStorage.setItem('ereaderSettings', JSON.stringify(global))
      this.saveBookSettings()
    },
    goToChapter(href) {
      this.showTOCModal = false
      this.$refs.readerComponent?.goToChapter(href)
    },
    readerMounted() {
      // All readers need the settings for TTS; the epub reader also uses them for styling
      this.loadEreaderSettings()
    },
    readerLoaded(data) {
      if (this.isComic) {
        this.comicHasMetadata = data.hasMetadata
      }
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
      this.ereaderSettings.ttsVoices = { ...this.ereaderSettings.ttsVoices, [this.ereaderSettings.ttsLanguage]: voice }
      this.settingsUpdated()
    },
    setTTSRate(delta) {
      const newRate = Math.round((this.ereaderSettings.ttsRate + delta) * 100) / 100
      if (newRate < 0.5 || newRate > 2.5) return
      this.ereaderSettings.ttsRate = newRate
      this.settingsUpdated()
    },
    ttsStateChanged(state) {
      this.ttsState = state
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
      try {
        const settings = localStorage.getItem('ereaderSettings')
        if (settings) {
          const _ereaderSettings = JSON.parse(settings)
          for (const key in this.ereaderSettings) {
            if (_ereaderSettings[key] !== undefined) {
              this.ereaderSettings[key] = _ereaderSettings[key]
            }
          }
        }
      } catch (error) {
        console.error('Failed to load ereader settings', error)
      }
      this.globalEreaderSettings = { ...this.ereaderSettings }

      // Apply the settings remembered for this book on top of the defaults
      clearTimeout(this.bookSettingsSaveTimeout)
      const override = this.loadBookSettingsOverride()
      this.bookSettingsOverride = null
      if (override) {
        for (const key of BOOK_SETTING_KEYS) {
          if (override[key] !== undefined && override[key] !== null) this.ereaderSettings[key] = override[key]
        }
        this.bookSettingsOverride = this.getBookSettingsDiff()
      }
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
