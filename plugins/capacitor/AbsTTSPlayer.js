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
 * Android (F1) and iOS (F3) implement it; the web falls back to the WebView
 * loop in mixins/ttsPlayer.js. iOS has a single speech engine, so
 * getEngines() returns an empty list there and setEngine() is a no-op.
 */
const AbsTTSPlayer = registerPlugin('AbsTTSPlayer')

export const isNativeTTSPlayerAvailable = () => {
  const platform = Capacitor.getPlatform()
  return (platform === 'android' || platform === 'ios') && Capacitor.isPluginAvailable('AbsTTSPlayer')
}

export { AbsTTSPlayer }
