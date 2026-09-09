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

let loadPromise = null

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
  deviceId: null
})

export const getters = {
  isLoaded: (state) => !!state.settings,
  /** Loaded settings, or the defaults while not loaded yet */
  getSettings: (state) => state.settings || normalizeEreaderSettings(null),
  getDeviceId: (state) => state.deviceId
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
  }
}

export const mutations = {
  setSettings(state, settings) {
    state.settings = settings
  },
  setDeviceId(state, deviceId) {
    state.deviceId = deviceId
  }
}
