<template>
  <div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelTheme }}</p>
      </div>
      <ui-toggle-btns :value="settings.theme" name="theme" :items="themeItems" @input="set('theme', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelFontFamily }}</p>
      </div>
      <ui-toggle-btns :value="settings.font" name="font" :items="fontItems" @input="set('font', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelFontScale }}</p>
      </div>
      <ui-range-input :value="settings.fontScale" :min="5" :max="300" :step="5" input-width="180px" @input="setNumber('fontScale', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelLineSpacing }}</p>
      </div>
      <ui-range-input :value="settings.lineSpacing" :min="100" :max="300" :step="5" input-width="180px" @input="setNumber('lineSpacing', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelFontBoldness }}</p>
      </div>
      <ui-range-input :value="settings.textStroke" :min="0" :max="300" :step="5" input-width="180px" @input="setNumber('textStroke', $event)" />
    </div>
    <div v-if="showAllFormats || isEpub" class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelLayout }}</p>
      </div>
      <ui-toggle-btns :value="settings.spread" name="spread" :items="spreadItems" @input="set('spread', $event)" />
    </div>
    <div v-if="showAllFormats || isDocument" class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelTextEncoding }}</p>
      </div>
      <ui-dropdown :value="settings.legacyEncoding" :items="legacyEncodingItems" small class="flex-grow max-w-[200px]" @input="set('legacyEncoding', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelNavigateWithVolume }}</p>
      </div>
      <ui-toggle-btns :value="settings.navigateWithVolume" name="navigate-volume" :items="navigateWithVolumeItems" @input="set('navigateWithVolume', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelNavigateWithVolumeWhilePlaying }}</p>
      </div>
      <ui-toggle-btns :value="settings.navigateWithVolumeWhilePlaying" name="navigate-volume-playing" :items="onOffToggleButtonItems" @input="set('navigateWithVolumeWhilePlaying', $event)" />
    </div>
    <div class="flex items-center mb-6">
      <div class="w-32">
        <p class="text-sm">{{ $strings.LabelKeepScreenAwake }}</p>
      </div>
      <ui-toggle-btns :value="settings.keepScreenAwake" name="keep-awake" :items="onOffToggleButtonItems" @input="set('keepScreenAwake', $event)" />
    </div>
    <template v-if="ttsAvailable">
      <div class="flex items-center mb-6">
        <div class="w-32">
          <p class="text-sm">{{ $strings.LabelReadAloudLanguage }}</p>
        </div>
        <div>
          <ui-toggle-btns :value="settings.ttsLanguage" name="tts-language" :items="ttsLanguageItems" @input="set('ttsLanguage', $event)" />
          <p v-if="languageHint" class="text-xs text-fg-muted mt-1">{{ languageHint }}</p>
        </div>
      </div>
      <div class="flex items-center mb-6">
        <div class="w-32">
          <p class="text-sm">{{ $strings.LabelReadAloudControlsSide }}</p>
        </div>
        <ui-toggle-btns :value="settings.ttsControlsSide || 'right'" name="tts-controls-side" :items="ttsControlsSideItems" @input="set('ttsControlsSide', $event)" />
      </div>
      <div class="flex items-center mb-6">
        <div class="w-32">
          <p class="text-sm">{{ $strings.LabelReadAloudPageStep }}</p>
        </div>
        <ui-toggle-btns :value="ttsPageStep" name="tts-page-step" :items="ttsPageStepItems" @input="set('ttsPageStep', $event)" />
      </div>
      <div class="flex items-center mb-6">
        <div class="w-32">
          <p class="text-sm">{{ $strings.LabelReadAloudVoice }}</p>
        </div>
        <ui-btn small @click="$emit('open-tts-settings')">{{ $strings.HeaderReadAloudSettings }}</ui-btn>
      </div>
    </template>
    <slot />
  </div>
</template>

<script>
import { ttsLanguageItems } from '@/utils/ereaderSettings'

/**
 * Ereader and read aloud settings rows, shared by the reader settings modal
 * (the settings of the open book) and the app settings page (the defaults
 * for all books). Emits `change(key, value)` for every edit and
 * `open-tts-settings` for the voice/engine dialog the parent owns.
 */
export default {
  props: {
    settings: {
      type: Object,
      required: true
    },
    // Format-specific rows: shown for the matching reader, or all of them for the defaults
    isEpub: Boolean,
    isDocument: Boolean,
    showAllFormats: Boolean,
    ttsAvailable: Boolean,
    // Note under the read aloud language toggle (e.g. that it came from the book metadata)
    languageHint: String
  },
  computed: {
    ttsLanguageItems() {
      return ttsLanguageItems()
    },
    ttsPageStep() {
      const step = parseInt(this.settings.ttsPageStep)
      return step > 0 ? step : 3
    },
    ttsPageStepItems() {
      return [1, 2, 3, 5, 10].map((pages) => ({ text: String(pages), value: pages }))
    },
    ttsControlsSideItems() {
      return [
        { text: this.$strings.LabelLeft, value: 'left' },
        { text: this.$strings.LabelRight, value: 'right' }
      ]
    },
    spreadItems() {
      return [
        { text: this.$strings.LabelLayoutSinglePage, value: 'none' },
        { text: this.$strings.LabelLayoutAuto, value: 'auto' }
      ]
    },
    navigateWithVolumeItems() {
      return [
        { text: this.$strings.LabelOn, value: 'enabled' },
        { text: this.$strings.LabelNavigateWithVolumeMirrored, value: 'mirrored' },
        { text: this.$strings.LabelOff, value: 'none' }
      ]
    },
    onOffToggleButtonItems() {
      return [
        { text: this.$strings.LabelOn, value: true },
        { text: this.$strings.LabelOff, value: false }
      ]
    },
    themeItems() {
      return [
        { text: this.$strings.LabelThemeBlack, value: 'black' },
        { text: this.$strings.LabelThemeDark, value: 'dark' },
        { text: this.$strings.LabelThemeLight, value: 'light' }
      ]
    },
    fontItems() {
      return [
        { text: this.$strings.LabelFontFamilySans, value: 'sans-serif' },
        { text: this.$strings.LabelFontFamilySerif, value: 'serif' }
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
    }
  },
  methods: {
    set(key, value) {
      if (value === this.settings[key]) return
      this.$emit('change', key, value)
    },
    /** Range inputs report strings - stored as numbers so per-book diffs compare cleanly */
    setNumber(key, value) {
      const number = Number(value)
      if (isNaN(number)) return
      this.set(key, number)
    }
  }
}
</script>
