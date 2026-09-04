package com.audiobookshelf.app.plugins

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.util.Log
import com.audiobookshelf.app.MainActivity
import com.audiobookshelf.app.data.TTSBook
import com.audiobookshelf.app.player.PlayerNotificationService
import com.audiobookshelf.app.player.TTSPlaybackEngine
import com.fasterxml.jackson.core.json.JsonReadFeature
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import org.json.JSONArray

/**
 * Capacitor bridge for the native read aloud (TTS) player.
 * JS contract: plugins/capacitor/AbsTTSPlayer.js, design in
 * docs/native-tts-player-design.md
 */
@CapacitorPlugin(name = "AbsTTSPlayer")
class AbsTTSPlayer : Plugin() {
  private val tag = "AbsTTSPlayer"
  private var jacksonMapper = jacksonObjectMapper().enable(JsonReadFeature.ALLOW_UNESCAPED_CONTROL_CHARS.mappedFeature())

  private lateinit var mainActivity: MainActivity
  lateinit var playerNotificationService: PlayerNotificationService

  private val mainHandler = Handler(Looper.getMainLooper())

  override fun load() {
    mainActivity = (activity as MainActivity)

    val foregroundServiceReady: () -> Unit = {
      playerNotificationService = mainActivity.foregroundService

      playerNotificationService.ttsClientEventEmitter = (object : PlayerNotificationService.TTSClientEventEmitter {
        override fun onTTSStateChange(state: String) {
          val ret = JSObject()
          ret.put("state", state)
          notifyListeners("onStateChange", ret)
        }

        override fun onTTSParagraph(chapterIndex: Int, paragraphIndex: Int, location: String?, progress: Double) {
          val ret = JSObject()
          ret.put("chapterIndex", chapterIndex)
          ret.put("paragraphIndex", paragraphIndex)
          ret.put("location", location)
          ret.put("progress", progress)
          notifyListeners("onParagraph", ret)
        }

        override fun onTTSError(message: String) {
          val ret = JSObject()
          ret.put("error", message)
          notifyListeners("onError", ret)
        }
      })
    }
    mainActivity.pluginCallbacks.add(foregroundServiceReady)
  }

  private fun isServiceReady(): Boolean {
    return this::playerNotificationService.isInitialized
  }

  @PluginMethod
  fun prepareBook(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val book: TTSBook
    try {
      book = jacksonMapper.readValue(call.data.toString(), TTSBook::class.java)
    } catch (e: Exception) {
      Log.e(tag, "prepareBook failed to parse book", e)
      return call.reject("Invalid book payload")
    }
    if (book.libraryItemId.isEmpty() || book.chapters.isEmpty()) {
      return call.reject("Book has no id or no chapters")
    }
    mainHandler.post {
      playerNotificationService.prepareTTSBook(book)
      call.resolve()
    }
  }

  @PluginMethod
  fun play(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val libraryItemId = call.getString("libraryItemId")
    val chapterIndex = if (call.data.has("chapterIndex")) call.getInt("chapterIndex") else null
    val paragraphIndex = if (call.data.has("paragraphIndex")) call.getInt("paragraphIndex") else null
    mainHandler.post {
      playerNotificationService.playTTS(libraryItemId, chapterIndex, paragraphIndex)
      call.resolve()
    }
  }

  @PluginMethod
  fun pause(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    mainHandler.post {
      playerNotificationService.ttsEngine?.pause()
      call.resolve()
    }
  }

  @PluginMethod
  fun stop(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    mainHandler.post {
      playerNotificationService.ttsEngine?.stop()
      call.resolve()
    }
  }

  @PluginMethod
  fun seekTo(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val chapterIndex = call.getInt("chapterIndex") ?: 0
    val paragraphIndex = call.getInt("paragraphIndex") ?: 0
    mainHandler.post {
      playerNotificationService.ttsEngine?.seekTo(chapterIndex, paragraphIndex)
      call.resolve()
    }
  }

  @PluginMethod
  fun nextChapter(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    mainHandler.post {
      playerNotificationService.ttsEngine?.seekChapter(1)
      call.resolve()
    }
  }

  @PluginMethod
  fun prevChapter(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    mainHandler.post {
      playerNotificationService.ttsEngine?.seekChapter(-1)
      call.resolve()
    }
  }

  /** Skip by the configured number of pages: delta -1 = back, 1 = forward */
  @PluginMethod
  fun seekPages(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val delta = call.getInt("delta") ?: 1
    mainHandler.post {
      playerNotificationService.ttsEngine?.seekPages(delta)
      call.resolve()
    }
  }

  /** Pages per skip and the reader's characters-per-page estimate (0 = keep default) */
  @PluginMethod
  fun setPageStep(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val pageStep = call.getInt("pageStep") ?: 0
    val pageChars = call.getInt("pageChars") ?: 0
    mainHandler.post {
      playerNotificationService.ttsEngine?.setPageStep(pageStep, pageChars)
      call.resolve()
    }
  }

  @PluginMethod
  fun setRate(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val rate = call.getFloat("rate") ?: 1f
    mainHandler.post {
      playerNotificationService.ttsEngine?.setPlaybackRate(rate)
      call.resolve()
    }
  }

  @PluginMethod
  fun setLanguage(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val lang = call.getString("lang") ?: return call.reject("Missing lang")
    mainHandler.post {
      playerNotificationService.ttsEngine?.setLanguage(lang)
      call.resolve()
    }
  }

  @PluginMethod
  fun setEngine(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val engine = call.getString("engine") ?: ""
    mainHandler.post {
      playerNotificationService.ttsEngine?.setEngine(engine)
      call.resolve()
    }
  }

  @PluginMethod
  fun setVoice(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val voice = call.getString("voice") ?: ""
    mainHandler.post {
      playerNotificationService.ttsEngine?.setVoice(voice)
      call.resolve()
    }
  }

  @PluginMethod
  fun openTTSSettings(call: PluginCall) {
    try {
      val intent = Intent("com.android.settings.TTS_SETTINGS")
      intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
      activity.startActivity(intent)
      call.resolve()
    } catch (e: Exception) {
      Log.e(tag, "Failed to open system TTS settings", e)
      call.reject("Could not open TTS settings")
    }
  }

  /**
   * Run the block with a temporary TextToSpeech instance for enumeration -
   * independent of the playback engine so it works with no book prepared and
   * can enumerate an engine other than the active one. Voices are only valid
   * after the async init, so results resolve from the init listener.
   */
  private fun withEnumerationTTS(enginePackage: String?, block: (TextToSpeech?, Boolean) -> Unit) {
    mainHandler.post {
      var enumTts: TextToSpeech? = null
      val initListener = TextToSpeech.OnInitListener { status ->
        mainHandler.post {
          block(enumTts, status == TextToSpeech.SUCCESS)
          enumTts?.shutdown()
        }
      }
      enumTts = if (enginePackage.isNullOrEmpty()) TextToSpeech(context, initListener)
                else TextToSpeech(context, initListener, enginePackage)
    }
  }

  @PluginMethod
  fun getEngines(call: PluginCall) {
    // The engines list is a package query and works even when init fails
    withEnumerationTTS(null) { tts, _ ->
      val engines = JSONArray()
      tts?.engines?.forEach { engine ->
        val engineObj = JSObject()
        engineObj.put("name", engine.name)
        engineObj.put("label", engine.label)
        engines.put(engineObj)
      }
      val ret = JSObject()
      ret.put("engines", engines)
      call.resolve(ret)
    }
  }

  @PluginMethod
  fun getVoices(call: PluginCall) {
    val enginePackage = call.getString("engine")
    val language = call.getString("language")
    withEnumerationTTS(enginePackage) { tts, ready ->
      if (!ready) return@withEnumerationTTS call.reject("TTS engine failed to initialize")
      val voices = JSONArray()
      // Match on the ISO language part only ("cs") so all regional variants are listed
      val langPrefix = language?.substringBefore('-')?.lowercase()
      val engineVoices = try { tts?.voices } catch (e: Exception) { null }
      engineVoices?.forEach { voice ->
        if (langPrefix != null && voice.locale.language.lowercase() != langPrefix) return@forEach
        val voiceObj = JSObject()
        voiceObj.put("name", voice.name)
        voiceObj.put("lang", voice.locale.toLanguageTag())
        voiceObj.put("quality", voice.quality)
        voiceObj.put("networkRequired", voice.isNetworkConnectionRequired)
        voices.put(voiceObj)
      }
      val ret = JSObject()
      ret.put("voices", voices)
      call.resolve(ret)
    }
  }

  @PluginMethod
  fun getState(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    mainHandler.post {
      val engine = playerNotificationService.ttsEngine
      val ret = JSObject()
      ret.put("state", engine?.state?.value ?: TTSPlaybackEngine.TTSState.STOPPED.value)
      ret.put("libraryItemId", engine?.book?.libraryItemId)
      ret.put("chapterIndex", engine?.chapterIndex ?: 0)
      ret.put("paragraphIndex", engine?.paragraphIndex ?: 0)
      ret.put("location", engine?.currentLocation)
      ret.put("progress", engine?.progress ?: 0.0)
      ret.put("rate", engine?.rate ?: 1f)
      ret.put("language", engine?.language ?: "en-US")
      ret.put("engine", engine?.enginePackage ?: "")
      ret.put("voice", engine?.voiceName ?: "")
      call.resolve(ret)
    }
  }

  @PluginMethod
  fun listCachedBooks(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    mainHandler.post {
      val ret = JSObject()
      ret.put("books", JSONArray(jacksonMapper.writeValueAsString(playerNotificationService.ttsBookCache.list())))
      call.resolve(ret)
    }
  }

  @PluginMethod
  fun removeCachedBook(call: PluginCall) {
    if (!isServiceReady()) return call.reject("Player service not ready")
    val libraryItemId = call.getString("libraryItemId") ?: return call.reject("Missing libraryItemId")
    mainHandler.post {
      playerNotificationService.ttsBookCache.remove(libraryItemId)
      playerNotificationService.notifyEbooksChanged()
      call.resolve()
    }
  }
}
