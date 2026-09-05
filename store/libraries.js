const { BookCoverAspectRatio } = require('../plugins/constants')

export const state = () => ({
  libraries: [],
  lastLoad: 0,
  currentLibraryId: '',
  showModal: false,
  issues: 0,
  filterData: null,
  numUserPlaylists: 0,
  ereaderDevices: [],
  scanningLibraryIds: [],
  // libraryId -> { startedAt, lastScan }: when the scan was seen starting and the
  // library's lastScan value before it, for the scan status fallback
  scanBaseline: {}
})

// Library scan status fallback: the "scan_complete" socket event is lost while
// the app is in the background, so while a scan is pending the library is
// re-read from the server and a changed lastScan means the scan finished.
// Skip the check right after a scan starts and give up after a long time
// without an answer.
const SCAN_STATUS_GRACE_MS = 10 * 1000
const SCAN_STATUS_TIMEOUT_MS = 15 * 60 * 1000

/** @returns {number|null} lastScan of a GET /api/libraries/:id payload (plain library or { library }) */
const lastScanOf = (payload) => {
  const library = payload?.library || payload
  return library?.lastScan || null
}

export const getters = {
  getCurrentLibrary: state => {
    return state.libraries.find(lib => lib.id === state.currentLibraryId)
  },
  getIsCurrentLibraryScanning: state => {
    return !!state.currentLibraryId && state.scanningLibraryIds.includes(state.currentLibraryId)
  },
  getCurrentLibraryName: (state, getters) => {
    return getters.getCurrentLibrary?.name || null
  },
  getCurrentLibraryMediaType: (state, getters) => {
    return getters.getCurrentLibrary?.mediaType || null
  },
  getCurrentLibrarySettings: (state, getters) => {
    return getters.getCurrentLibrary?.settings || null
  },
  getBookCoverAspectRatio: (state, getters) => {
    if (isNaN(getters.getCurrentLibrarySettings?.coverAspectRatio)) return 1
    return getters.getCurrentLibrarySettings.coverAspectRatio === BookCoverAspectRatio.STANDARD ? 1.6 : 1
  },
  getLibraryIsAudiobooksOnly: (state, getters) => {
    return !!getters.getCurrentLibrarySettings?.audiobooksOnly
  }
}

export const actions = {
  fetch({ state, commit, dispatch, rootState }, libraryId) {
    if (!rootState.user || !rootState.user.user) {
      console.error('libraries/fetch - User not set')
      return false
    }

    return this.$nativeHttp
      .get(`/api/libraries/${libraryId}?include=filterdata`)
      .then((data) => {
        const library = data.library
        const filterData = data.filterdata
        const issues = data.issues || 0
        const numUserPlaylists = data.numUserPlaylists || 0

        dispatch('user/checkUpdateLibrarySortFilter', library.mediaType, { root: true })

        commit('addUpdate', library)
        commit('setLibraryIssues', issues)
        commit('setLibraryFilterData', filterData)
        commit('setNumUserPlaylists', numUserPlaylists)
        commit('setCurrentLibrary', libraryId)
        return data
      })
      .catch((error) => {
        console.error('Failed', error)
        return false
      })
  },
  // Return true if calling load
  load({ state, commit, rootState }) {
    if (!rootState.user || !rootState.user.user) {
      console.error('libraries/load - User not set')
      return false
    }

    // Don't load again if already loaded in the last 5 minutes
    var lastLoadDiff = Date.now() - state.lastLoad
    if (lastLoadDiff < 5 * 60 * 1000) {
      // Already up to date
      return false
    }

    return this.$nativeHttp
      .get(`/api/libraries`)
      .then((data) => {
        // TODO: Server release 2.2.9 changed response to an object. Remove after a few releases
        const libraries = data.libraries || data

        // Set current library if not already set or was not returned in results
        if (libraries.length && (!state.currentLibraryId || !libraries.find(li => li.id == state.currentLibraryId))) {
          commit('setCurrentLibrary', libraries[0].id)
        }

        commit('set', libraries)
        commit('setLastLoad', Date.now())
        return true
      })
      .catch((error) => {
        console.error('Failed', error)
        commit('set', [])
        return false
      })
  },
  /**
   * Check the server for library scans that finished without the app
   * receiving the "scan_complete" socket event (e.g. while in the background).
   * Clears the scanning state of scans that are no longer running.
   * @returns {Promise<Array<{ id: string, name: string, timedOut: boolean }>>} scans that just finished
   */
  async checkScanStatus({ state, commit, rootState }) {
    if (!state.scanningLibraryIds.length || !rootState.user?.user) return []

    const now = Date.now()
    const finished = []
    for (const libraryId of [...state.scanningLibraryIds]) {
      const baseline = state.scanBaseline[libraryId] || {}
      const startedAt = baseline.startedAt || 0
      if (now - startedAt <= SCAN_STATUS_GRACE_MS) continue

      const payload = await this.$nativeHttp.get(`/api/libraries/${libraryId}`, { connectTimeout: 10000 }).catch((error) => {
        console.error('[libraries] checkScanStatus failed to load library', error)
        return null
      })
      const lastScan = lastScanOf(payload)

      let isDone = false
      let timedOut = false
      if (lastScan && baseline.lastScan === undefined) {
        // Scan started elsewhere (socket event only) - take the current value as the baseline
        commit('setScanBaselineLastScan', { libraryId, lastScan })
      } else if (lastScan && lastScan !== baseline.lastScan) {
        // The server stamps lastScan when a scan finishes
        isDone = true
      }
      if (!isDone && now - startedAt > SCAN_STATUS_TIMEOUT_MS) {
        // No answer for a long time (server unreachable or a very old server) - stop showing the scan as running
        isDone = true
        timedOut = true
      }
      if (!isDone) continue

      commit('setLibraryScanning', { libraryId, isScanning: false })
      const library = state.libraries.find((lib) => lib.id === libraryId)
      finished.push({ id: libraryId, name: library?.name || '', timedOut })
    }
    return finished
  }
}

export const mutations = {
  setShowModal(state, val) {
    state.showModal = val
  },
  setLastLoad(state, val) {
    state.lastLoad = val
  },
  reset(state) {
    state.lastLoad = 0
    state.currentLibraryId = null
    state.libraries = []
    state.scanningLibraryIds = []
    state.scanBaseline = {}
  },
  /**
   * @param {{ libraryId: string, isScanning: boolean, lastScan?: number|null }} payload
   *   lastScan: the library's lastScan before this scan (null when the library was never scanned), when known
   */
  setLibraryScanning(state, { libraryId, isScanning, lastScan }) {
    if (!libraryId) return
    const isListed = state.scanningLibraryIds.includes(libraryId)
    if (isScanning && !isListed) {
      state.scanningLibraryIds.push(libraryId)
      const baseline = { startedAt: Date.now() }
      if (lastScan !== undefined) baseline.lastScan = lastScan
      state.scanBaseline = { ...state.scanBaseline, [libraryId]: baseline }
    } else if (!isScanning && isListed) {
      state.scanningLibraryIds = state.scanningLibraryIds.filter((id) => id !== libraryId)
      const { [libraryId]: _removed, ...rest } = state.scanBaseline
      state.scanBaseline = rest
    }
  },
  setScanBaselineLastScan(state, { libraryId, lastScan }) {
    const baseline = state.scanBaseline[libraryId]
    if (!baseline) return
    state.scanBaseline = { ...state.scanBaseline, [libraryId]: { ...baseline, lastScan } }
  },
  setCurrentLibrary(state, val) {
    state.currentLibraryId = val
  },
  set(state, libraries) {
    state.libraries = libraries
  },
  addUpdate(state, library) {
    var index = state.libraries.findIndex(a => a.id === library.id)
    if (index >= 0) {
      state.libraries.splice(index, 1, library)
    } else {
      state.libraries.push(library)
    }
  },
  remove(state, library) {
    state.libraries = state.libraries.filter(a => a.id !== library.id)
  },
  setLibraryIssues(state, val) {
    state.issues = val
  },
  setNumUserPlaylists(state, numUserPlaylists) {
    state.numUserPlaylists = numUserPlaylists
  },
  setLibraryFilterData(state, filterData) {
    state.filterData = filterData
  },
  updateFilterDataWithAudiobook(state, audiobook) {
    if (!audiobook || !audiobook.book || !state.filterData) return
    if (state.currentLibraryId !== audiobook.libraryId) return
    /*
    var filterdata = {
      authors: [],
      genres: [],
      tags: [],
      series: [],
      narrators: []
    }
    */

    if (audiobook.book.authorFL) {
      audiobook.book.authorFL.split(', ').forEach((author) => {
        if (author && !state.filterData.authors.includes(author)) {
          state.filterData.authors.push(author)
        }
      })
    }
    if (audiobook.book.narratorFL) {
      audiobook.book.narratorFL.split(', ').forEach((narrator) => {
        if (narrator && !state.filterData.narrators.includes(narrator)) {
          state.filterData.narrators.push(narrator)
        }
      })
    }
    if (audiobook.book.series && !state.filterData.series.includes(audiobook.book.series)) {
      state.filterData.series.push(audiobook.book.series)
    }
    if (audiobook.tags && audiobook.tags.length) {
      audiobook.tags.forEach((tag) => {
        if (tag && !state.filterData.tags.includes(tag)) state.filterData.tags.push(tag)
      })
    }
    if (audiobook.book.genres && audiobook.book.genres.length) {
      audiobook.book.genres.forEach((genre) => {
        if (genre && !state.filterData.genres.includes(genre)) state.filterData.genres.push(genre)
      })
    }
  },
  setEReaderDevices(state, ereaderDevices) {
    state.ereaderDevices = ereaderDevices
  }
}