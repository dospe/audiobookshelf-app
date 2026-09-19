import Vue from 'vue'

/**
 * Ereader and read aloud (TTS) settings shared by the reader
 * (components/readers/Reader.vue) and the app settings page. The global
 * defaults live in the `ereader` store module; the reader keeps per-book
 * overrides of the appearance and of the read aloud language on the server.
 */

/**
 * Read aloud languages offered in the language toggle. `codes` are the ISO
 * 639-1/639-2 codes and `names` the language names a book's metadata may carry.
 */
export const TTS_LANGUAGES = Object.freeze([
  { value: 'cs-CZ', text: 'CZ', codes: ['cs', 'ces', 'cze'], names: ['czech', 'čeština', 'cestina', 'česky', 'cesky'] },
  { value: 'en-US', text: 'EN', codes: ['en', 'eng'], names: ['english', 'angličtina', 'anglictina'] }
])

export const DEFAULT_EREADER_SETTINGS = Object.freeze({
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
  // Voice per read aloud language ({ 'cs-CZ': voiceName })
  ttsVoices: {},
  // Read aloud bar: playback controls side ('left' | 'right') and pages per rewind/forward step
  ttsControlsSide: 'right',
  ttsPageStep: 3,
  // A newer reading position saved by another device while the reader is
  // open: 'auto' turns to it, 'ask' offers it, 'off' ignores it
  remotePosition: 'auto'
})

export const REMOTE_POSITION_MODES = Object.freeze(['auto', 'ask', 'off'])

const NUMERIC_KEYS = ['fontScale', 'lineSpacing', 'textStroke', 'ttsRate', 'ttsPageStep']

/** @returns {Array<{ text: string, value: string }>} items for the language toggle */
export function ttsLanguageItems() {
  return TTS_LANGUAGES.map(({ text, value }) => ({ text, value }))
}

/** @returns {boolean} whether the value is one of the offered read aloud languages */
export function isTtsLanguage(value) {
  return TTS_LANGUAGES.some((language) => language.value === value)
}

/**
 * Read aloud language for a language of a book or of the app: an ISO code
 * ('cs', 'ces'), a tag ('en-GB', 'cs_CZ') or a name ('Czech', 'čeština').
 * @param {string} raw
 * @returns {string|null} the offered language ('cs-CZ'), null when unknown or not offered
 */
export function ttsLanguageForBookLanguage(raw) {
  if (!raw || typeof raw !== 'string') return null
  // Some books list several languages ("cs; en") - the first one is the book's
  const value = raw.trim().toLowerCase().split(/[;,]/)[0].trim()
  if (!value) return null
  const primary = value.split(/[-_]/)[0]
  const match = TTS_LANGUAGES.find((language) => language.value.toLowerCase() === value || language.codes.includes(primary) || language.names.includes(value))
  return match?.value || null
}

/** Read aloud language matching the app UI language, for a device without a saved setting */
export function defaultTtsLanguage() {
  const uiLanguage = Vue.prototype.$languageCodes?.current || ''
  return ttsLanguageForBookLanguage(uiLanguage) || DEFAULT_EREADER_SETTINGS.ttsLanguage
}

/**
 * Stored settings (possibly partial, from an older version or damaged) merged
 * over the defaults. Always returns a fresh object.
 * @param {Object|null} stored
 */
export function normalizeEreaderSettings(stored) {
  const settings = { ...DEFAULT_EREADER_SETTINGS, ttsVoices: {}, ttsLanguage: defaultTtsLanguage() }
  if (!stored || typeof stored !== 'object') return settings

  for (const key in DEFAULT_EREADER_SETTINGS) {
    if (stored[key] === undefined || stored[key] === null) continue
    settings[key] = stored[key]
  }
  for (const key of NUMERIC_KEYS) {
    const value = Number(settings[key])
    settings[key] = isNaN(value) ? DEFAULT_EREADER_SETTINGS[key] : value
  }
  if (!(settings.ttsRate >= 0.5 && settings.ttsRate <= 2.5)) settings.ttsRate = DEFAULT_EREADER_SETTINGS.ttsRate
  if (!(settings.ttsPageStep > 0)) settings.ttsPageStep = DEFAULT_EREADER_SETTINGS.ttsPageStep
  if (!isTtsLanguage(settings.ttsLanguage)) {
    settings.ttsLanguage = ttsLanguageForBookLanguage(settings.ttsLanguage) || defaultTtsLanguage()
  }
  if (!REMOTE_POSITION_MODES.includes(settings.remotePosition)) settings.remotePosition = DEFAULT_EREADER_SETTINGS.remotePosition
  settings.ttsVoices = stored.ttsVoices && typeof stored.ttsVoices === 'object' ? { ...stored.ttsVoices } : {}
  return settings
}

/**
 * Settings with the voice of the current read aloud language replaced. Voices
 * are stored per language so the language toggle keeps its own pick.
 */
export function withTtsVoice(settings, voice) {
  return { ...settings, ttsVoices: { ...(settings.ttsVoices || {}), [settings.ttsLanguage]: voice || '' } }
}

/**
 * Settings remembered per book (on the server, `ebookSettings` of the media
 * progress) when they differ from the defaults of the book. The appearance is
 * kept per device - a font size that suits a tablet is too big for a phone -
 * while the read aloud language and the text encoding are properties of the
 * book, shared by every device.
 *
 * Stored shape: `{ ttsLanguage, legacyEncoding, devices: { [deviceId]: { theme, fontScale, ... } } }`.
 * Appearance keys at the top level were saved by older app versions or by the
 * web client - they came from any device, so they are kept but not used.
 */
export const BOOK_DEVICE_SETTING_KEYS = Object.freeze(['theme', 'font', 'fontScale', 'lineSpacing', 'textStroke', 'spread'])
export const BOOK_SHARED_SETTING_KEYS = Object.freeze(['legacyEncoding', 'ttsLanguage'])
export const BOOK_SETTING_KEYS = Object.freeze([...BOOK_DEVICE_SETTING_KEYS, ...BOOK_SHARED_SETTING_KEYS])

function isObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value)
}

function pickSettings(source, keys) {
  const picked = {}
  if (!isObject(source)) return picked
  for (const key of keys) {
    if (source[key] === undefined || source[key] === null) continue
    picked[key] = source[key]
  }
  return picked
}

/**
 * The per-book override of a device out of the stored per-book settings: the
 * shared keys and the appearance saved for the device.
 * @param {Object|null} stored - the settings as stored (see BOOK_DEVICE_SETTING_KEYS)
 * @param {string} deviceId
 * @returns {Object|null} the override, null when the device has none
 */
export function bookSettingsForDevice(stored, deviceId) {
  if (!isObject(stored)) return null
  const override = {
    ...pickSettings(stored, BOOK_SHARED_SETTING_KEYS),
    ...pickSettings(deviceId && isObject(stored.devices) ? stored.devices[deviceId] : null, BOOK_DEVICE_SETTING_KEYS)
  }
  return Object.keys(override).length ? override : null
}

/**
 * The stored per-book settings with the override of a device replaced. The
 * entries of the other devices and any top-level appearance of older clients
 * are kept. This is what an older server, which replaces the whole object,
 * is sent (see serverMergesBookSettings).
 * @param {Object|null} stored - the settings as stored
 * @param {Object|null} override - the per-book override of the device (its diff from the book defaults)
 * @param {string} deviceId
 * @returns {Object|null} the settings to store, null when nothing is left
 */
export function withDeviceBookSettings(stored, override, deviceId) {
  const result = isObject(stored) ? { ...stored } : {}
  for (const key of BOOK_SHARED_SETTING_KEYS) delete result[key]
  Object.assign(result, pickSettings(override, BOOK_SHARED_SETTING_KEYS))

  const devices = isObject(result.devices) ? { ...result.devices } : {}
  if (deviceId) {
    const deviceSettings = pickSettings(override, BOOK_DEVICE_SETTING_KEYS)
    if (Object.keys(deviceSettings).length) devices[deviceId] = deviceSettings
    else delete devices[deviceId]
  }
  if (Object.keys(devices).length) result.devices = devices
  else delete result.devices

  return Object.keys(result).length ? result : null
}

/**
 * Whether the server merges an ebookSettings update into the stored settings
 * (fork 2.36.0-dospe.4 and later): a key or a device entry is set by a value
 * and removed by null, what is left out stays. Older servers, upstream
 * included, replace the whole object.
 * @param {string} serverVersion - e.g. "2.36.0-dospe.4"
 * @returns {boolean}
 */
export function serverMergesBookSettings(serverVersion) {
  const match = /^(\d+)\.(\d+)\.(\d+)-dospe\.(\d+)/.exec(String(serverVersion || '').trim())
  if (!match) return false
  const [major, minor, patch, fork] = match.slice(1).map(Number)
  const base = major * 1000000 + minor * 1000 + patch
  const mergeBase = 2 * 1000000 + 36 * 1000 + 0
  return base > mergeBase || (base === mergeBase && fork >= 4)
}

/**
 * The update a device sends for a book to a merging server: its own entry of
 * `devices` (the complete appearance override, null when there is none) and
 * the shared keys of the book only where they differ from what is stored -
 * a device that merely uses the language another device saved does not
 * touch it. An empty shared value removes the key.
 * @param {Object|null} stored - the settings as stored (all devices)
 * @param {Object|null} override - the per-book override of the device (its diff from the book defaults)
 * @param {Object} effective - the settings in use for the book on this device
 * @param {string} deviceId
 * @returns {Object} the update to send
 */
export function deviceBookSettingsUpdate(stored, override, effective, deviceId) {
  const update = {}
  for (const key of BOOK_SHARED_SETTING_KEYS) {
    const storedValue = isObject(stored) && stored[key] !== undefined && stored[key] !== null && stored[key] !== '' ? stored[key] : null
    const value = effective?.[key] !== undefined && effective?.[key] !== null && effective?.[key] !== '' ? effective[key] : null
    if (value !== storedValue) update[key] = value
  }
  if (deviceId) {
    const deviceSettings = pickSettings(override, BOOK_DEVICE_SETTING_KEYS)
    update.devices = { [deviceId]: Object.keys(deviceSettings).length ? deviceSettings : null }
  }
  return update
}

/**
 * The stored per-book settings with an update applied the way the server
 * merges it (see deviceBookSettingsUpdate): a shared key is set by a value
 * and removed by null, an entry of `devices` replaced by an object and
 * removed by null, everything else stays.
 * @param {Object|null} stored
 * @param {Object|null} update
 * @returns {Object|null} the merged settings, null when nothing is left
 */
export function applyBookSettingsUpdate(stored, update) {
  if (update === null) return null
  const result = isObject(stored) ? { ...stored } : {}
  if (!isObject(update)) return Object.keys(result).length ? result : null
  for (const key of BOOK_SETTING_KEYS) {
    if (update[key] === undefined) continue
    if (update[key] === null) delete result[key]
    else result[key] = update[key]
  }
  const devices = isObject(result.devices) ? { ...result.devices } : {}
  if (isObject(update.devices)) {
    for (const deviceId of Object.keys(update.devices)) {
      const entry = update.devices[deviceId]
      if (entry === undefined) continue
      const deviceSettings = pickSettings(entry, BOOK_DEVICE_SETTING_KEYS)
      if (Object.keys(deviceSettings).length) devices[deviceId] = deviceSettings
      else delete devices[deviceId]
    }
  }
  if (Object.keys(devices).length) result.devices = devices
  else delete result.devices
  return Object.keys(result).length ? result : null
}
