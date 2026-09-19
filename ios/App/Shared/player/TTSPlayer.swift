//
//  TTSPlayer.swift
//  Audiobookshelf
//
//  Native read aloud (TTS) player speaking a TTSBook with the system voices
//  (AVSpeechSynthesizer). The counterpart of the Android TTSPlaybackEngine
//  plus the TTS part of PlayerNotificationService: paragraphs are spoken in
//  sentence-sized chunks guarded by the current utterance, the playback
//  audio session keeps speaking with the screen off, and the Now Playing
//  info / remote commands give lock screen, Control Center, headset and
//  CarPlay "Now Playing" controls. Every call runs on the main thread.
//  See docs/native-tts-player-design.md (3.4)
//

import Foundation
import AVFoundation
import MediaPlayer
import UIKit

enum TTSState: String {
    case stopped
    case playing
    case paused
}

protocol TTSPlayerListener: AnyObject {
    func onTTSStateChange(_ state: TTSState)
    func onTTSParagraph(chapterIndex: Int, paragraphIndex: Int, location: String?, progress: Double)
    func onTTSError(_ message: String)
}

class TTSPlayer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSPlayer()
    static let maxChunkLength = 300
    static let charsPerSecond = 15.0 // rough speaking speed at 1x for time estimates
    // A session paused for this long is checked against the server before it goes on (see resumeSession)
    static let remoteCheckAfterPause: TimeInterval = 2 * 60

    weak var listener: TTSPlayerListener?
    let cache = TTSBookCache()
    private lazy var progressSyncer = TTSProgressSyncer(player: self)
    private let synthesizer = AVSpeechSynthesizer()

    private(set) var book: TTSBook?
    private(set) var chapterIndex = 0
    private(set) var paragraphIndex = 0
    private(set) var state: TTSState = .stopped
    private(set) var rate: Float = 1
    private(set) var language = "en-US"
    private(set) var voiceIdentifier = "" // "" = default voice for the language
    // Page skips (remote previous/next): pages per skip and characters per displayed page
    private(set) var pageStep = TTSBook.defaultPageStep
    private(set) var pageChars = TTSBook.defaultPageChars
    // Position stays on the last paragraph when the book ends; this makes progress report 100%
    private(set) var endOfBookReached = false
    // When the session was paused (seconds since 1970) and whether the position
    // was moved since: a resume after a long pause asks the server for a position
    // written elsewhere meanwhile, unless the user placed the session themselves
    private(set) var pausedAt: TimeInterval = 0
    private(set) var positionChangedSincePause = false

    private var chunks: [String] = []
    private var chunkIndex = 0
    // The utterance being spoken - callbacks of any other (interrupted) utterance are ignored
    private var currentUtterance: AVSpeechUtterance?
    private var languageWarned = false
    private var resumeAfterInterruption = false
    private var hasNowPlaying = false
    private var remoteCommandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkItemId: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(notification:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(notification:)), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
    }

    // MARK: - Position and progress

    var isSessionActive: Bool {
        return state != .stopped
    }

    var currentLocation: String? {
        return book?.paragraph(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)?.location
    }

    var progress: Double {
        guard let currentBook = book else { return 0 }
        if endOfBookReached { return 1 }
        if currentBook.totalChars <= 0 { return 0 }
        return Double(currentBook.charsBefore(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)) / Double(currentBook.totalChars)
    }

    /// Estimated total duration in seconds from character count and speaking rate, for the Now Playing info
    var estimatedDuration: Double {
        guard let currentBook = book else { return 0 }
        return Double(currentBook.totalChars) / (TTSPlayer.charsPerSecond * Double(rate))
    }

    /// Estimated position in seconds of the current paragraph start
    var estimatedPosition: Double {
        guard let currentBook = book else { return 0 }
        return Double(currentBook.charsBefore(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)) / (TTSPlayer.charsPerSecond * Double(rate))
    }

    /// Seek from an estimated time position (lock screen scrubber) to the nearest paragraph
    func seekToPosition(seconds: Double) {
        guard let currentBook = book else { return }
        let targetChars = Int(seconds * TTSPlayer.charsPerSecond * Double(rate))
        var chars = 0
        for (ci, chapter) in currentBook.chapters.enumerated() {
            for (pi, paragraph) in chapter.paragraphs.enumerated() {
                chars += paragraph.chars
                if chars > targetChars {
                    seekTo(chapterIndex: ci, paragraphIndex: pi)
                    return
                }
            }
        }
        let last = currentBook.lastPosition
        seekTo(chapterIndex: last.chapterIndex, paragraphIndex: last.paragraphIndex)
    }

    // MARK: - Session

    func prepare(_ newBook: TTSBook) {
        // Preparing a different book while a session is active ends that session
        // first, while `book` still points at the old one: the stopped transition
        // syncs the old book's final progress and releases the Now Playing info,
        // and the play() that follows raises playing again so the client sees
        // the book switch
        if state != .stopped && book?.libraryItemId != newBook.libraryItemId {
            stop()
        }
        interrupt()
        book = newBook
        language = newBook.language
        rate = newBook.rate
        // nil = keep the current voice
        if let voice = newBook.voice {
            voiceIdentifier = voice
        }
        setPageStep(newBook.pageStep, pageChars: newBook.pageChars)
        chapterIndex = 0
        paragraphIndex = 0
        chunks = []
        chunkIndex = 0
        endOfBookReached = false
        languageWarned = false
    }

    /**
     * Plugin play(): no book id resumes the running session (reader play/pause);
     * another book is loaded from the cache and resumed from the saved reading
     * position unless the caller (the reader) passes an explicit position.
     */
    func play(libraryItemId: String?, chapterIndex startChapterIndex: Int?, paragraphIndex startParagraphIndex: Int?, skipRemoteCheck: Bool = false) {
        guard let libraryItemId = libraryItemId, !libraryItemId.isEmpty else {
            if startChapterIndex == nil {
                resumeSession(skipRemoteCheck: skipRemoteCheck)
            } else {
                play(startChapterIndex: startChapterIndex, startParagraphIndex: startParagraphIndex)
            }
            return
        }
        if book?.libraryItemId != libraryItemId {
            guard let cached = cache.load(libraryItemId) else {
                listener?.onTTSError("Book not found in cache")
                return
            }
            prepare(cached)
        }
        if startChapterIndex != nil {
            play(startChapterIndex: startChapterIndex, startParagraphIndex: startParagraphIndex)
            return
        }
        guard let currentBook = book else { return }
        resolveSavedProgress(for: currentBook) { [weak self] saved in
            guard let self = self, self.book?.libraryItemId == currentBook.libraryItemId else { return }
            if let position = self.savedPosition(in: currentBook, saved: saved) {
                self.seekTo(chapterIndex: position.chapterIndex, paragraphIndex: position.paragraphIndex)
            }
            self.play(startChapterIndex: nil, startParagraphIndex: nil)
        }
    }

    /**
     * Resume the session (lock screen, headset, the reader's play button).
     * After a longer pause the book may have been read further elsewhere - the
     * tablet, the phone reader - so the saved position is fetched first and,
     * when it was written after the pause and points elsewhere, the session
     * continues from it. Skipped when the reader has placed the session itself
     * (it follows the server on its own) or the position was moved while
     * paused. A short pause resumes at once.
     */
    func resumeSession(skipRemoteCheck: Bool = false) {
        guard let currentBook = book, state == .paused, !skipRemoteCheck, !positionChangedSincePause,
              Date().timeIntervalSince1970 - pausedAt >= TTSPlayer.remoteCheckAfterPause else {
            play(startChapterIndex: nil, startParagraphIndex: nil)
            return
        }
        // The pause synced the position with the pause time (ms), so anything newer was written elsewhere
        let pausedAtMs = pausedAt * 1000
        resolveSavedProgress(for: currentBook) { [weak self] saved in
            guard let self = self, self.book?.libraryItemId == currentBook.libraryItemId else { return }
            if self.state == .paused, !self.positionChangedSincePause,
               let saved = saved, saved.lastUpdate > pausedAtMs + 5000,
               let position = self.savedPosition(in: currentBook, saved: saved),
               position.chapterIndex != self.chapterIndex || position.paragraphIndex != self.paragraphIndex {
                AbsLogger.info(message: "TTSPlayer: \"\(currentBook.title)\" was read further elsewhere since the pause - continuing from \(saved.location ?? "progress \(saved.progress)")")
                self.seekTo(chapterIndex: position.chapterIndex, paragraphIndex: position.paragraphIndex)
            }
            self.play(startChapterIndex: nil, startParagraphIndex: nil)
        }
    }

    func play(startChapterIndex: Int? = nil, startParagraphIndex: Int? = nil) {
        guard let currentBook = book, !currentBook.chapters.isEmpty else {
            listener?.onTTSError("No book prepared")
            return
        }
        if let startChapterIndex = startChapterIndex {
            chapterIndex = clamp(startChapterIndex, 0, currentBook.chapters.count - 1)
            paragraphIndex = clamp(startParagraphIndex ?? 0, 0, max(0, currentBook.chapters[chapterIndex].paragraphs.count - 1))
            chunks = []
            chunkIndex = 0
            endOfBookReached = false
        }

        // TTS and audiobook playback share the audio output - pause any playing audio
        PlayerHandler.paused = true

        guard activateAudioSession() else {
            listener?.onTTSError("Audio session unavailable")
            return
        }

        interrupt()
        setState(.playing)
        if chunks.isEmpty {
            loadCurrentParagraph()
        }
        speakCurrentChunk()
    }

    func pause() {
        guard state == .playing else { return }
        pausedAt = Date().timeIntervalSince1970
        positionChangedSincePause = false
        interrupt()
        setState(.paused)
    }

    func stop() {
        guard state != .stopped else { return }
        interrupt()
        setState(.stopped)
    }

    func seekTo(chapterIndex newChapterIndex: Int, paragraphIndex newParagraphIndex: Int) {
        guard let currentBook = book, !currentBook.chapters.isEmpty else { return }
        chapterIndex = clamp(newChapterIndex, 0, currentBook.chapters.count - 1)
        paragraphIndex = clamp(newParagraphIndex, 0, max(0, currentBook.chapters[chapterIndex].paragraphs.count - 1))
        chunks = []
        chunkIndex = 0
        endOfBookReached = false
        if state == .paused {
            positionChangedSincePause = true
        }
        if state == .playing {
            interrupt()
            loadCurrentParagraph()
            speakCurrentChunk()
        } else {
            updateNowPlaying()
        }
    }

    func seekParagraph(_ delta: Int) {
        guard let currentBook = book, !currentBook.chapters.isEmpty else { return }
        var ci = chapterIndex
        var pi = paragraphIndex + delta
        while pi < 0 && ci > 0 {
            ci -= 1
            pi += currentBook.chapters[ci].paragraphs.count
        }
        while ci < currentBook.chapters.count && pi >= currentBook.chapters[ci].paragraphs.count {
            pi -= currentBook.chapters[ci].paragraphs.count
            ci += 1
        }
        if ci >= currentBook.chapters.count { return } // past the end, ignore
        seekTo(chapterIndex: ci, paragraphIndex: max(0, pi))
    }

    func seekChapter(_ delta: Int) {
        seekTo(chapterIndex: chapterIndex + delta, paragraphIndex: 0)
    }

    /// Pages per remote skip and the reader's characters-per-page estimate; values <= 0 keep the defaults
    func setPageStep(_ newPageStep: Int, pageChars newPageChars: Int) {
        pageStep = newPageStep > 0 ? newPageStep : TTSBook.defaultPageStep
        pageChars = newPageChars > 0 ? newPageChars : TTSBook.defaultPageChars
    }

    /**
     * Skip `delta` steps of pageStep pages (remote previous/next). A pdf
     * chapter is one page, so pdfs skip by chapters; other formats move by
     * pageChars characters per page to the paragraph at the target, always
     * at least one paragraph in the requested direction. The reader, when
     * open, follows through the paragraph event.
     */
    func seekPages(_ delta: Int) {
        guard let currentBook = book, delta != 0 else { return }
        let steps = delta * pageStep

        if currentBook.ebookFormat == "pdf" {
            let target = clamp(chapterIndex + steps, 0, currentBook.chapters.count - 1)
            if target == chapterIndex && delta > 0 { return } // already on the last page
            seekTo(chapterIndex: target, paragraphIndex: 0)
            return
        }

        let currentChars = currentBook.charsBefore(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)
        let targetChars = currentChars + steps * pageChars
        if targetChars <= 0 {
            seekTo(chapterIndex: 0, paragraphIndex: 0)
            return
        }
        if targetChars >= currentBook.totalChars {
            if delta > 0 { seekParagraph(1) } // near the end: just move on, past the end is ignored
            return
        }
        let position = currentBook.position(forProgress: Double(targetChars) / Double(currentBook.totalChars))
        if position.chapterIndex == chapterIndex && position.paragraphIndex == paragraphIndex {
            // Target landed in the current (long) paragraph - still move one paragraph
            seekParagraph(delta > 0 ? 1 : -1)
            return
        }
        seekTo(chapterIndex: position.chapterIndex, paragraphIndex: position.paragraphIndex)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        updateNowPlaying()
        restartCurrentChunkIfPlaying()
    }

    func setLanguage(_ newLanguage: String) {
        language = newLanguage
        languageWarned = false
        restartCurrentChunkIfPlaying()
    }

    func setVoice(_ newVoiceIdentifier: String) {
        guard newVoiceIdentifier != voiceIdentifier else { return }
        voiceIdentifier = newVoiceIdentifier
        restartCurrentChunkIfPlaying()
    }

    // MARK: - Saved reading position

    private typealias SavedProgress = (location: String?, progress: Double, lastUpdate: Double)

    /**
     * The saved reading position of the book, wherever it was last written:
     * the local db of a downloaded copy and the server (for a downloaded copy
     * the server item it is linked to on the current server, so a book read
     * further on another device is picked up here too) - the most recently
     * updated one wins. Nil when the book was never opened. Realm objects
     * stay on this thread.
     */
    private func resolveSavedProgress(for currentBook: TTSBook, completion: @escaping (SavedProgress?) -> Void) {
        var candidates: [SavedProgress] = []
        var serverLibraryItemId: String?
        if currentBook.libraryItemId.hasPrefix("local") {
            if let saved = Database.shared.getLocalMediaProgress(localMediaProgressId: currentBook.libraryItemId) {
                candidates.append((saved.ebookLocation, saved.ebookProgress ?? 0, saved.lastUpdate))
                if let linkedId = saved.libraryItemId, !linkedId.isEmpty, let serverConfig = Store.serverConfig, saved.serverConnectionConfigId == serverConfig.id {
                    serverLibraryItemId = linkedId
                }
            }
        } else {
            if let localEntry = Database.shared.getAllLocalMediaProgress().first(where: { $0.libraryItemId == currentBook.libraryItemId && ($0.episodeId ?? "").isEmpty }) {
                candidates.append((localEntry.ebookLocation, localEntry.ebookProgress ?? 0, localEntry.lastUpdate))
            }
            if Store.serverConfig != nil {
                serverLibraryItemId = currentBook.libraryItemId
            }
        }
        guard let serverItemId = serverLibraryItemId else {
            completion(TTSPlayer.newestSavedProgress(candidates))
            return
        }
        Task {
            let serverProgress = await ApiClient.getMediaProgress(libraryItemId: serverItemId, episodeId: nil)
            var all = candidates
            if let serverProgress = serverProgress {
                all.append((serverProgress.ebookLocation, serverProgress.ebookProgress ?? 0, serverProgress.lastUpdate))
            }
            DispatchQueue.main.async {
                completion(TTSPlayer.newestSavedProgress(all))
            }
        }
    }

    /// Entries without any ebook position are audio-only progress for the same item
    private static func newestSavedProgress(_ candidates: [SavedProgress]) -> SavedProgress? {
        return candidates.filter { $0.progress > 0 || !($0.location ?? "").isEmpty }.max { $0.lastUpdate < $1.lastUpdate }
    }

    /// Start position for a saved progress, nil to start from the beginning
    private func savedPosition(in currentBook: TTSBook, saved: SavedProgress?) -> (chapterIndex: Int, paragraphIndex: Int)? {
        guard let saved = saved else { return nil }
        if saved.progress >= 1 { return nil } // finished - start over
        if let position = currentBook.position(forLocation: saved.location) { return position }
        return saved.progress > 0 ? currentBook.position(forProgress: saved.progress) : nil
    }

    // MARK: - Speaking

    private func setState(_ newState: TTSState) {
        guard state != newState else { return }
        state = newState
        switch newState {
        case .playing:
            progressSyncer.start()
            takeNowPlaying()
            updateNowPlaying()
        case .paused:
            progressSyncer.stop()
            updateNowPlaying()
            deactivateAudioSession()
        case .stopped:
            // End of book changes progress to 100% without a paragraph event
            if endOfBookReached { progressSyncer.paragraphReached() }
            progressSyncer.stop()
            releaseNowPlaying()
            deactivateAudioSession()
        }
        listener?.onTTSStateChange(newState)
    }

    /// Stop speaking without changing state; invalidates in-flight utterance callbacks
    private func interrupt() {
        currentUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func restartCurrentChunkIfPlaying() {
        guard state == .playing else { return }
        interrupt()
        speakCurrentChunk()
    }

    private func loadCurrentParagraph() {
        let paragraph = book?.paragraph(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex)
        chunks = paragraph.map { TTSPlayer.splitTextChunks($0.text) } ?? []
        chunkIndex = 0
        if let paragraph = paragraph {
            progressSyncer.paragraphReached()
            updateNowPlaying()
            listener?.onTTSParagraph(chapterIndex: chapterIndex, paragraphIndex: paragraphIndex, location: paragraph.location, progress: progress)
        }
    }

    private func speakCurrentChunk() {
        guard state == .playing else { return }
        guard chunkIndex < chunks.count else {
            advance()
            return
        }
        let utterance = AVSpeechUtterance(string: chunks[chunkIndex])
        utterance.voice = resolveVoice()
        utterance.rate = utteranceRate
        utterance.prefersAssistiveTechnologySettings = false
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func advance() {
        guard let currentBook = book else { return }
        // Next paragraph, moving across chapter boundaries (empty chapters are
        // not produced by the extractor but guard anyway)
        var ci = chapterIndex
        var pi = paragraphIndex + 1
        while ci < currentBook.chapters.count && pi >= currentBook.chapters[ci].paragraphs.count {
            ci += 1
            pi = 0
        }
        if ci >= currentBook.chapters.count {
            AbsLogger.info(message: "TTSPlayer: Reached the end of the book")
            endOfBookReached = true
            setState(.stopped)
            return
        }
        chapterIndex = ci
        paragraphIndex = pi
        loadCurrentParagraph()
        speakCurrentChunk()
    }

    /// The voice for the selected identifier, else the default voice of the language, else any voice of that language
    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            // A voice of another language would override the language of the
            // book (a voice kept from a book in another language)
            if TTSPlayer.sameLanguage(voice.language, language) {
                return voice
            }
            AbsLogger.info(message: "TTSPlayer: Voice \(voiceIdentifier) is not a \(language) voice, using the language default")
        }
        if let voice = AVSpeechSynthesisVoice(language: language) {
            return voice
        }
        let prefix = language.split(separator: "-").first.map { String($0).lowercased() } ?? language.lowercased()
        if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.lowercased().hasPrefix(prefix) }) {
            return voice
        }
        if !languageWarned {
            languageWarned = true
            AbsLogger.error(message: "TTSPlayer: Language \(language) not supported by the speech synthesizer")
            listener?.onTTSError("Language \(language) is not supported")
        }
        return nil // system default voice
    }

    /// Whether two language tags ("cs-CZ", "cs_CZ", "cs") name the same language
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        return languagePrefix(a) == languagePrefix(b)
    }

    private static func languagePrefix(_ tag: String) -> String {
        let normalized = tag.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map { String($0).lowercased() } ?? normalized.lowercased()
    }

    /// AVSpeechUtterance rates are not a multiplier: the default (0.5) is normal
    /// speed. Below normal the scale is roughly proportional; above it a quarter
    /// of the range per 1x is close to the Android engine (2x ≈ 0.75).
    private var utteranceRate: Float {
        let base = AVSpeechUtteranceDefaultSpeechRate
        let mapped: Float = rate <= 1 ? base * rate : base + (rate - 1) * 0.25
        return min(max(mapped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        return min(max(value, lower), upper)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, utterance === self.currentUtterance, self.state == .playing else { return }
            self.currentUtterance = nil
            self.chunkIndex += 1
            self.speakCurrentChunk()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cancelled by interrupt() - the current utterance guard already moved on
    }

    // MARK: - Audio session

    private func activateAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            return true
        } catch {
            AbsLogger.error(message: "TTSPlayer: Failed to activate the audio session: \(error)")
            return false
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Speech may still be winding down - the session then deactivates on its own
            AbsLogger.info(message: "TTSPlayer: Audio session deactivation deferred: \(error)")
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        // When the interruption is from the app suspending then don't touch playback
        if #available(iOS 14.5, *) {
            let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            if AVAudioSession.InterruptionReason(rawValue: reasonValue) == .appWasSuspended {
                return
            }
        }

        let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch type {
            case .began:
                // Ducked speech is unintelligible, so any interruption pauses
                if self.state == .playing {
                    self.resumeAfterInterruption = true
                    self.pause()
                }
            case .ended:
                guard self.resumeAfterInterruption else { return }
                self.resumeAfterInterruption = false
                if AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable,
              let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription else { return }
        // Headphones unplugged - pause instead of continuing on the speaker
        let headphonesWereConnected = !previousRoute.outputs.filter({ $0.portType == .headphones }).isEmpty
        guard headphonesWereConnected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pause()
        }
    }

    // MARK: - Now Playing and remote commands

    private func takeNowPlaying() {
        guard !hasNowPlaying else { return }
        hasNowPlaying = true
        UIApplication.shared.beginReceivingRemoteControlEvents()
        registerRemoteCommands()
        loadArtwork()
    }

    private func releaseNowPlaying() {
        guard hasNowPlaying else { return }
        hasNowPlaying = false
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Hand the remote commands back to the audiobook player, when one exists
        PlayerHandler.updateRemoteTransportControls()
    }

    private func updateNowPlaying() {
        guard hasNowPlaying, let currentBook = book else { return }
        var info: [String: Any] = [:]
        let chapterTitle = currentBook.chapter(at: chapterIndex)?.title ?? ""
        info[MPMediaItemPropertyTitle] = currentBook.title
        info[MPMediaItemPropertyArtist] = currentBook.author ?? ""
        info[MPMediaItemPropertyAlbumTitle] = chapterTitle.isEmpty ? currentBook.title : chapterTitle
        info[MPMediaItemPropertyPlaybackDuration] = estimatedDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = estimatedPosition
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = "tts:\(currentBook.libraryItemId)"
        if let artwork = artwork, artworkItemId == currentBook.libraryItemId {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork() {
        guard let currentBook = book, artworkItemId != currentBook.libraryItemId else { return }
        artworkItemId = currentBook.libraryItemId
        artwork = nil
        guard let url = coverUrl(for: currentBook) else { return }
        ApiClient.getData(from: url) { [weak self] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                guard let self = self, self.artworkItemId == currentBook.libraryItemId else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying()
            }
        }
    }

    private func coverUrl(for currentBook: TTSBook) -> URL? {
        if currentBook.libraryItemId.hasPrefix("local") {
            return Database.shared.getLocalLibraryItem(localLibraryItemId: currentBook.libraryItemId)?.coverUrl
        }
        guard let config = Store.serverConfig else { return nil }
        if let serverAddress = currentBook.serverAddress, !serverAddress.isEmpty, serverAddress != config.address {
            return nil
        }
        // As of v2.17.0 the token is not needed with cover image requests
        if Store.isServerVersionGreaterThanOrEqualTo("2.17.0") {
            return URL(string: "\(config.address)/api/items/\(currentBook.libraryItemId)/cover")
        }
        return URL(string: "\(config.address)/api/items/\(currentBook.libraryItemId)/cover?token=\(config.token)")
    }

    /// Lock screen / headset mapping, per docs/native-tts-player-design.md (A.3):
    /// previous/next skip by pages, seek (long press) by paragraph
    private func registerRemoteCommands() {
        unregisterRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        let deviceSettings = Database.shared.getDeviceSettings()

        func register(_ command: MPRemoteCommand, enabled: Bool = true, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            // The audiobook player's targets are re-added when the session is released
            command.removeTarget(nil)
            command.isEnabled = enabled
            guard enabled else { return }
            let token = command.addTarget(handler: handler)
            remoteCommandTokens.append((command: command, token: token))
        }

        // Play after a longer pause checks the server for a position written elsewhere (resumeSession)
        register(center.playCommand) { [weak self] _ in
            self?.resumeSession()
            return .success
        }
        register(center.pauseCommand) { [weak self] _ in
            self?.pause()
            return .success
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.state == .playing { self.pause() } else { self.resumeSession() }
            return .success
        }
        register(center.stopCommand) { [weak self] _ in
            self?.stop()
            return .success
        }
        register(center.nextTrackCommand) { [weak self] _ in
            self?.seekPages(1)
            return .success
        }
        register(center.previousTrackCommand) { [weak self] _ in
            self?.seekPages(-1)
            return .success
        }
        register(center.seekForwardCommand) { [weak self] event in
            if let event = event as? MPSeekCommandEvent, event.type == .beginSeeking {
                self?.seekParagraph(1)
            }
            return .success
        }
        register(center.seekBackwardCommand) { [weak self] event in
            if let event = event as? MPSeekCommandEvent, event.type == .beginSeeking {
                self?.seekParagraph(-1)
            }
            return .success
        }
        // Skip interval buttons would replace previous/next on the lock screen
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        register(center.changePlaybackPositionCommand, enabled: deviceSettings.allowSeekingOnMediaControls) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .noSuchContent }
            self?.seekToPosition(seconds: event.positionTime)
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        register(center.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .noSuchContent }
            self?.setRate(event.playbackRate)
            return .success
        }
    }

    private func unregisterRemoteCommands() {
        for entry in remoteCommandTokens {
            entry.command.removeTarget(entry.token)
        }
        remoteCommandTokens = []
        let center = MPRemoteCommandCenter.shared()
        center.stopCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
    }

    // MARK: - Chunking

    private static let sentenceRegex = try? NSRegularExpression(pattern: "[^.!?…]+[.!?…]+[\"'”’)]*\\s*|[^.!?…]+$", options: [])

    /**
     * Split text into sentence-sized chunks - same algorithm as splitTextChunks
     * in mixins/ttsPlayer.js and the Android engine, in UTF-16 units like both.
     */
    static func splitTextChunks(_ text: String, maxLength: Int = maxChunkLength) -> [String] {
        let source = text as NSString
        var sentences: [String] = []
        if let regex = sentenceRegex {
            sentences = regex.matches(in: text, options: [], range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        }
        if sentences.isEmpty {
            sentences = [text]
        }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let sentenceLength = (sentence as NSString).length
            if !current.isEmpty && (current as NSString).length + sentenceLength > maxLength {
                chunks.append(current)
                current = ""
            }
            if sentenceLength > maxLength {
                var remaining = sentence.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
                while remaining.length > maxLength {
                    // Cut at the last space within the limit (lastIndexOf(' ', maxLength))
                    let searchRange = NSRange(location: 0, length: min(maxLength + 1, remaining.length))
                    var cut = remaining.range(of: " ", options: .backwards, range: searchRange).location
                    if cut == NSNotFound || cut <= 0 {
                        cut = maxLength
                    }
                    chunks.append(remaining.substring(to: cut))
                    remaining = remaining.substring(from: cut) as NSString
                }
                current = remaining as String
            } else {
                current += sentence
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
