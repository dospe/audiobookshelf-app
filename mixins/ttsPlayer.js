import { TextToSpeech } from '@capacitor-community/text-to-speech'
import { AbsTTSPlayer, isNativeTTSPlayerAvailable } from '@/plugins/capacitor/AbsTTSPlayer'

/**
 * Read aloud (TTS) engine shared by the ebook readers, speaking with the
 * device system voices via the native text-to-speech plugin.
 *
 * Text is spoken in sentence-sized chunks grouped into paragraphs, and
 * paragraphs into "units" (an epub spine section, a pdf page, or the whole
 * document). The reader component implements the format-specific hooks:
 *
 *   ttsCollectParagraphs() -> Array<{ text: String, ref: any }> | Promise
 *     Paragraphs of the current unit. Called when TTS starts.
 *   ttsStartIndex(paragraphs) -> Number (optional)
 *     Index of the paragraph to start speaking from, e.g. based on the
 *     currently visible page or scroll position. Defaults to 0.
 *   ttsAdvanceUnit() -> Array<paragraph> | null | Promise (optional)
 *     Move to the next unit and return its paragraphs, or null at the end
 *     of the book. The hook is responsible for skipping empty units.
 *     When not implemented the book ends with the current unit.
 *   ttsFollowParagraph(paragraph) (optional)
 *     Bring the paragraph about to be spoken into view.
 *
 * When the native TTS player plugin is available (Android, F1 of
 * docs/native-tts-player-design.md) the loop instead runs in the native
 * service so it survives the screen turning off. Readers opt in by
 * implementing these additional hooks:
 *
 *   ttsExtractBook() -> { ebookFormat, chapters } | Promise
 *     Full book text: chapters with { title, startLocation, startCfi,
 *     paragraphs }, paragraph { text, location, chars }.
 *   ttsNativeStartPosition(book) -> { chapterIndex, paragraphIndex } (optional)
 *     Where to start based on the current reading position.
 *   ttsNativeFollow(event) (optional)
 *     Follow-along for onParagraph events { chapterIndex, paragraphIndex, location }.
 *   ttsEstimatePageChars() -> Number (optional)
 *     Characters on one displayed page, used by the native player to skip
 *     by pages from the notification / lock screen / Android Auto.
 *
 * Skipping by pages (the read aloud bar rewind/forward buttons) uses:
 *
 *   ttsTurnPages(delta) -> Promise (optional)
 *     Turn `delta` pages in the reader (negative = backwards). After the
 *     turn the spoken position is moved to the first paragraph of the
 *     visible page with the ttsStartIndex / ttsNativeStartPosition hooks.
 *   ttsIsParagraphVisible({ location, paragraphIndex, ref }) -> Boolean|null (optional)
 *     Whether the paragraph is on the visible page / in the viewport, null
 *     when unknown. `location` and `paragraphIndex` describe a native session
 *     position, `ref` a paragraph from ttsCollectParagraphs. Play after a
 *     pause uses it: when the paused paragraph was paged away from, speaking
 *     continues from the visible page instead of the old spot.
 *
 * A native session of the reader's book may still be running or paused in the
 * background when the reader opens. `this.ttsNativeSessionState` (a promise
 * set in created) resolves with that session's getState() payload - location,
 * progress, chapterIndex, paragraphIndex - or null, so the reader can open at
 * the spoken position; the saved progress in the store lags behind while the
 * WebView is not running.
 */
export default {
  data() {
    return {
      ttsState: 'stopped',
      ttsSessionId: 0,
      ttsParagraphs: [],
      ttsParagraphIndex: 0,
      ttsChunks: [],
      ttsChunkIndex: 0,
      // Resolved index into getSupportedVoices() for the web path; indices are
      // only stable within one snapshot so it is resolved fresh, never persisted
      ttsWebVoiceIndex: null,
      // Book payload of the running native session, kept for page skips
      ttsNativeBook: null,
      // Set while a page skip is turning pages so follow-along does not turn them back
      ttsSkipInProgress: false,
      ereaderSettings: {
        ttsLanguage: 'en-US',
        ttsRate: 1,
        ttsEngine: '',
        ttsVoices: {},
        ttsPageStep: 3
      }
    }
  },
  methods: {
    // Readers with their own settings handling (epub) override this and
    // call ttsHandleSettingsChange themselves before storing the settings
    updateSettings(settings) {
      this.ttsHandleSettingsChange(settings)
      this.ereaderSettings = settings
    },
    ttsHandleSettingsChange(newSettings) {
      const langChanged = newSettings.ttsLanguage !== this.ereaderSettings.ttsLanguage
      const rateChanged = newSettings.ttsRate !== this.ereaderSettings.ttsRate
      const engineChanged = (newSettings.ttsEngine || '') !== (this.ereaderSettings.ttsEngine || '')
      const newVoice = newSettings.ttsVoices?.[newSettings.ttsLanguage] || ''
      const oldVoice = this.ereaderSettings.ttsVoices?.[this.ereaderSettings.ttsLanguage] || ''
      // A language or engine switch also switches the effective voice
      const voiceChanged = newVoice !== oldVoice || langChanged || engineChanged
      const pageStepChanged = this.ttsPageStepOf(newSettings) !== this.ttsPageStepOf(this.ereaderSettings)
      if (!langChanged && !rateChanged && !engineChanged && !voiceChanged && !pageStepChanged) return

      if (this.ttsUseNative()) {
        if (pageStepChanged) {
          AbsTTSPlayer.setPageStep({ pageStep: this.ttsPageStepOf(newSettings), pageChars: this.ttsEstimatePageChars?.() || 0 }).catch(() => {})
        }
        if (!langChanged && !rateChanged && !engineChanged && !voiceChanged) return
        // Order matters: the engine re-init clears the voice, setLanguage picks
        // a default the voice then overrides
        if (engineChanged) AbsTTSPlayer.setEngine({ engine: newSettings.ttsEngine || '' }).catch(() => {})
        if (langChanged) AbsTTSPlayer.setLanguage({ lang: newSettings.ttsLanguage }).catch(() => {})
        if (rateChanged) AbsTTSPlayer.setRate({ rate: newSettings.ttsRate }).catch(() => {})
        if (voiceChanged) AbsTTSPlayer.setVoice({ voice: newVoice }).catch(() => {})
        return
      }

      // The page step is read from the settings on every skip on the web path
      if (!langChanged && !rateChanged && !engineChanged && !voiceChanged) return

      // Engine selection is not possible on the web path (no plugin API for it)
      this.ttsResolveWebVoiceIndex(newSettings).finally(() => {
        if (this.ttsState === 'playing') {
          // Restart the current chunk so the new voice/rate takes effect immediately
          this.ttsSessionId++
          TextToSpeech.stop()
            .catch(() => {})
            .finally(() => {
              if (this.ttsState === 'playing') this.speakNextChunk()
            })
        }
      })
    },
    async ttsResolveWebVoiceIndex(settings = this.ereaderSettings) {
      const voiceId = settings.ttsVoices?.[settings.ttsLanguage] || ''
      if (!voiceId) {
        this.ttsWebVoiceIndex = null
        return
      }
      const result = await TextToSpeech.getSupportedVoices().catch(() => null)
      const index = (result?.voices || []).findIndex((v) => v.voiceURI === voiceId || v.name === voiceId)
      this.ttsWebVoiceIndex = index >= 0 ? index : null
    },
    ttsUseNative() {
      return !!this.ttsExtractBook && isNativeTTSPlayerAvailable()
    },
    async startTTS() {
      if (this.ttsUseNative()) return this.startNativeTTS()
      return this.startWebTTS()
    },
    async startNativeTTS() {
      const extracted = await Promise.resolve(this.ttsExtractBook()).catch((error) => {
        console.error('[ttsPlayer] Failed to extract book for native TTS', error)
        return null
      })
      if (!extracted?.chapters?.length) {
        this.$toast.error(this.$strings.MessageReadAloudNoText)
        return
      }

      const book = this.ttsBuildBookPayload(extracted)
      this.ttsNativeBook = book
      await this.ttsRegisterNativeListeners()

      try {
        await AbsTTSPlayer.prepareBook(book)
        const start = this.ttsNativeStartPosition?.(book) || { chapterIndex: 0, paragraphIndex: 0 }
        await AbsTTSPlayer.play({ libraryItemId: book.libraryItemId, ...start })
      } catch (error) {
        console.error('[ttsPlayer] Native TTS failed to start', error)
        this.$toast.error(this.$strings.MessageReadAloudFailed)
      }
    },
    ttsBuildBookPayload(extracted) {
      const chapters = (extracted.chapters || []).map((chapter) => ({
        title: chapter.title || '',
        startLocation: chapter.startLocation || '',
        startCfi: chapter.startCfi || null,
        paragraphs: (chapter.paragraphs || []).map((p) => ({
          text: p.text,
          location: p.location || null,
          chars: p.chars || p.text.length
        }))
      }))
      const totalChars = chapters.reduce((total, chapter) => total + chapter.paragraphs.reduce((s, p) => s + p.chars, 0), 0)
      const mediaMetadata = this.libraryItem?.media?.metadata || {}
      return {
        libraryItemId: this.libraryItem?.id || '',
        serverAddress: this.$store?.getters['user/getServerAddress'] || '',
        title: mediaMetadata.title || '',
        author: mediaMetadata.authorName || '',
        language: this.ereaderSettings.ttsLanguage || 'en-US',
        rate: this.ereaderSettings.ttsRate || 1,
        ttsEngine: this.ereaderSettings.ttsEngine || '',
        voice: this.ereaderSettings.ttsVoices?.[this.ereaderSettings.ttsLanguage] || '',
        ebookFormat: extracted.ebookFormat || '',
        chapters,
        totalChars,
        // Page skips from the media session (notification, Android Auto)
        pageStep: this.ttsPageStepOf(this.ereaderSettings),
        pageChars: this.ttsEstimatePageChars?.() || 0
      }
    },
    /** @returns {number} pages per rewind/forward step from the settings */
    ttsPageStepOf(settings) {
      const step = parseInt(settings?.ttsPageStep)
      return step > 0 ? step : 3
    },
    /**
     * Rewind/forward by the configured number of pages: turn the pages in the
     * reader and continue speaking from the first paragraph on the new page.
     * @param {number} direction -1 backwards, 1 forward
     */
    async ttsSkipPages(direction) {
      if (!this.ttsTurnPages || this.ttsSkipInProgress) return
      const delta = (direction < 0 ? -1 : 1) * this.ttsPageStepOf(this.ereaderSettings)
      this.ttsSkipInProgress = true
      try {
        await this.ttsTurnPages(delta)
        if (this.ttsState !== 'stopped') {
          await this.ttsSeekToVisiblePage()
        }
      } catch (error) {
        console.error('[ttsPlayer] Failed to skip pages', error)
      } finally {
        this.ttsSkipInProgress = false
      }
    },
    /** Move the spoken position to the first paragraph of the visible page */
    async ttsSeekToVisiblePage() {
      if (this.ttsUseNative()) {
        if (!this.ttsNativeBook) {
          // Reader re-attached to a background session - the payload is needed for the position
          const extracted = await Promise.resolve(this.ttsExtractBook()).catch(() => null)
          if (!extracted?.chapters?.length) return
          this.ttsNativeBook = this.ttsBuildBookPayload(extracted)
        }
        const position = this.ttsNativeStartPosition?.(this.ttsNativeBook) || { chapterIndex: 0, paragraphIndex: 0 }
        await AbsTTSPlayer.seekTo(position).catch((error) => {
          console.error('[ttsPlayer] Native TTS seek failed', error)
        })
        return
      }

      const session = this.ttsSessionId
      let paragraphs = await Promise.resolve(this.ttsCollectParagraphs()).catch(() => [])
      if (session !== this.ttsSessionId || this.ttsState === 'stopped') return
      let startIndex = 0
      if (paragraphs?.length) {
        startIndex = this.ttsStartIndex?.(paragraphs) || 0
      } else if (this.ttsAdvanceUnit) {
        // No readable text here (e.g. a scanned pdf page) - continue with the next unit that has some
        paragraphs = await Promise.resolve(this.ttsAdvanceUnit()).catch(() => null)
        if (session !== this.ttsSessionId || this.ttsState === 'stopped') return
      }
      if (!paragraphs?.length) {
        this.stopTTS()
        return
      }

      this.ttsParagraphs = paragraphs
      this.ttsParagraphIndex = Math.max(0, Math.min(startIndex, paragraphs.length - 1))
      if (this.ttsState === 'playing') {
        this.ttsSessionId++
        await TextToSpeech.stop().catch(() => {})
        if (this.ttsState !== 'playing') return
        this.speakCurrentParagraph()
      } else {
        // Paused: resume continues with the chunks of the new paragraph
        this.ttsChunks = this.splitTextChunks(paragraphs[this.ttsParagraphIndex].text)
        this.ttsChunkIndex = 0
      }
    },
    async ttsRegisterNativeListeners() {
      if (this.ttsNativeListeners) return
      this.ttsNativeListeners = [
        await AbsTTSPlayer.addListener('onStateChange', (data) => {
          const state = data?.state || 'stopped'
          if (state === this.ttsState) return
          this.ttsState = state
          this.$emit('tts-state', state)
        }),
        await AbsTTSPlayer.addListener('onParagraph', (data) => {
          if (data && !this.ttsSkipInProgress) this.ttsNativeFollow?.(data)
        }),
        await AbsTTSPlayer.addListener('onError', (data) => {
          console.error('[ttsPlayer] Native TTS error', data?.error)
          if ((data?.error || '').includes('not supported')) {
            this.$toast.warning(this.$strings.MessageReadAloudNoVoice)
          } else {
            this.$toast.error(this.$strings.MessageReadAloudFailed)
          }
        })
      ]
    },
    async ttsRemoveNativeListeners() {
      const listeners = this.ttsNativeListeners || []
      this.ttsNativeListeners = null
      for (const listener of listeners) {
        await listener.remove().catch(() => {})
      }
    },
    async startWebTTS() {
      this.ttsSessionId++
      const session = this.ttsSessionId
      await TextToSpeech.stop().catch(() => {})
      await this.ttsResolveWebVoiceIndex()

      const lang = this.ereaderSettings.ttsLanguage || 'en-US'
      TextToSpeech.isLanguageSupported({ lang })
        .then((result) => {
          if (!result.supported) {
            this.$toast.warning(this.$strings.MessageReadAloudNoVoice)
          }
        })
        .catch(() => {})

      const paragraphs = await Promise.resolve(this.ttsCollectParagraphs()).catch((error) => {
        console.error('[ttsPlayer] Failed to collect paragraphs', error)
        return []
      })
      if (session !== this.ttsSessionId) return
      if (!paragraphs?.length) {
        this.$toast.error(this.$strings.MessageReadAloudNoText)
        return
      }

      this.ttsParagraphs = paragraphs
      let startIndex = this.ttsStartIndex?.(paragraphs) || 0
      this.ttsParagraphIndex = Math.max(0, Math.min(startIndex, paragraphs.length - 1))
      this.ttsState = 'playing'
      this.$emit('tts-state', 'playing')
      this.speakCurrentParagraph()
    },
    pauseTTS() {
      if (this.ttsState !== 'playing') return
      if (this.ttsUseNative()) {
        AbsTTSPlayer.pause().catch(() => {})
        return
      }
      this.ttsState = 'paused'
      this.ttsSessionId++
      TextToSpeech.stop().catch(() => {})
      this.$emit('tts-state', 'paused')
    },
    async resumeTTS() {
      if (this.ttsState !== 'paused') return
      if (this.ttsUseNative()) {
        this.resumeNativeTTS()
        return
      }
      // Paged away from the paused paragraph while paused - continue from the
      // page on screen instead of jumping back to where the pause happened
      const paused = this.ttsParagraphs[this.ttsParagraphIndex]
      if (paused && this.ttsIsParagraphVisible?.({ ref: paused.ref, paragraphIndex: this.ttsParagraphIndex }) === false) {
        await this.ttsSeekToVisiblePage()
        if (this.ttsState !== 'paused') return
      }
      this.ttsState = 'playing'
      this.$emit('tts-state', 'playing')
      this.speakNextChunk()
    },
    async resumeNativeTTS() {
      // The native session can belong to another book by now (started from
      // another reader or from Android Auto) - resuming would speak that book,
      // so only resume this book's session and otherwise start fresh
      const state = await AbsTTSPlayer.getState().catch(() => null)
      if (!state?.libraryItemId || state.libraryItemId !== this.libraryItem?.id) {
        this.startTTS()
        return
      }
      // Paged away from the paused paragraph while paused - continue from the
      // page on screen instead of jumping back to where the pause happened
      if (this.ttsNativeStartPosition && this.ttsIsParagraphVisible?.({ location: state.location, paragraphIndex: state.paragraphIndex }) === false) {
        await this.ttsSeekToVisiblePage()
      }
      AbsTTSPlayer.play({}).catch(() => {})
    },
    stopTTS() {
      const wasActive = this.ttsState !== 'stopped'
      this.ttsState = 'stopped'
      if (this.ttsUseNative()) {
        // Only a reader attached to the session (state synced via listeners)
        // stops it - never a background session of another book
        if (wasActive) AbsTTSPlayer.stop().catch(() => {})
        this.ttsRemoveNativeListeners()
        this.ttsNativeBook = null
        if (wasActive) this.$emit('tts-state', 'stopped')
        return
      }
      this.ttsSessionId++
      TextToSpeech.stop().catch(() => {})
      this.ttsParagraphs = []
      this.ttsParagraphIndex = 0
      this.ttsChunks = []
      this.ttsChunkIndex = 0
      if (wasActive) this.$emit('tts-state', 'stopped')
    },
    speakCurrentParagraph() {
      const paragraph = this.ttsParagraphs[this.ttsParagraphIndex]
      if (!paragraph) {
        this.ttsAdvance()
        return
      }
      if (!this.ttsSkipInProgress) this.ttsFollowParagraph?.(paragraph)
      this.ttsChunks = this.splitTextChunks(paragraph.text)
      this.ttsChunkIndex = 0
      this.speakNextChunk()
    },
    async speakNextChunk() {
      if (this.ttsState !== 'playing') return

      if (this.ttsChunkIndex >= this.ttsChunks.length) {
        this.ttsParagraphIndex++
        if (this.ttsParagraphIndex >= this.ttsParagraphs.length) {
          this.ttsAdvance()
        } else {
          this.speakCurrentParagraph()
        }
        return
      }

      const session = this.ttsSessionId
      try {
        await TextToSpeech.speak({
          text: this.ttsChunks[this.ttsChunkIndex],
          lang: this.ereaderSettings.ttsLanguage || 'en-US',
          rate: this.ereaderSettings.ttsRate || 1,
          category: 'playback',
          ...(this.ttsWebVoiceIndex != null ? { voice: this.ttsWebVoiceIndex } : {})
        })
      } catch (error) {
        // Rejection is expected when speech gets interrupted by stop()
        if (session !== this.ttsSessionId || this.ttsState !== 'playing') return
        console.error('[ttsPlayer] TTS speak failed', error)
        this.$toast.error(this.$strings.MessageReadAloudFailed)
        this.stopTTS()
        return
      }
      if (session !== this.ttsSessionId || this.ttsState !== 'playing') return

      this.ttsChunkIndex++
      this.speakNextChunk()
    },
    async ttsAdvance() {
      if (this.ttsState !== 'playing') return
      if (!this.ttsAdvanceUnit) {
        this.stopTTS()
        return
      }

      const session = this.ttsSessionId
      const paragraphs = await Promise.resolve(this.ttsAdvanceUnit()).catch((error) => {
        console.error('[ttsPlayer] Failed to advance unit', error)
        return null
      })
      if (session !== this.ttsSessionId || this.ttsState !== 'playing') return
      if (!paragraphs?.length) {
        // Reached the end of the book
        this.stopTTS()
        return
      }
      this.ttsParagraphs = paragraphs
      this.ttsParagraphIndex = 0
      this.speakCurrentParagraph()
    },
    /**
     * Native TTS engines limit utterance length and cannot be interrupted
     * mid-utterance on all platforms, so speak in sentence-sized chunks
     * @returns {string[]}
     */
    splitTextChunks(text, maxLength = 300) {
      const chunks = []
      const sentences = text.match(/[^.!?…]+[.!?…]+["'”’)]*\s*|[^.!?…]+$/g) || [text]
      let current = ''
      for (const sentence of sentences) {
        if (current && current.length + sentence.length > maxLength) {
          chunks.push(current)
          current = ''
        }
        if (sentence.length > maxLength) {
          let remaining = sentence.trim()
          while (remaining.length > maxLength) {
            let cut = remaining.lastIndexOf(' ', maxLength)
            if (cut <= 0) cut = maxLength
            chunks.push(remaining.slice(0, cut))
            remaining = remaining.slice(cut)
          }
          current = remaining
        } else {
          current += sentence
        }
      }
      if (current) chunks.push(current)
      return chunks.map((c) => c.trim()).filter((c) => c)
    },
    /**
     * Collect readable text elements from a rendered HTML document
     * @returns {Array<{ text: string, ref: Element }>}
     */
    ttsCollectHtmlParagraphs(documentBody) {
      const textElementsSelector = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, figcaption, dt, dd'
      const paragraphs = []
      const elements = documentBody?.querySelectorAll(textElementsSelector) || []
      elements.forEach((el) => {
        // Skip elements nested inside another matched element to avoid reading text twice
        if (el.parentElement?.closest(textElementsSelector)) return
        const text = (el.innerText || el.textContent || '').trim()
        if (!text) return
        paragraphs.push({ text, ref: el })
      })

      // Fallback for books not using standard text elements
      if (!paragraphs.length) {
        const bodyText = (documentBody?.innerText || '').trim()
        if (bodyText) {
          paragraphs.push({ text: bodyText, ref: documentBody })
        }
      }
      return paragraphs
    }
  },
  created() {
    // State of a native read aloud session of this book that is running or
    // paused in the background, null when there is none. Resolved once, before
    // the reader loads its content, so it can open at the spoken position.
    // A session of another book is never adopted, otherwise the play button
    // would resume that book instead of starting this one.
    this.ttsNativeSessionState = this.ttsUseNative()
      ? AbsTTSPlayer.getState()
          .then((state) => (state?.state && state.state !== 'stopped' && state.libraryItemId && state.libraryItemId === this.libraryItem?.id ? state : null))
          .catch(() => null)
      : Promise.resolve(null)
  },
  async mounted() {
    // Re-attach to a native TTS session that kept playing in the background
    // after the reader was closed: follow-along events and the play/pause
    // state, the reader itself positions on the session (ttsNativeSessionState)
    const state = await this.ttsNativeSessionState
    if (state) {
      await this.ttsRegisterNativeListeners()
      this.ttsState = state.state
      this.$emit('tts-state', state.state)
    }
  },
  beforeDestroy() {
    if (this.ttsUseNative()) {
      // Native playback intentionally continues in the background when the
      // reader closes - that is the point of the native player. Only detach
      // the follow-along listeners; the user stops it from the notification
      // or with the stop button next time the reader opens.
      this.ttsRemoveNativeListeners()
      return
    }
    this.stopTTS()
  }
}
