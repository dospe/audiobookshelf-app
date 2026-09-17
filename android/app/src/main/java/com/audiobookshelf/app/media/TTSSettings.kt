package com.audiobookshelf.app.media

import android.content.Context
import android.util.Log
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper

/**
 * Read aloud languages offered by the reader (cs-CZ, en-US) and the mapping of
 * a language a book or a setting names onto them - the native counterpart of
 * ttsLanguageForBookLanguage in utils/ereaderSettings.js, so a book started
 * from Android Auto resolves its language the way the reader does.
 */
object TTSLanguage {
  const val DEFAULT = "en-US"

  private class Offered(val tag: String, val codes: Set<String>, val names: Set<String>)

  private val OFFERED = listOf(
    Offered("cs-CZ", setOf("cs", "ces", "cze"), setOf("czech", "čeština", "cestina", "česky", "cesky")),
    Offered("en-US", setOf("en", "eng"), setOf("english", "angličtina", "anglictina"))
  )

  /**
   * The offered read aloud language for an ISO code ("cs", "ces"), a tag
   * ("en-GB", "cs_CZ") or a language name ("Czech", "čeština"). Null when
   * unknown or not offered. Some books list several languages ("cs; en") -
   * the first one is the book's.
   */
  fun forBookLanguage(raw: String?): String? {
    val value = raw?.trim()?.lowercase()?.split(';', ',')?.firstOrNull()?.trim()
    if (value.isNullOrEmpty()) return null
    val primary = value.split('-', '_')[0]
    return OFFERED.find { it.tag.lowercase() == value || primary in it.codes || value in it.names }?.tag
  }
}

/**
 * The global ereader and read aloud defaults the app saves with the
 * Preferences plugin (store/ereader.js, key `ereaderSettings` in the
 * CapacitorStorage shared preferences). Read natively so a book started
 * without the WebView - picked in Android Auto - speaks with the same
 * language, speed, engine and voice as the reader would.
 *
 * Every value is null when it is not stored (or unusable), so callers keep
 * what the engine has instead.
 */
data class TTSSettings(
  val ttsLanguage: String?,
  val ttsRate: Float?,
  // "" = the system default engine, like the ttsEngine setting of the reader
  val ttsEngine: String?,
  // Voice per read aloud language ({ 'cs-CZ': voiceName })
  val ttsVoices: Map<String, String>,
  val ttsPageStep: Int?
) {
  /** Voice saved for a language, empty when none - the engine default of the language */
  fun voiceFor(language: String): String = ttsVoices[language] ?: ""

  companion object {
    private const val TAG = "TTSSettings"
    private const val PREFERENCES_NAME = "CapacitorStorage"
    private const val PREFERENCES_KEY = "ereaderSettings"
    const val MIN_RATE = 0.5f
    const val MAX_RATE = 2.5f

    val EMPTY = TTSSettings(null, null, null, emptyMap(), null)

    fun load(context: Context): TTSSettings {
      val json = try {
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE).getString(PREFERENCES_KEY, null)
      } catch (e: Exception) {
        Log.e(TAG, "Failed to read the ereader settings", e)
        null
      }
      val settings = parse(json)
      if (settings == EMPTY && !json.isNullOrBlank()) Log.w(TAG, "Stored ereader settings are not usable")
      return settings
    }

    /** The settings out of the stored JSON; damaged or missing values are null (no logging - unit tested) */
    fun parse(json: String?): TTSSettings {
      if (json.isNullOrBlank()) return EMPTY
      val node = try {
        jacksonObjectMapper().readTree(json)
      } catch (e: Exception) {
        return EMPTY
      }
      if (node == null || !node.isObject) return EMPTY

      val language = TTSLanguage.forBookLanguage(node.get("ttsLanguage")?.takeIf { it.isTextual }?.asText())
      val rate = node.get("ttsRate")?.takeIf { it.isNumber || it.isTextual }?.asText()?.toFloatOrNull()
        ?.takeIf { it in MIN_RATE..MAX_RATE }
      val engine = node.get("ttsEngine")?.takeIf { it.isTextual }?.asText()
      val pageStep = node.get("ttsPageStep")?.takeIf { it.isNumber || it.isTextual }?.asText()?.toIntOrNull()
        ?.takeIf { it > 0 }
      val voices = mutableMapOf<String, String>()
      node.get("ttsVoices")?.takeIf { it.isObject }?.fields()?.forEach { (voiceLanguage, voice: JsonNode) ->
        if (voice.isTextual && voice.asText().isNotEmpty()) voices[voiceLanguage] = voice.asText()
      }
      return TTSSettings(language, rate, engine, voices, pageStep)
    }
  }
}
