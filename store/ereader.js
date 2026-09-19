import { normalizeEreaderSettings } from '@/utils/ereaderSettings'

/**
 * Global ereader and read aloud (TTS) settings - the defaults for every book.
 *
 * Persisted with the native Preferences plugin (the same store as the app
 * theme and language) instead of WebView localStorage, which the system can
 * drop: losing the settings silently put read aloud back to the built-in
 * default language. Settings saved by older versions in localStorage are
 * migrated on the first load.
 *
 * The module also holds the id of this device the per-book appearance is
 * stored under on the server (see BOOK_DEVICE_SETTING_KEYS in
 * utils/ereaderSettings.js).
 */

const LEGACY_STORAGE_KEY = 'ereaderSettings'
const DEVICE_ID_PREFERENCE_KEY = 'ereaderDeviceId'
// Per-book settings updates not yet acknowledged by the server, keyed by
// library item id: { serverAddress, merge, payload, queuedAt }. Kept in the
// preferences so a save the app could not send (locked right after a font
// change, killed in the background) goes out on the next start instead of
// being overruled by the server copy when the book is opened again.
const PENDING_BOOK_SETTINGS_PREFERENCE_KEY = 'ereaderPendingBookSettings'
const PENDING_BOOK_SETTINGS_MAX_AGE = 30 * 24 * 60 * 60 * 1000

let loadPromise = null
let flushPromise = null

function readJsonPreference(store, key) {
  return store.$localStore.getPreferenceByKey(key).then((raw) => {
    try {
      const parsed = raw ? JSON.parse(raw) : null
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
    } catch (error) {
      console.error(`[ereader] Invalid preference "${key}"`, error)
      return {}
    }
  })
}

function readLegacySettings() {
  try {
    if (typeof localStorage === 'undefined') return null
    const raw = localStorage.getItem(LEGACY_STORAGE_KEY)
    return raw ? JSON.parse(raw) : null
  } catch (error) {
    console.error('[ereader] Invalid legacy ereader settings', error)
    return null
  }
}

/** Random id for a device the native layer reports no id for (web builds) */
function generateDeviceId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (char) => {
    const random = (Math.random() * 16) | 0
    return (char === 'x' ? random : (random & 0x3) | 0x8).toString(16)
  })
}

/**
 * Id of this device: the one the native layer reports (Android id, iOS vendor
 * id - the id the server sees in the playback sessions), otherwise an id
 * generated once and kept in the preferences.
 * @param {import('vuex').Store} store
 * @returns {Promise<string>}
 */
async function resolveDeviceId(store) {
  let deviceData = store.state.deviceData
  if (!deviceData?.deviceId) {
    deviceData = await store.$db.getDeviceData().catch((error) => {
      console.error('[ereader] Failed to load the device data', error)
      return null
    })
  }
  if (deviceData?.deviceId) return String(deviceData.deviceId)

  let deviceId = await store.$localStore.getPreferenceByKey(DEVICE_ID_PREFERENCE_KEY)
  if (!deviceId) {
    deviceId = generateDeviceId()
    console.log('[ereader] Generated the device id for the per-device book settings')
    await store.$localStore.setPreferenceByKey(DEVICE_ID_PREFERENCE_KEY, deviceId)
  }
  return deviceId
}

export const state = () => ({
  // null until loaded
  settings: null,
  // Id of this device (loaded with the settings), null until loaded
  deviceId: null,
  // Per-book settings updates waiting for the server (see PENDING_BOOK_SETTINGS_PREFERENCE_KEY), null until loaded
  pendingBookSettings: null
})

export const getters = {
  isLoaded: (state) => !!state.settings,
  /** Loaded settings, or the defaults while not loaded yet */
  getSettings: (state) => state.settings || normalizeEreaderSettings(null),
  getDeviceId: (state) => state.deviceId,
  /**
   * The per-book settings update of a book still waiting for the server, or null
   * @returns {(libraryItemId: string, serverAddress: string) => { merge: boolean, payload: Object|null }|null}
   */
  getPendingBookSettings: (state) => (libraryItemId, serverAddress) => {
    const pending = state.pendingBookSettings?.[libraryItemId]
    return pending && pending.serverAddress === serverAddress ? pending : null
  }
}

export const actions = {
  /**
   * Load the settings and the device id once (concurrent callers share the load)
   * @returns {Promise<Object>} the settings
   */
  load({ state, commit }) {
    if (state.settings && state.deviceId) return Promise.resolve(state.settings)
    if (!loadPromise) {
      loadPromise = (async () => {
        const deviceIdLoad = resolveDeviceId(this).catch((error) => {
          console.error('[ereader] Failed to resolve the device id', error)
          return generateDeviceId()
        })
        let stored = await this.$localStore.getEreaderSettings()
        if (!stored) {
          stored = readLegacySettings()
          if (stored) {
            console.log('[ereader] Migrating ereader settings from localStorage')
            await this.$localStore.setEreaderSettings(stored)
          }
        }
        const settings = normalizeEreaderSettings(stored)
        commit('setSettings', settings)
        commit('setDeviceId', await deviceIdLoad)
        return settings
      })().finally(() => {
        loadPromise = null
      })
    }
    return loadPromise
  },
  /**
   * Save the settings as the new global defaults
   * @returns {Promise<Object>} the normalized settings
   */
  async save({ commit }, settings) {
    const normalized = normalizeEreaderSettings(settings)
    commit('setSettings', normalized)
    await this.$localStore.setEreaderSettings(normalized)
    return normalized
  },
  /** Load the pending per-book settings updates once, dropping stale ones */
  async loadPendingBookSettings({ state, commit }) {
    if (state.pendingBookSettings) return state.pendingBookSettings
    const stored = await readJsonPreference(this, PENDING_BOOK_SETTINGS_PREFERENCE_KEY)
    const pending = {}
    for (const libraryItemId of Object.keys(stored)) {
      const entry = stored[libraryItemId]
      if (!entry?.serverAddress || entry.payload === undefined || Date.now() - (entry.queuedAt || 0) > PENDING_BOOK_SETTINGS_MAX_AGE) continue
      pending[libraryItemId] = entry
    }
    commit('setPendingBookSettings', pending)
    return pending
  },
  /**
   * Remember a per-book settings update until the server acknowledges it
   * @param {{ libraryItemId: string, serverAddress: string, merge: boolean, payload: Object|null }} update
   */
  async queueBookSettings({ dispatch, commit, state }, update) {
    await dispatch('loadPendingBookSettings')
    commit('setPendingBookSettingsEntry', { libraryItemId: update.libraryItemId, entry: { ...update, queuedAt: Date.now() } })
    await this.$localStore.setPreferenceByKey(PENDING_BOOK_SETTINGS_PREFERENCE_KEY, JSON.stringify(state.pendingBookSettings))
  },
  /**
   * Forget a pending update once it reached the server - only when it is still
   * the one queued (a newer edit may have replaced it meanwhile)
   * @param {{ libraryItemId: string, payload: Object|null }} update
   */
  async clearPendingBookSettings({ dispatch, commit, state }, { libraryItemId, payload }) {
    await dispatch('loadPendingBookSettings')
    const pending = state.pendingBookSettings[libraryItemId]
    if (!pending || JSON.stringify(pending.payload) !== JSON.stringify(payload)) return
    commit('setPendingBookSettingsEntry', { libraryItemId, entry: null })
    await this.$localStore.setPreferenceByKey(PENDING_BOOK_SETTINGS_PREFERENCE_KEY, JSON.stringify(state.pendingBookSettings))
  },
  /**
   * Send the pending updates of the connected server (one book, or all of them)
   * @param {{ libraryItemId?: string }} [options]
   */
  flushPendingBookSettings({ dispatch, state, rootState, rootGetters }, options = {}) {
    if (flushPromise) return flushPromise
    flushPromise = (async () => {
      const serverAddress = rootGetters['user/getServerAddress']
      if (!serverAddress || !rootState.user.user || !rootState.networkConnected) return
      const pending = await dispatch('loadPendingBookSettings')
      const libraryItemIds = Object.keys(pending).filter((id) => pending[id].serverAddress === serverAddress && (!options.libraryItemId || id === options.libraryItemId))
      for (const libraryItemId of libraryItemIds) {
        const entry = pending[libraryItemId]
        try {
          await this.$nativeHttp.patch(`/api/me/progress/${libraryItemId}`, { ebookSettings: entry.payload }, { connectTimeout: 5000, readTimeout: 5000 })
          await dispatch('clearPendingBookSettings', { libraryItemId, payload: entry.payload })
          console.log(`[ereader] Sent the pending book settings of ${libraryItemId}`)
        } catch (error) {
          console.warn(`[ereader] Pending book settings of ${libraryItemId} still not sent:`, error?.message || error)
        }
      }
    })().finally(() => {
      flushPromise = null
    })
    return flushPromise
  }
}

export const mutations = {
  setSettings(state, settings) {
    state.settings = settings
  },
  setDeviceId(state, deviceId) {
    state.deviceId = deviceId
  },
  setPendingBookSettings(state, pending) {
    state.pendingBookSettings = pending
  },
  setPendingBookSettingsEntry(state, { libraryItemId, entry }) {
    const pending = { ...(state.pendingBookSettings || {}) }
    if (entry) pending[libraryItemId] = entry
    else delete pending[libraryItemId]
    state.pendingBookSettings = pending
  }
}
