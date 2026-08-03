import { registerPlugin, Capacitor } from '@capacitor/core'

/**
 * Native read aloud (TTS) player. The native side keeps speaking with the
 * screen off, shows a media notification and (on Android) integrates with
 * the media session / Android Auto.
 *
 * See docs/native-tts-player-design.md for the plugin contract. Besides the
 * playback methods the plugin exposes engine/voice selection: getEngines(),
 * getVoices({ engine, language }), setEngine({ engine }), setVoice({ voice })
 * and openTTSSettings() opening the Android system TTS settings screen.
 * F1 implements Android; other platforms fall back to the WebView loop
 * in mixins/ttsPlayer.js.
 */
const AbsTTSPlayer = registerPlugin('AbsTTSPlayer')

export const isNativeTTSPlayerAvailable = () => {
  return Capacitor.getPlatform() === 'android' && Capacitor.isPluginAvailable('AbsTTSPlayer')
}

export { AbsTTSPlayer }
