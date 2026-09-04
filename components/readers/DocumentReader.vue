<template>
  <div ref="viewer" class="document-viewer w-full relative" @scroll.passive="onScroll">
    <div ref="content" class="document-content w-full max-w-3xl mx-auto px-4 pt-4 pb-12" :class="fontClass" :style="contentStyle" />

    <div v-if="errorMessage" class="w-full flex items-center justify-center px-8 py-16">
      <p class="text-center text-fg-muted">{{ errorMessage }}</p>
    </div>

    <div v-show="loading" class="fixed top-0 left-0 w-full h-full flex items-center justify-center z-10">
      <ui-loading-indicator />
    </div>

    <div class="fixed left-0 h-8 w-full bg-bg px-4 flex items-center text-fg-muted" :style="{ bottom: isPlayerOpen ? '120px' : '0px' }">
      <p v-if="usedFallbackEncoding" class="text-xs truncate">{{ effectiveLegacyEncoding }}</p>
      <div class="flex-grow" />
      <p class="text-xs">{{ progressPercent }}%</p>
    </div>
  </div>
</template>

<script>
import TTSPlayer from '@/mixins/ttsPlayer'
import defaultCss from '@/assets/ebooks/basic.js'
import { parseDocumentToHtml } from '@/assets/ebooks/documentParser.js'
import { guessLegacyEncoding } from '@/assets/ebooks/textEncoding.js'

/**
 * Reader for the "document" ebook formats (doc, docx, rtf, pdb). The file is
 * parsed into a small HTML subset and rendered in a scrolling container. The
 * reading position is the index of the first visible paragraph, which is
 * also the paragraph index used by the read aloud (TTS) engine.
 */
export default {
  mixins: [TTSPlayer],
  props: {
    url: String,
    libraryItem: {
      type: Object,
      default: () => {}
    },
    isLocal: Boolean,
    keepProgress: Boolean,
    showingToolbar: Boolean,
    ebookFormat: String
  },
  data() {
    return {
      loading: true,
      errorMessage: null,
      fileData: null,
      blocks: [],
      chapters: [],
      progressPercent: 0,
      usedFallbackEncoding: false,
      parsedEncoding: '',
      scrollTimeout: null,
      lastSavedLocation: null
    }
  },
  computed: {
    localLibraryItem() {
      if (this.isLocal) return this.libraryItem
      return this.libraryItem.localLibraryItem || null
    },
    localLibraryItemId() {
      return this.localLibraryItem?.id
    },
    serverLibraryItemId() {
      if (!this.isLocal) return this.libraryItem.id
      // Check if local library item is connected to the current server
      if (!this.libraryItem.serverAddress || !this.libraryItem.libraryItemId) return null
      if (this.$store.getters['user/getServerAddress'] === this.libraryItem.serverAddress) {
        return this.libraryItem.libraryItemId
      }
      return null
    },
    userItemProgress() {
      if (this.isLocal) return this.localItemProgress
      return this.serverItemProgress
    },
    localItemProgress() {
      return this.$store.getters['globals/getLocalMediaProgressById'](this.localLibraryItemId)
    },
    serverItemProgress() {
      return this.$store.getters['user/getUserMediaProgress'](this.serverLibraryItemId)
    },
    savedBlockIndex() {
      if (!this.keepProgress) return 0
      const location = Number(this.userItemProgress?.ebookLocation)
      if (isNaN(location) || location < 0) return 0
      return Math.floor(location)
    },
    isPlayerOpen() {
      return this.$store.getters['getIsPlayerOpen']
    },
    effectiveLegacyEncoding() {
      return this.ereaderSettings.legacyEncoding || guessLegacyEncoding(navigator.language)
    },
    fontClass() {
      return this.ereaderSettings.font === 'sans-serif' ? 'font-sans' : 'font-serif'
    },
    contentStyle() {
      const fontScale = Number(this.ereaderSettings.fontScale) || 100
      const lineSpacing = Number(this.ereaderSettings.lineSpacing) || 115
      const textStroke = Number(this.ereaderSettings.textStroke) || 0
      return {
        fontSize: `${fontScale}%`,
        lineHeight: `${lineSpacing}%`,
        '-webkit-text-stroke': textStroke ? `${textStroke / 100}px currentColor` : ''
      }
    }
  },
  methods: {
    /**
     * TTS hook: paragraphs of the rendered document. The whole document is a
     * single unit, so there is no ttsAdvanceUnit.
     */
    ttsCollectParagraphs() {
      return this.ttsCollectHtmlParagraphs(this.$refs.content)
    },
    /** TTS hook: start from the first paragraph visible at the current scroll position */
    ttsStartIndex(paragraphs) {
      return this.currentBlockIndex(paragraphs.map((p) => p.ref))
    },
    /** Native TTS hook: one chapter; location is the paragraph index */
    ttsExtractBook() {
      const paragraphs = this.ttsCollectHtmlParagraphs(this.$refs.content)
      this.ttsNativeElements = paragraphs.map((p) => p.ref)
      if (!paragraphs.length) return { ebookFormat: this.ebookFormat, chapters: [] }
      return {
        ebookFormat: this.ebookFormat,
        chapters: [
          {
            title: '',
            startLocation: '',
            paragraphs: paragraphs.map((p, index) => ({ text: p.text, location: String(index), chars: p.text.length }))
          }
        ]
      }
    },
    /** Native TTS hook: start from the paragraph at the current scroll position */
    ttsNativeStartPosition() {
      return { chapterIndex: 0, paragraphIndex: this.currentBlockIndex(this.ttsNativeElements || []) }
    },
    /** Native TTS hook: scroll along with the spoken paragraph */
    ttsNativeFollow(event) {
      const el = this.ttsNativeElements?.[event.paragraphIndex]
      if (el) this.ttsFollowParagraph({ ref: el })
    },
    /** TTS hook: scroll the spoken paragraph into view */
    ttsFollowParagraph(paragraph) {
      const el = paragraph.ref
      const viewer = this.$refs.viewer
      if (!el || !viewer) return
      const top = el.offsetTop
      const bottom = top + el.offsetHeight
      const viewTop = viewer.scrollTop
      const viewBottom = viewTop + viewer.clientHeight - 48
      if (top < viewTop || bottom > viewBottom) {
        viewer.scrollTo({ top: Math.max(0, top - 16), behavior: 'smooth' })
      }
    },
    updateSettings(settings) {
      this.ttsHandleSettingsChange(settings)
      const encodingChanged = (settings.legacyEncoding || '') !== (this.ereaderSettings.legacyEncoding || '')
      this.ereaderSettings = settings
      if (encodingChanged && this.usedFallbackEncoding && this.fileData) {
        const index = this.currentBlockIndex()
        this.render().then(() => this.scrollToBlock(index))
      }
    },
    goToChapter(href) {
      const index = Number(String(href).replace(/^#block-/, ''))
      if (!isNaN(index)) this.scrollToBlock(index)
    },
    /**
     * Index of the first block whose bottom edge is below the top of the view
     * @param {HTMLElement[]} [blocks]
     */
    currentBlockIndex(blocks = this.blocks) {
      const viewer = this.$refs.viewer
      if (!viewer || !blocks.length) return 0
      const scrollTop = viewer.scrollTop + 4
      const index = blocks.findIndex((el) => el.offsetTop + el.offsetHeight > scrollTop)
      return index < 0 ? blocks.length - 1 : index
    },
    scrollToBlock(index) {
      const viewer = this.$refs.viewer
      const el = this.blocks[index]
      if (!viewer || !el) return
      viewer.scrollTop = Math.max(0, el.offsetTop - 8)
      this.updateProgressPercent()
    },
    next() {
      const viewer = this.$refs.viewer
      if (!viewer) return
      viewer.scrollTo({ top: viewer.scrollTop + viewer.clientHeight - 48, behavior: 'smooth' })
    },
    prev() {
      const viewer = this.$refs.viewer
      if (!viewer) return
      viewer.scrollTo({ top: Math.max(0, viewer.scrollTop - viewer.clientHeight + 48), behavior: 'smooth' })
    },
    onScroll() {
      this.updateProgressPercent()
      clearTimeout(this.scrollTimeout)
      this.scrollTimeout = setTimeout(() => this.updateProgress(), 1000)
    },
    updateProgressPercent() {
      const viewer = this.$refs.viewer
      if (!viewer) return
      const scrollable = viewer.scrollHeight - viewer.clientHeight
      this.progressPercent = scrollable > 0 ? Math.min(100, Math.round((viewer.scrollTop / scrollable) * 100)) : 100
    },
    isAtEnd() {
      const viewer = this.$refs.viewer
      return !!viewer && viewer.scrollTop + viewer.clientHeight >= viewer.scrollHeight - 4
    },
    async updateProgress() {
      if (!this.keepProgress || !this.blocks.length || this.loading) return

      const index = this.currentBlockIndex()
      const ebookProgress = this.isAtEnd() ? 1 : Math.max(0, Math.min(1, index / this.blocks.length))
      const payload = {
        ebookLocation: String(index),
        ebookProgress
      }
      if (this.lastSavedLocation === `${payload.ebookLocation}:${ebookProgress}`) return
      this.lastSavedLocation = `${payload.ebookLocation}:${ebookProgress}`

      // Update local item
      if (this.localLibraryItemId) {
        const localPayload = {
          localLibraryItemId: this.localLibraryItemId,
          ...payload
        }
        const localResponse = await this.$db.updateLocalEbookProgress(localPayload)
        if (localResponse?.localMediaProgress) {
          this.$store.commit('globals/updateLocalMediaProgress', localResponse.localMediaProgress)
        }
      }

      // Update server item
      if (this.serverLibraryItemId) {
        this.$nativeHttp.patch(`/api/me/progress/${this.serverLibraryItemId}`, payload).catch((error) => {
          console.error('DocumentReader.updateProgress failed:', error)
        })
      }
    },
    buildChapters() {
      const chapters = []
      this.blocks.forEach((el, index) => {
        if (!/^H[1-3]$/.test(el.tagName)) return
        const label = (el.textContent || '').trim()
        if (!label) return
        chapters.push({ id: `block-${index}`, label, href: `#block-${index}`, subitems: [] })
      })
      this.chapters = chapters
    },
    async render() {
      const content = this.$refs.content
      if (!content || !this.fileData) return
      this.loading = true
      this.errorMessage = null
      // Let the spinner paint before the (synchronous) parse
      await new Promise((resolve) => setTimeout(resolve, 20))
      try {
        const result = await parseDocumentToHtml(this.fileData, {
          format: this.ebookFormat,
          legacyEncoding: this.effectiveLegacyEncoding
        })
        this.usedFallbackEncoding = result.usedFallbackEncoding
        let html = result.html
        if (result.rawHtml) {
          // Book HTML from the MOBI parser relies on calibre's class based stylesheet
          html = `<style>${defaultCss}</style>${html}`
        }
        content.innerHTML = html
        content.querySelectorAll('a[href]').forEach((a) => a.removeAttribute('href'))
        this.blocks = this.ttsCollectHtmlParagraphs(content).map((p) => p.ref)
        this.buildChapters()
      } catch (error) {
        console.error('[DocumentReader] Failed to open document', error)
        content.innerHTML = ''
        this.blocks = []
        const message = error?.code === 'encrypted' ? this.$strings.MessageEbookEncrypted : error?.code === 'unsupported' ? this.$getString('MessageUnsupportedEbookFormat', [error.message || this.ebookFormat]) : this.$strings.MessageEbookOpenFailed
        this.errorMessage = message
        this.$toast.error(message)
      }
      this.loading = false
    },
    async init() {
      this.loading = true
      try {
        this.fileData = await this.$axios.$get(this.url, { responseType: 'arraybuffer' })
      } catch (error) {
        console.error('[DocumentReader] Failed to load document', error)
        this.errorMessage = this.$strings.MessageEbookOpenFailed
        this.$toast.error(this.$strings.MessageEbookOpenFailed)
        this.loading = false
        return
      }
      await this.render()
      if (!this.errorMessage) {
        await this.$nextTick()
        if (this.savedBlockIndex > 0) this.scrollToBlock(this.savedBlockIndex)
        this.updateProgressPercent()
        this.$emit('loaded', { chapters: this.chapters })
      }
    }
  },
  mounted() {
    this.init()
  },
  beforeDestroy() {
    clearTimeout(this.scrollTimeout)
    this.updateProgress()
  }
}
</script>

<style>
.document-viewer {
  height: calc(100% - 32px);
  max-height: calc(100% - 32px);
  overflow-x: hidden;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
}
.reader-player-open .document-viewer {
  height: calc(100% - 132px);
  max-height: calc(100% - 132px);
}
.document-content p {
  margin: 0 0 0.9em 0;
  text-align: justify;
  hyphens: auto;
}
.document-content h1,
.document-content h2,
.document-content h3,
.document-content h4,
.document-content h5,
.document-content h6 {
  font-weight: bold;
  margin: 1.4em 0 0.7em 0;
  line-height: 1.25;
}
.document-content h1 {
  font-size: 1.6em;
}
.document-content h2 {
  font-size: 1.35em;
}
.document-content h3 {
  font-size: 1.15em;
}
.document-content img {
  max-width: 100%;
  height: auto;
}
</style>
