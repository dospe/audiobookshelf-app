<template>
  <div>
    <modals-modal v-model="show" :width="340" height="unset">
      <div class="w-full bg-primary rounded-lg border border-fg/20 p-4" @click.stop>
        <p class="text-lg mb-4">{{ $strings.HeaderReadAloudSettings }}</p>

        <div class="py-2 flex items-center">
          <p class="pr-4 w-24 text-sm">{{ $strings.LabelLanguage }}</p>
          <ui-toggle-btns :value="language" name="tts-dialog-language" :items="languageItems" @input="selectLanguage" />
        </div>

        <div class="py-2 flex items-center">
          <p class="pr-4 w-24 text-sm">{{ $strings.LabelPlaybackSpeed }}</p>
          <div class="flex items-center">
            <button type="button" class="inline-flex" :class="{ 'opacity-40': rate <= 0.5 }" :disabled="rate <= 0.5" @click.stop="changeRate(-0.25)">
              <span class="material-symbols text-2xl">remove</span>
            </button>
            <p class="text-sm w-12 text-center">{{ rate }}×</p>
            <button type="button" class="inline-flex" :class="{ 'opacity-40': rate >= 2.5 }" :disabled="rate >= 2.5" @click.stop="changeRate(0.25)">
              <span class="material-symbols text-2xl">add</span>
            </button>
          </div>
        </div>

        <div v-if="isNative" class="py-2 flex items-center">
          <p class="pr-4 w-24 text-sm">{{ $strings.LabelReadAloudEngine }}</p>
          <div class="flex-grow" @click.stop="showEngineDialog = true">
            <ui-text-input :value="selectedEngineLabel" readonly :autofocus="false" append-icon="expand_more" />
          </div>
        </div>

        <div class="py-2 flex items-center">
          <p class="pr-4 w-24 text-sm">{{ $strings.LabelReadAloudVoice }}</p>
          <div class="flex-grow" @click.stop="showVoiceDialog = true">
            <ui-text-input :value="selectedVoiceLabel" readonly :autofocus="false" append-icon="expand_more" />
          </div>
        </div>

        <div class="py-2 flex items-center">
          <p class="pr-4 w-24 text-sm">{{ $strings.LabelReadAloudControlsSide }}</p>
          <ui-toggle-btns :value="controlsSide || 'right'" name="tts-dialog-controls-side" :items="controlsSideItems" @input="selectControlsSide" />
        </div>

        <div class="py-2 flex items-center">
          <p class="pr-4 w-24 text-sm">{{ $strings.LabelReadAloudPageStep }}</p>
          <ui-toggle-btns :value="pageStep" name="tts-dialog-page-step" :items="pageStepItems" @input="selectPageStep" />
        </div>

        <ui-btn v-if="isNative" small class="w-full mt-4" @click="openSystemTTSSettings">{{ $strings.ButtonOpenSystemTTSSettings }}</ui-btn>
      </div>
    </modals-modal>

    <modals-dialog v-model="showEngineDialog" :items="engineItems" :selected="ttsEngine || ''" @action="selectEngine" />
    <modals-dialog v-model="showVoiceDialog" :items="voiceItems" :selected="selectedVoiceValue" @action="selectVoice" />
  </div>
</template>

<script>
import { TextToSpeech } from '@capacitor-community/text-to-speech'
import { AbsTTSPlayer } from '@/plugins/capacitor/AbsTTSPlayer'

/**
 * Read aloud (TTS) engine and voice picker. On the native Android player the
 * engines/voices come from the AbsTTSPlayer plugin; on the web fallback path
 * only the voices of the system speech synthesis are selectable.
 */
export default {
  props: {
    value: Boolean,
    language: String,
    ttsEngine: String,
    ttsVoices: {
      type: Object,
      default: () => ({})
    },
    isNative: Boolean,
    // Language choices ({ text, value }) and current speaking rate
    languageItems: {
      type: Array,
      default: () => []
    },
    rate: {
      type: Number,
      default: 1
    },
    // Read aloud bar layout: playback controls side and pages per rewind/forward step
    controlsSide: String,
    pageStep: {
      type: Number,
      default: 3
    }
  },
  data() {
    return {
      engines: [],
      voices: [],
      showEngineDialog: false,
      showVoiceDialog: false
    }
  },
  watch: {
    show(newVal) {
      // Loaded fresh on every open - voices can be (un)installed in the
      // system TTS settings this dialog links to
      if (newVal) this.load()
    },
    ttsEngine() {
      if (this.show) this.loadVoices()
    },
    language() {
      if (this.show) this.loadVoices()
    }
  },
  computed: {
    show: {
      get() {
        return this.value
      },
      set(val) {
        this.$emit('input', val)
      }
    },
    controlsSideItems() {
      return [
        { text: this.$strings.LabelLeft, value: 'left' },
        { text: this.$strings.LabelRight, value: 'right' }
      ]
    },
    pageStepItems() {
      return [1, 2, 3, 5, 10].map((pages) => ({ text: String(pages), value: pages }))
    },
    selectedVoiceValue() {
      return this.ttsVoices?.[this.language] || ''
    },
    engineItems() {
      return [{ text: this.$strings.LabelReadAloudVoiceDefault, value: '' }, ...this.engines.map((e) => ({ text: e.label || e.name, value: e.name }))]
    },
    selectedEngineLabel() {
      if (!this.ttsEngine) return this.$strings.LabelReadAloudVoiceDefault
      return this.engines.find((e) => e.name === this.ttsEngine)?.label || this.ttsEngine
    },
    voiceItems() {
      return [{ text: this.$strings.LabelReadAloudVoiceDefault, value: '' }, ...this.voices]
    },
    selectedVoiceLabel() {
      // A stored voice missing from the fresh list shows as default without clearing the setting
      const voice = this.voices.find((v) => v.value === this.selectedVoiceValue)
      return voice?.text || this.$strings.LabelReadAloudVoiceDefault
    }
  },
  methods: {
    load() {
      if (this.isNative) this.loadEngines()
      this.loadVoices()
    },
    async loadEngines() {
      const result = await AbsTTSPlayer.getEngines().catch(() => null)
      this.engines = result?.engines || []
    },
    async loadVoices() {
      this.voices = []
      if (this.isNative) {
        const result = await AbsTTSPlayer.getVoices({ engine: this.ttsEngine || '', language: this.language }).catch(() => null)
        this.voices = (result?.voices || []).map((v) => ({ text: v.name + (v.networkRequired ? ' (online)' : ''), value: v.name })).sort((a, b) => a.text.localeCompare(b.text))
      } else {
        const result = await TextToSpeech.getSupportedVoices().catch(() => null)
        const langPrefix = (this.language || '').split('-')[0].toLowerCase()
        this.voices = (result?.voices || [])
          .filter((v) => (v.lang || '').replace('_', '-').toLowerCase().startsWith(langPrefix))
          .map((v) => ({ text: v.name, value: v.voiceURI }))
          .sort((a, b) => a.text.localeCompare(b.text))
      }
    },
    selectLanguage(lang) {
      if (lang && lang !== this.language) this.$emit('update:language', lang)
    },
    changeRate(delta) {
      const newRate = Math.round((this.rate + delta) * 100) / 100
      if (newRate < 0.5 || newRate > 2.5) return
      this.$emit('update:rate', newRate)
    },
    selectControlsSide(side) {
      if (side !== (this.controlsSide || 'right')) this.$emit('update:controlsSide', side)
    },
    selectPageStep(pages) {
      if (pages !== this.pageStep) this.$emit('update:pageStep', pages)
    },
    selectEngine(engine) {
      this.showEngineDialog = false
      if (engine !== (this.ttsEngine || '')) this.$emit('update:engine', engine)
    },
    selectVoice(voice) {
      this.showVoiceDialog = false
      if (voice !== this.selectedVoiceValue) this.$emit('update:voice', voice)
    },
    openSystemTTSSettings() {
      AbsTTSPlayer.openTTSSettings().catch((error) => {
        console.error('Failed to open system TTS settings', error)
      })
    }
  }
}
</script>
