//
//  TTSProgressSyncer.swift
//  Audiobookshelf
//
//  Syncs the read aloud (TTS) ebook progress while the native engine speaks,
//  so progress reaches the local db and the server without the WebView
//  reader being open. Same 15s cadence as the audiobook progress sync and
//  the same ebookLocation/ebookProgress format the reader saves - reading
//  and listening stay interchangeable. Counterpart of the Android
//  TTSProgressSyncer. See docs/native-tts-player-design.md (A.6)
//

import Foundation
import Network
import RealmSwift
import UIKit

/// Ebook progress payload for PATCH api/me/progress/:id - the keys the reader and the Android syncer send
struct TTSEbookProgressPayload: Encodable {
    var ebookLocation: String?
    var ebookProgress: Double
    var lastUpdate: Double
}

class TTSProgressSyncer {
    private static let syncInterval: TimeInterval = 15
    private static let meteredServerSyncInterval: TimeInterval = 60

    unowned let player: TTSPlayer

    private var timer: Timer?
    private(set) var isRunning = false
    // Set on every spoken paragraph, cleared after a successful local save
    private var dirty = false
    private var lastServerSyncTime: TimeInterval = 0

    private let monitor = NWPathMonitor()
    private var isConnected = true
    private var isExpensiveConnection = false

    init(player: TTSPlayer) {
        self.player = player
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.isExpensiveConnection = path.isExpensive || path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
    }

    deinit {
        monitor.cancel()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastServerSyncTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: TTSProgressSyncer.syncInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only sync with the server on an unmetered connection every 15s OR
            // if the last server sync is >= 60s (audiobook syncer behavior)
            let shouldSyncServer = !self.isExpensiveConnection ||
                Date().timeIntervalSince1970 - self.lastServerSyncTime >= TTSProgressSyncer.meteredServerSyncInterval
            self.sync(shouldSyncServer: shouldSyncServer)
        }
    }

    /// Called for every paragraph the engine reaches; the position is read from the engine at sync time
    func paragraphReached() {
        dirty = true
    }

    /// Stop the timer and sync the final position (pause, stop, end of book)
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        sync(shouldSyncServer: true)
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        dirty = false
        lastServerSyncTime = 0
    }

    private func sync(shouldSyncServer: Bool) {
        guard dirty, let book = player.book else { return }

        // Paragraphs without a location fall back to the chapter start so the
        // reader can still return close to the spoken position: the chapter cfi
        // when the extraction built one (the format every ebook reader resumes
        // from), the raw chapter href only as a last resort
        let chapter = book.chapter(at: player.chapterIndex)
        let location = nonEmpty(player.currentLocation) ?? nonEmpty(chapter?.startCfi) ?? nonEmpty(chapter?.startLocation)
        let progress = player.progress
        let lastUpdate = Date().timeIntervalSince1970 * 1000

        if book.libraryItemId.hasPrefix("local") {
            dirty = false
            guard let localMediaProgress = saveLocalProgress(localLibraryItemId: book.libraryItemId, location: location, progress: progress, lastUpdate: lastUpdate) else { return }

            // Local item linked to a server library item - also patch the server
            // when connected to that server (same mapping as the reader). A skipped
            // or failed patch catches up with the next local progress sync.
            guard shouldSyncServer,
                  let serverLibraryItemId = localMediaProgress.libraryItemId, !serverLibraryItemId.isEmpty,
                  let serverConfig = Store.serverConfig,
                  localMediaProgress.serverConnectionConfigId == serverConfig.id,
                  isConnected else { return }
            sendServerProgress(libraryItemId: serverLibraryItemId, location: location, progress: progress, lastUpdate: lastUpdate)
        } else {
            // Streamed server item - progress lives on the server only, so keep
            // dirty and retry on the next tick until the patch can be sent
            guard shouldSyncServer,
                  let serverConfig = Store.serverConfig, !serverConfig.address.isEmpty,
                  serverConfig.address == book.serverAddress,
                  isConnected else { return }
            dirty = false
            sendServerProgress(libraryItemId: book.libraryItemId, location: location, progress: progress, lastUpdate: lastUpdate)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    private func saveLocalProgress(localLibraryItemId: String, location: String?, progress: Double, lastUpdate: Double) -> LocalMediaProgress? {
        do {
            guard let localMediaProgress = try LocalMediaProgress.fetchOrCreateLocalMediaProgress(localMediaProgressId: localLibraryItemId, localLibraryItemId: localLibraryItemId, localEpisodeId: nil) else {
                AbsLogger.error(message: "TTSProgressSyncer: Local library item \(localLibraryItemId) not found")
                return nil
            }
            try localMediaProgress.realm?.write {
                // Without a location for the spoken position the stored one is kept -
                // clearing it would restart the reader at the beginning of the book
                if let location = location {
                    localMediaProgress.ebookLocation = location
                }
                localMediaProgress.ebookProgress = progress
                localMediaProgress.lastUpdate = lastUpdate
            }
            // The audio player plugin forwards the saved progress to the WebView
            NotificationCenter.default.post(name: NSNotification.Name(PlayerEvents.localProgress.rawValue), object: nil, userInfo: ["localMediaProgressId": localLibraryItemId])
            AbsLogger.info(message: "TTSProgressSyncer: Saved local ebook progress \(progress) (location: \(location ?? "nil")) for \(localLibraryItemId)")
            return localMediaProgress
        } catch {
            AbsLogger.error(message: "TTSProgressSyncer: Failed to save local progress for \(localLibraryItemId): \(error)")
            return nil
        }
    }

    private func sendServerProgress(libraryItemId: String, location: String?, progress: Double, lastUpdate: Double) {
        let payload = TTSEbookProgressPayload(ebookLocation: location, ebookProgress: progress, lastUpdate: lastUpdate)
        // The final sync after a stop can run while the app is going to the background
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ABS:ttsProgressSync") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        ApiClient.patchResourceWithTokenRefresh(endpoint: "api/me/progress/\(libraryItemId)", parameters: payload) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.lastServerSyncTime = Date().timeIntervalSince1970
                    AbsLogger.info(message: "TTSProgressSyncer: Synced TTS ebook progress \(progress) for item \"\(libraryItemId)\"")
                } else {
                    // Keep dirty so the next tick retries with the latest position
                    self?.dirty = true
                    AbsLogger.error(message: "TTSProgressSyncer: Failed to sync TTS ebook progress for item \"\(libraryItemId)\"")
                }
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
        }
    }
}
