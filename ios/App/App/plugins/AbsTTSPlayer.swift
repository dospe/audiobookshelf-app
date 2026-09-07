//
//  AbsTTSPlayer.swift
//  Audiobookshelf
//
//  Capacitor bridge for the native read aloud (TTS) player - the same
//  contract as the Android plugin (plugins/AbsTTSPlayer.kt).
//  JS side: plugins/capacitor/AbsTTSPlayer.js, design in
//  docs/native-tts-player-design.md
//

import Foundation
import Capacitor
import AVFoundation
import UIKit

@objc(AbsTTSPlayer)
public class AbsTTSPlayer: CAPPlugin, CAPBridgedPlugin, TTSPlayerListener {
    public var identifier = "AbsTTSPlayerPlugin"
    public var jsName = "AbsTTSPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "prepareBook", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seekTo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "nextChapter", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "prevChapter", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seekPages", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPageStep", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLanguage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setEngine", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVoice", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openTTSSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getEngines", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getVoices", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listCachedBooks", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeCachedBook", returnType: CAPPluginReturnPromise)
    ]

    private var player: TTSPlayer {
        return TTSPlayer.shared
    }

    override public func load() {
        DispatchQueue.main.async {
            TTSPlayer.shared.listener = self
        }
    }

    // MARK: - Engine events -> JS

    func onTTSStateChange(_ state: TTSState) {
        notifyListeners("onStateChange", data: ["state": state.rawValue])
    }

    func onTTSParagraph(chapterIndex: Int, paragraphIndex: Int, location: String?, progress: Double) {
        notifyListeners("onParagraph", data: [
            "chapterIndex": chapterIndex,
            "paragraphIndex": paragraphIndex,
            "location": jsValue(location),
            "progress": progress
        ])
    }

    func onTTSError(_ message: String) {
        notifyListeners("onError", data: ["error": message])
    }

    /// Optional strings cross the bridge as null, not as a missing key
    private func jsValue(_ value: String?) -> Any {
        if let value = value {
            return value
        }
        return NSNull()
    }

    // MARK: - Playback

    @objc func prepareBook(_ call: CAPPluginCall) {
        let book: TTSBook
        do {
            let options: Any? = call.options
            guard let payload = options, JSONSerialization.isValidJSONObject(payload) else {
                return call.reject("Invalid book payload")
            }
            book = try JSONDecoder().decode(TTSBook.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            AbsLogger.error(message: "prepareBook failed to parse book: \(error)")
            return call.reject("Invalid book payload")
        }
        guard !book.libraryItemId.isEmpty, !book.chapters.isEmpty else {
            return call.reject("Book has no id or no chapters")
        }
        DispatchQueue.main.async {
            self.player.prepare(book)
            call.resolve()
        }
        // The extracted text of a whole book is MB-sized json - write it off the main thread
        DispatchQueue.global(qos: .utility).async {
            self.player.cache.save(book)
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        let libraryItemId = call.getString("libraryItemId")
        let chapterIndex = call.getInt("chapterIndex")
        let paragraphIndex = call.getInt("paragraphIndex")
        DispatchQueue.main.async {
            self.player.play(libraryItemId: libraryItemId, chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player.pause()
            call.resolve()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player.stop()
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        let chapterIndex = call.getInt("chapterIndex") ?? 0
        let paragraphIndex = call.getInt("paragraphIndex") ?? 0
        DispatchQueue.main.async {
            self.player.seekTo(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)
            call.resolve()
        }
    }

    @objc func nextChapter(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player.seekChapter(1)
            call.resolve()
        }
    }

    @objc func prevChapter(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player.seekChapter(-1)
            call.resolve()
        }
    }

    /// Skip by the configured number of pages: delta -1 = back, 1 = forward
    @objc func seekPages(_ call: CAPPluginCall) {
        let delta = call.getInt("delta") ?? 1
        DispatchQueue.main.async {
            self.player.seekPages(delta)
            call.resolve()
        }
    }

    /// Pages per skip and the reader's characters-per-page estimate (0 = keep default)
    @objc func setPageStep(_ call: CAPPluginCall) {
        let pageStep = call.getInt("pageStep") ?? 0
        let pageChars = call.getInt("pageChars") ?? 0
        DispatchQueue.main.async {
            self.player.setPageStep(pageStep, pageChars: pageChars)
            call.resolve()
        }
    }

    @objc func setRate(_ call: CAPPluginCall) {
        let rate = call.getFloat("rate") ?? 1
        DispatchQueue.main.async {
            self.player.setRate(rate)
            call.resolve()
        }
    }

    @objc func setLanguage(_ call: CAPPluginCall) {
        guard let lang = call.getString("lang") else {
            return call.reject("Missing lang")
        }
        DispatchQueue.main.async {
            self.player.setLanguage(lang)
            call.resolve()
        }
    }

    /// iOS has a single speech engine - engine selection is an Android feature
    @objc func setEngine(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func setVoice(_ call: CAPPluginCall) {
        let voice = call.getString("voice") ?? ""
        DispatchQueue.main.async {
            self.player.setVoice(voice)
            call.resolve()
        }
    }

    // MARK: - Engines and voices

    /// Voices are managed in the Settings app (Accessibility > Spoken Content > Voices)
    @objc func openTTSSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) else {
                return call.reject("Could not open the Settings app")
            }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            call.resolve()
        }
    }

    /// No engine choice on iOS - an empty list hides the engine picker in the reader settings
    @objc func getEngines(_ call: CAPPluginCall) {
        call.resolve(["engines": [[String: Any]]()])
    }

    @objc func getVoices(_ call: CAPPluginCall) {
        let language = call.getString("language") ?? ""
        // Match on the ISO language part only ("cs") so all regional variants are listed
        let langPrefix = language.split(separator: "-").first.map { String($0).lowercased() } ?? ""
        let voices: [[String: Any]] = AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            let voiceLanguage = voice.language.replacingOccurrences(of: "_", with: "-")
            let voicePrefix = voiceLanguage.split(separator: "-").first.map { String($0).lowercased() } ?? ""
            if !langPrefix.isEmpty && voicePrefix != langPrefix {
                return nil
            }
            return [
                // The identifier is the stable key (names repeat across qualities); the label is shown
                "name": voice.identifier,
                "label": self.voiceLabel(voice),
                "lang": voiceLanguage,
                "quality": voice.quality.rawValue,
                "networkRequired": false
            ]
        }
        call.resolve(["voices": voices])
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        if #available(iOS 16.0, *), voice.quality == .premium {
            return "\(voice.name) (Premium)"
        }
        if voice.quality == .enhanced {
            return "\(voice.name) (Enhanced)"
        }
        return voice.name
    }

    // MARK: - State and cache

    @objc func getState(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let player = self.player
            call.resolve([
                "state": player.state.rawValue,
                "libraryItemId": self.jsValue(player.book?.libraryItemId),
                "chapterIndex": player.chapterIndex,
                "paragraphIndex": player.paragraphIndex,
                "location": self.jsValue(player.currentLocation),
                "progress": player.progress,
                "rate": player.rate,
                "language": player.language,
                "engine": "",
                "voice": player.voiceIdentifier
            ])
        }
    }

    @objc func listCachedBooks(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            let books = (try? self.player.cache.list().asDictionaryArray()) ?? []
            call.resolve(["books": books])
        }
    }

    @objc func removeCachedBook(_ call: CAPPluginCall) {
        guard let libraryItemId = call.getString("libraryItemId") else {
            return call.reject("Missing libraryItemId")
        }
        DispatchQueue.global(qos: .utility).async {
            self.player.cache.remove(libraryItemId)
            call.resolve()
        }
    }
}
