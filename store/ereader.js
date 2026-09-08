import { normalizeEreaderSettings } from '@/utils/ereaderSettings'

/**
 * Global ereader and read aloud (TTS) settings - the defaults for every book.
 *
 * Persisted with the native Preferences plugin (the same store as the app
 * theme and language) instead of WebView localStorage, which the system can
 * drop: losing the settings silently put read aloud back to the built-in
 * default language. Settings saved by older versions in localStorage are
 * migrated on the first load.
 */

const LEGACY_STORAGE_KEY = 'ereaderSettings'

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

export const state = () => ({
  // null until loaded
  settings: null
})

export const getters = {
  isLoaded: (state) => !!state.settings,
  /** Loaded settings, or the defaults while not loaded yet */
  getSettings: (state) => state.settings || normalizeEreaderSettings(null)
}

export const actions = {
  /**
   * Load the settings once (concurrent callers share the load)
   * @returns {Promise<Object>} the settings
   */
  load({ state, commit }) {
    if (state.settings) return Promise.resolve(state.settings)
    if (!loadPromise) {
      loadPromise = (async () => {
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
  }
}
