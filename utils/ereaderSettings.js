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
  ttsPageStep: 3
})

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
 * are kept.
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
