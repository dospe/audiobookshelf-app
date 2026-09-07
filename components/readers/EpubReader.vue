<template>
  <div id="epub-frame" class="w-full">
    <div id="viewer" class="h-full w-full"></div>

    <div class="fixed left-0 h-8 w-full px-4 flex items-center" :class="isLightTheme ? 'bg-white text-black' : isDarkTheme ? 'bg-[#232323] text-white/80' : 'bg-black text-white/80'" :style="{ bottom: isPlayerOpen ? '120px' : '0px' }">
      <p v-if="totalLocations" class="text-xs text-slate-600">Location {{ currentLocationNum }} of {{ totalLocations }}</p>
      <div class="flex-grow" />
      <p class="text-xs">{{ progress }}%</p>
    </div>
  </div>
</template>

<script>
import ePub, { EpubCFI } from 'epubjs'
import TTSPlayer from '@/mixins/ttsPlayer'

export default {
  mixins: [TTSPlayer],
  props: {
    url: String,
    libraryItem: {
      type: Object,
      default: () => {}
    },
    isLocal: Boolean,
    keepProgress: Boolean
  },
  data() {
    return {
      /** @type {ePub.Book} */
      book: null,
      /** @type {ePub.Rendition} */
      rendition: null,
      progress: 0,
      totalLocations: 0,
      currentLocationNum: 0,
      currentLocationCfi: null,
      inittingDisplay: true,
      isRefreshingUI: false,
      ttsSectionIndex: 0,
      ereaderSettings: {
        theme: 'dark',
        font: 'serif',
        fontScale: 100,
        lineSpacing: 115,
        textStroke: 0,
        ttsLanguage: 'en-US',
        ttsRate: 1
      }
    }
  },
  watch: {
    isPlayerOpen() {
      this.refreshUI()
    }
  },
  computed: {
    /** @returns {string} */
    libraryItemId() {
      return this.libraryItem?.id
    },
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
    isPlayerOpen() {
      return this.$store.getters['getIsPlayerOpen']
    },
    readerHeightOffset() {
      return this.isPlayerOpen ? 204 : 104
    },
    /** @returns {Array<ePub.NavItem>} */
    chapters() {
      return this.book?.navigation?.toc || []
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
    localStorageLocationsKey() {
      return `ebookLocations-${this.libraryItemId}`
    },
    /**
     * Saved reading position. Usually an epubcfi, but read aloud falls back to
     * the start of the spoken chapter when the extraction produced no cfi for
     * the paragraph, so a spine href is a valid saved location too.
     * @returns {string|null}
     */
    savedEbookLocation() {
      if (!this.keepProgress) return null
      if (!this.userItemProgress?.ebookLocation) return null
      return String(this.userItemProgress.ebookLocation)
    },
    /** @returns {number} saved position as a ratio of the whole book, 0 when there is none */
    savedEbookProgress() {
      if (!this.keepProgress) return 0
      const progress = Number(this.userItemProgress?.ebookProgress)
      if (isNaN(progress) || progress <= 0 || progress >= 1) return 0
      return progress
    },
    isLightTheme() {
      return this.ereaderSettings.theme === 'light'
    },
    isDarkTheme() {
      return this.ereaderSettings.theme === 'dark'
    },
    themeRules() {
      const isDark = this.ereaderSettings.theme === 'dark'
      const isBlack = this.ereaderSettings.theme === 'black'
      const fontColor = isDark ? '#fff' : isBlack ? '#fff' : '#000'
      const backgroundColor = isDark ? 'rgb(35 35 35)' : isBlack ? 'rgb(0 0 0)' : 'rgb(255, 255, 255)'

      return {
        '*': {
          color: `${fontColor}!important`,
          'background-color': `${backgroundColor}!important`,
          'line-height': this.ereaderSettings.lineSpacing + '%!important',
          '-webkit-text-stroke': this.ereaderSettings.textStroke / 100 + 'px ' + fontColor + '!important'
        },
        a: {
          color: `${fontColor}!important`
        }
      }
    }
  },
  methods: {
    updateSettings(settings) {
      this.ttsHandleSettingsChange(settings)
      this.ereaderSettings = settings

      if (!this.rendition) return

      this.applyTheme()

      const fontScale = settings.fontScale || 100
      this.rendition.themes.fontSize(`${fontScale}%`)
      this.rendition.themes.font(settings.font)
      this.rendition.spread(settings.spread || 'auto')
    },
    goToChapter(href) {
      return this.rendition?.display(href)
    },
    /**
     * TTS hook: paragraphs of the section at the current reading location.
     * Paragraph `ref` is the epub cfi of the element, used to follow along.
     */
    ttsCollectParagraphs() {
      const location = this.rendition?.currentLocation()
      if (!location?.start) return []
      this.ttsSectionIndex = location.start.index
      return this.ttsCollectSectionParagraphs()
    },
    /** TTS hook: start from the first paragraph on the currently visible page */
    ttsStartIndex(paragraphs) {
      const location = this.rendition?.currentLocation()
      if (!location?.start?.cfi) return 0
      const cfiCompare = new EpubCFI()
      const startIndex = paragraphs.findIndex((p) => {
        try {
          return p.ref && cfiCompare.compare(p.ref, location.start.cfi) >= 0
        } catch (error) {
          return false
        }
      })
      return startIndex < 0 ? paragraphs.length - 1 : startIndex
    },
    /** TTS hook: display the next spine section, skipping ones with no readable text */
    async ttsAdvanceUnit() {
      let nextSection = this.book.spine.get(this.ttsSectionIndex + 1)
      while (nextSection) {
        this.ttsSectionIndex = nextSection.index
        const session = this.ttsSessionId
        await this.rendition.display(nextSection.href).catch((error) => {
          console.error('[EpubReader] TTS failed to display section', error)
        })
        if (session !== this.ttsSessionId) return null

        const paragraphs = this.ttsCollectSectionParagraphs()
        if (paragraphs.length) return paragraphs
        nextSection = this.book.spine.get(this.ttsSectionIndex + 1)
      }
      return null
    },
    /** TTS hook: turn the page when the spoken paragraph is not on the visible page */
    ttsFollowParagraph(paragraph) {
      const cfi = paragraph.ref
      if (!cfi) return
      const location = this.rendition?.currentLocation()
      if (!location?.start?.cfi || !location?.end?.cfi) return
      try {
        const cfiCompare = new EpubCFI()
        if (cfiCompare.compare(cfi, location.end.cfi) >= 0 || cfiCompare.compare(cfi, location.start.cfi) < 0) {
          this.rendition.display(cfi).catch((error) => {
            console.error('[EpubReader] TTS failed to follow location', error)
          })
        }
      } catch (error) {
        console.error('[EpubReader] TTS failed to compare locations', error)
      }
    },
    /** @returns {Array<{ text: string, ref: string }>} paragraphs with their cfi as ref */
    ttsCollectSectionParagraphs() {
      const contents = this.getTTSSectionContents()
      if (!contents) return []
      return this.ttsCollectHtmlParagraphs(contents.document?.body).map((p) => {
        let cfi = null
        try {
          cfi = contents.cfiFromNode(p.ref)
        } catch (error) {
          console.error('[EpubReader] TTS failed to get cfi for element', error)
        }
        return { text: p.text, ref: cfi }
      })
    },
    getTTSSectionContents() {
      const contents = this.rendition?.getContents() || []
      return contents.find((c) => c.sectionIndex === this.ttsSectionIndex) || contents[0] || null
    },
    /**
     * Native TTS hook: extract the whole book by walking the spine without
     * rendering. Paragraph location is the epub cfi of the element.
     */
    async ttsExtractBook() {
      if (!this.book?.spine) return null

      // Map spine hrefs to chapter titles from the toc
      const tocTitles = {}
      const addTocItems = (items) => {
        for (const item of items || []) {
          const href = (item.href || '').split('#')[0]
          if (href && !tocTitles[href]) tocTitles[href] = item.label?.trim() || ''
          addTocItems(item.subitems)
        }
      }
      addTocItems(this.chapters)

      const chapters = []
      for (const section of this.book.spine.spineItems || []) {
        if (section.linear === false || section.linear === 'no') continue
        try {
          const doc = await section.load(this.book.load.bind(this.book))
          const body = doc?.querySelector?.('body') || doc?.getElementsByTagName?.('body')?.[0] || doc
          const paragraphs = this.ttsCollectHtmlParagraphs(body).map((p) => {
            let cfi = null
            try {
              cfi = new EpubCFI(p.ref, section.cfiBase).toString()
            } catch (error) {
              // paragraph stays speakable without follow-along
            }
            return { text: p.text, location: cfi, chars: p.text.length }
          })
          section.unload()
          if (!paragraphs.length) continue
          chapters.push({
            title: tocTitles[(section.href || '').split('#')[0]] || '',
            startLocation: section.href || '',
            // Fallback saved position for paragraphs whose cfi could not be built
            startCfi: section.cfiBase ? `epubcfi(${section.cfiBase}!/4)` : null,
            paragraphs
          })
        } catch (error) {
          console.error('[EpubReader] ttsExtractBook failed to load section', section.href, error)
        }
      }
      return { ebookFormat: 'epub', chapters }
    },
    /** Native TTS hook: start at the chapter/paragraph of the visible page */
    ttsNativeStartPosition(book) {
      const location = this.rendition?.currentLocation()
      const currentHref = this.book?.spine?.get(location?.start?.index)?.href
      const chapterIndex = book.chapters.findIndex((c) => c.startLocation === currentHref)
      if (chapterIndex < 0) return { chapterIndex: 0, paragraphIndex: 0 }

      const cfiCompare = new EpubCFI()
      let paragraphIndex = book.chapters[chapterIndex].paragraphs.findIndex((p) => {
        try {
          return p.location && cfiCompare.compare(p.location, location.start.cfi) >= 0
        } catch (error) {
          return false
        }
      })
      if (paragraphIndex < 0) paragraphIndex = 0
      return { chapterIndex, paragraphIndex }
    },
    /** Native TTS hook: follow the spoken paragraph while the reader is open */
    ttsNativeFollow(event) {
      if (event.location) this.ttsFollowParagraph({ ref: event.location })
    },
    /** TTS hook: whether the paragraph (an epub cfi) is on the visible page, null while nothing is displayed */
    ttsIsParagraphVisible(paragraph) {
      const cfi = paragraph.ref || paragraph.location
      const location = this.rendition?.currentLocation()
      if (!cfi || !location?.start?.cfi || !location?.end?.cfi) return null
      try {
        const cfiCompare = new EpubCFI()
        return cfiCompare.compare(cfi, location.start.cfi) >= 0 && cfiCompare.compare(cfi, location.end.cfi) < 0
      } catch (error) {
        return null
      }
    },
    /**
     * TTS hook: characters on the visible page, from the generated cfi
     * locations (100 characters each). 0 when the locations are not ready.
     */
    ttsEstimatePageChars() {
      const location = this.rendition?.currentLocation()
      const startLocation = location?.start?.location
      const endLocation = location?.end?.location
      if (!this.totalLocations || !(startLocation >= 0) || !(endLocation >= startLocation)) return 0
      return (endLocation - startLocation + 1) * 100
    },
    /** TTS hook: turn pages for the rewind/forward buttons */
    async ttsTurnPages(delta) {
      if (!this.rendition) return
      const pages = Math.abs(delta)
      for (let i = 0; i < pages; i++) {
        // Both resolve once the new page is displayed; at the ends of the book they are no-ops
        if (delta < 0) await this.rendition.prev()
        else await this.rendition.next()
      }
    },
    prev() {
      if (this.rendition) {
        this.rendition.prev()
      }
    },
    next() {
      if (this.rendition) {
        this.rendition.next()
      }
    },
    /**
     * @param {object} payload
     * @param {string} payload.ebookLocation - CFI of the current location
     * @param {string} payload.ebookProgress - eBook Progress Percentage
     */
    async updateProgress(payload) {
      if (!this.keepProgress) return

      // Update local item
      if (this.localLibraryItemId) {
        const localPayload = {
          localLibraryItemId: this.localLibraryItemId,
          ...payload
        }
        const localResponse = await this.$db.updateLocalEbookProgress(localPayload)
        if (localResponse.localMediaProgress) {
          this.$store.commit('globals/updateLocalMediaProgress', localResponse.localMediaProgress)
        }
      }

      // Update server item
      if (this.serverLibraryItemId) {
        this.$nativeHttp.patch(`/api/me/progress/${this.serverLibraryItemId}`, payload).catch((error) => {
          console.error('EpubReader.updateProgress failed:', error)
        })
      }
    },
    getAllEbookLocationData() {
      const locations = []
      let totalSize = 0 // Total in bytes

      for (const key in localStorage) {
        if (!localStorage.hasOwnProperty(key) || !key.startsWith('ebookLocations-')) {
          continue
        }

        try {
          const ebookLocations = JSON.parse(localStorage[key])
          if (!ebookLocations.locations) throw new Error('Invalid locations object')

          ebookLocations.key = key
          ebookLocations.size = (localStorage[key].length + key.length) * 2
          locations.push(ebookLocations)
          totalSize += ebookLocations.size
        } catch (error) {
          console.error('Failed to parse ebook locations', key, error)
          localStorage.removeItem(key)
        }
      }

      // Sort by oldest lastAccessed first
      locations.sort((a, b) => a.lastAccessed - b.lastAccessed)

      return {
        locations,
        totalSize
      }
    },
    /** @param {string} locationString */
    checkSaveLocations(locationString) {
      const maxSizeInBytes = 3000000 // Allow epub locations to take up to 3MB of space
      const newLocationsSize = JSON.stringify({ lastAccessed: Date.now(), locations: locationString }).length * 2

      // Too large overall
      if (newLocationsSize > maxSizeInBytes) {
        console.error('Epub locations are too large to store. Size =', newLocationsSize)
        return
      }

      const ebookLocationsData = this.getAllEbookLocationData()

      let availableSpace = maxSizeInBytes - ebookLocationsData.totalSize

      // Remove epub locations until there is room for locations
      while (availableSpace < newLocationsSize && ebookLocationsData.locations.length) {
        const oldestLocation = ebookLocationsData.locations.shift()
        console.log(`Removing cached locations for epub "${oldestLocation.key}" taking up ${oldestLocation.size} bytes`)
        availableSpace += oldestLocation.size
        localStorage.removeItem(oldestLocation.key)
      }

      console.log(`Cacheing epub locations with key "${this.localStorageLocationsKey}" taking up ${newLocationsSize} bytes`)
      this.saveLocations(locationString)
    },
    /** @param {string} locationString */
    saveLocations(locationString) {
      localStorage.setItem(
        this.localStorageLocationsKey,
        JSON.stringify({
          lastAccessed: Date.now(),
          locations: locationString
        })
      )
    },
    loadLocations() {
      const locationsObjString = localStorage.getItem(this.localStorageLocationsKey)
      if (!locationsObjString) return null

      const locationsObject = JSON.parse(locationsObjString)

      // Remove invalid location objects
      if (!locationsObject.locations) {
        console.error('Invalid epub locations stored', this.localStorageLocationsKey)
        localStorage.removeItem(this.localStorageLocationsKey)
        return null
      }

      // Update lastAccessed
      this.saveLocations(locationsObject.locations)

      return locationsObject.locations
    },
    /** Generate the cfi locations used by the location counter and by progress based resume */
    generateLocations() {
      return this.book.locations
        .generate(100)
        .then(() => {
          this.totalLocations = this.book.locations.length()
          this.currentLocationNum = this.rendition.currentLocation()?.start?.location || 0
          this.checkSaveLocations(this.book.locations.save())
        })
        .catch((error) => {
          console.error('[EpubReader] Failed to generate locations', error)
        })
    },
    /**
     * Spine section a saved location points into, null when it resolves to none
     * @param {string} location - cfi or spine href
     * @returns {ePub.Section|null}
     */
    getSpineSection(location) {
      try {
        return this.book.spine.get(location) || null
      } catch (error) {
        console.error(`[EpubReader] Invalid saved location ${location}`, error)
        return null
      }
    },
    /** @returns {string|null} cfi for the saved character ratio, needs the locations generated */
    cfiFromSavedProgress() {
      return this.cfiFromRatio(this.savedEbookProgress)
    },
    /**
     * @param {number} ratio - position as a ratio of the whole book
     * @returns {string|null} cfi at the ratio, null outside (0, 1) or while the locations are not generated
     */
    cfiFromRatio(ratio) {
      const progress = Number(ratio)
      if (!(progress > 0) || progress >= 1 || !this.book?.locations?.length()) return null
      try {
        // epubjs answers with -1 when the ratio maps outside the locations
        const cfi = this.book.locations.cfiFromPercentage(progress)
        return typeof cfi === 'string' && cfi.startsWith('epubcfi') ? cfi : null
      } catch (error) {
        console.error('[EpubReader] Failed to map the progress ratio to a cfi', error)
        return null
      }
    },
    /**
     * A spine href or a cfi with no path inside the section only locates the
     * chapter, not the position in it - read aloud saves those when the
     * extraction produced no paragraph cfis
     * @param {string} location
     */
    isChapterGranularityLocation(location) {
      if (!location.startsWith('epubcfi')) return true
      try {
        return (new EpubCFI(location).path?.steps?.length || 0) <= 1
      } catch (error) {
        return false
      }
    },
    /**
     * Where to open the book, most precise saved position first:
     * 1. the cfi saved by the reader or by read aloud following paragraph cfis
     * 2. the chapter saved by read aloud without paragraph cfis, refined with
     *    the character ratio when that lands in the same chapter
     * 3. the character ratio on its own
     * @returns {string|null} cfi or spine href to display, null to start at the beginning
     */
    getDisplayTarget() {
      return this.resolveDisplayTarget(this.savedEbookLocation, this.savedEbookProgress)
    },
    /**
     * Where a read aloud session of this book that is still running or paused
     * in the background is right now: the spoken paragraph cfi (reader
     * extraction), the chapter refined with the spoken character ratio (native
     * extraction has no paragraph cfis) or the ratio alone. The saved progress
     * can lag behind the engine while the WebView was not running, so this
     * comes first when a session exists.
     * @param {object|null} session - ttsNativeSessionState payload
     * @returns {string|null} cfi or spine href to display
     */
    getSessionDisplayTarget(session) {
      if (!session) return null
      const location = session.location ? String(session.location) : null
      const progress = Number(session.progress)
      return this.resolveDisplayTarget(location, progress > 0 && progress < 1 ? progress : 0)
    },
    /**
     * @param {string|null} savedLocation - cfi or spine href
     * @param {number} savedProgress - ratio of the whole book, 0 when unknown
     * @returns {string|null} cfi or spine href to display, null to start at the beginning
     */
    resolveDisplayTarget(savedLocation, savedProgress) {
      // A library item can hold ebook files of several formats sharing one
      // progress - a page number saved by the pdf reader is no spine target
      const isEpubLocation = savedLocation && (savedLocation.startsWith('epubcfi') || isNaN(savedLocation))
      const section = isEpubLocation ? this.getSpineSection(savedLocation) : null
      if (!section) return this.cfiFromRatio(savedProgress)
      if (!this.isChapterGranularityLocation(savedLocation)) return savedLocation

      const progressCfi = this.cfiFromRatio(savedProgress)
      if (progressCfi && this.getSpineSection(progressCfi)?.index === section.index) return progressCfi
      return savedLocation
    },
    /** @param {string} location - CFI of the new location */
    relocated(location) {
      console.log(`[EpubReader] relocated ${location.start.cfi}`)
      if (this.inittingDisplay) {
        console.log(`[EpubReader] relocated but initting display ${location.start.cfi}`)
        return
      }
      this.currentLocationNum = location.start.location

      if (this.currentLocationCfi === location.start.cfi) {
        console.log(`[EpubReader] location already saved`, location.start.cfi)
        return
      }

      console.log(`[EpubReader] Saving new location ${location.start.cfi}`)
      this.currentLocationCfi = location.start.cfi

      if (location.end.percentage) {
        this.updateProgress({
          ebookLocation: location.start.cfi,
          ebookProgress: location.end.percentage
        })
        this.progress = Math.round(location.end.percentage * 100)
      } else {
        this.updateProgress({
          ebookLocation: location.start.cfi
        })
      }
    },
    initEpub() {
      this.progress = Math.round((this.userItemProgress?.ebookProgress || 0) * 100)

      /** @type {EpubReader} */
      const reader = this

      // Use axios to make request because we have token refresh logic in interceptor
      const customRequest = async (url) => {
        try {
          return this.$axios.$get(url, {
            responseType: 'arraybuffer'
          })
        } catch (error) {
          console.error('EpubReader.initEpub customRequest failed:', error)
          throw error
        }
      }

      console.log('[EpubReader] initEpub', reader.url)
      /** @type {ePub.Book} */
      reader.book = new ePub(reader.url, {
        width: window.innerWidth,
        height: window.innerHeight - this.readerHeightOffset,
        openAs: 'epub',
        requestMethod: this.isLocal ? null : customRequest
      })

      /** @type {ePub.Rendition} */
      reader.rendition = reader.book.renderTo('viewer', {
        width: window.innerWidth,
        height: window.innerHeight - this.readerHeightOffset,
        snap: true,
        manager: 'continuous',
        flow: 'paginated'
      })

      reader.book.ready.then(async () => {
        console.log('%c [EpubReader] Book ready', 'color:cyan;')

        // Load the cached cfi locations first - resuming from a saved
        // character ratio needs them
        const savedLocations = this.loadLocations()
        if (savedLocations) {
          reader.book.locations.load(savedLocations)
          this.totalLocations = reader.book.locations.length()
        }

        // A read aloud session of this book still running or paused in the
        // background is the most current position - the saved progress in the
        // store lags behind it while the WebView was not running
        const ttsSession = await this.ttsNativeSessionState
        let displayCfi = this.getSessionDisplayTarget(ttsSession) || this.getDisplayTarget()
        if (!displayCfi && (this.savedEbookProgress || Number(ttsSession?.progress) > 0) && !reader.book.locations.length()) {
          // Only the character ratio of the position is usable (read aloud
          // extraction without cfis) - generating the locations maps it to a
          // position, worth the wait to not restart the book
          await this.generateLocations()
          displayCfi = this.getSessionDisplayTarget(ttsSession) || this.getDisplayTarget()
        }
        // Some epubs have spine entries referencing missing manifest items
        // (e.g. a dangling cover page). Displaying those fails and leaves the
        // reader blank - start at the first spine item that actually resolves.
        if (!displayCfi) {
          const firstValidSection = reader.book.spine.spineItems.find((section) => section.href && section.linear !== false)
          if (firstValidSection) displayCfi = firstValidSection.href
        }

        reader.rendition.on('displayed', async () => {
          console.log('%c [EpubReader] Rendition displayed', 'color:blue;')

          // Overriding the needsSnap function in epubjs `snap.js` to fix a bug with scrollLeft being a decimal
          reader.rendition.manager.snapper.needsSnap = function () {
            let left = Math.round(this.scrollLeft)
            let snapWidth = this.layout.pageWidth * this.layout.divisor
            return left % snapWidth !== 0
          }
        })

        reader.rendition.on('rendered', (section, view) => {
          this.applyTheme()
          console.log('%c [EpubReader] Rendition rendered', 'color:red;', section, view)
        })

        // set up event listeners
        reader.rendition.on('relocated', reader.relocated)

        reader.rendition.on('displayError', (err) => {
          console.log('[EpubReader] Display error', err)
        })

        reader.rendition.on('touchstart', (event) => {
          this.$emit('touchstart', event)
        })
        reader.rendition.on('touchend', (event) => {
          this.$emit('touchend', event)
        })

        // Locations not cached and not needed for the display target above
        if (!reader.book.locations.length()) {
          this.generateLocations()
        }

        // TODO: To get the correct page need to render twice. On book ready and after first display. Figure out why
        console.log(`[EpubReader] Displaying cfi ${displayCfi}`)
        this.currentLocationCfi = displayCfi
        reader.rendition
          .display(displayCfi)
          .then(() => {
            return reader.rendition.display(displayCfi)
          })
          .then(() => {
            this.inittingDisplay = false
          })
          .catch((error) => {
            // Saved location points into a section that no longer loads - fall
            // back to the first resolvable spine item instead of a blank reader
            console.error(`[EpubReader] Failed to display ${displayCfi}`, error)
            const firstValidSection = reader.book.spine.spineItems.find((section) => section.href && section.linear !== false)
            if (!firstValidSection) return
            this.currentLocationCfi = firstValidSection.href
            reader.rendition.display(firstValidSection.href).then(() => {
              this.inittingDisplay = false
            })
          })
      })
    },
    applyTheme() {
      if (!this.rendition) return
      this.rendition.getContents().forEach((c) => {
        c.addStylesheetRules(this.themeRules)
      })
    },
    async screenOrientationChange() {
      if (this.isRefreshingUI) return
      this.isRefreshingUI = true
      const windowWidth = window.innerWidth
      this.refreshUI()

      // Window width does not always change right away. Wait up to 250ms for a change.
      // iPhone 10 on iOS 16 took between 100 - 200ms to update when going from portrait to landscape
      //   but landscape to portrait was immediate
      for (let i = 0; i < 5; i++) {
        await new Promise((resolve) => setTimeout(resolve, 50))
        if (window.innerWidth !== windowWidth) {
          this.refreshUI()
          break
        }
      }

      this.isRefreshingUI = false
    },
    refreshUI() {
      if (this.rendition?.resize) {
        this.rendition.resize(window.innerWidth, window.innerHeight - this.readerHeightOffset)
      }
    }
  },
  mounted() {
    this.initEpub()

    if (screen.orientation) {
      // Not available on ios
      screen.orientation.addEventListener('change', this.screenOrientationChange)
    } else {
      document.addEventListener('orientationchange', this.screenOrientationChange)
    }
    window.addEventListener('resize', this.screenOrientationChange)
  },
  beforeDestroy() {
    this.book?.destroy()

    if (screen.orientation) {
      // Not available on ios
      screen.orientation.removeEventListener('change', this.screenOrientationChange)
    } else {
      document.removeEventListener('orientationchange', this.screenOrientationChange)
    }
    window.removeEventListener('resize', this.screenOrientationChange)
  }
}
</script>

<style>
#epub-frame {
  height: calc(100% - 32px);
  max-height: calc(100% - 32px);
  overflow: hidden;
}
.reader-player-open #epub-frame {
  height: calc(100% - 132px);
  max-height: calc(100% - 132px);
  overflow: hidden;
}
</style>
