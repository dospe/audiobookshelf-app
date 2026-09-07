//
//  TTSBookCache.swift
//  Audiobookshelf
//
//  Disk cache of extracted ebook text (TTSBook) so the native read aloud
//  player can resume a book without the WebView. Same layout and limits as
//  the Android TTSBookCache: Application Support/tts-cache/<id>.json (full
//  book) plus <id>.meta.json (TTSBookSummary); the oldest books by
//  lastAccessed are evicted over maxBooks / maxTotalBytes.
//

import Foundation

class TTSBookCache {
    static let maxBooks = 20
    static let maxTotalBytes: Int64 = 50 * 1024 * 1024 // 50 MB

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    private var cacheDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("tts-cache", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func sanitizeId(_ libraryItemId: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return libraryItemId.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private func bookFile(_ libraryItemId: String) -> URL {
        return cacheDir.appendingPathComponent("\(sanitizeId(libraryItemId)).json")
    }

    private func metaFile(_ libraryItemId: String) -> URL {
        return cacheDir.appendingPathComponent("\(sanitizeId(libraryItemId)).meta.json")
    }

    func save(_ book: TTSBook) {
        do {
            let summary = TTSBookSummary(
                libraryItemId: book.libraryItemId,
                serverAddress: book.serverAddress,
                title: book.title,
                author: book.author,
                language: book.language,
                ebookFormat: book.ebookFormat,
                totalChars: book.totalChars,
                lastAccessed: Date().timeIntervalSince1970 * 1000
            )
            try encoder.encode(book).write(to: bookFile(book.libraryItemId), options: .atomic)
            try encoder.encode(summary).write(to: metaFile(book.libraryItemId), options: .atomic)
            evictOverLimit()
        } catch {
            AbsLogger.error(message: "TTSBookCache: Failed to save book \(book.libraryItemId): \(error)")
        }
    }

    func load(_ libraryItemId: String) -> TTSBook? {
        let file = bookFile(libraryItemId)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            let book = try decoder.decode(TTSBook.self, from: Data(contentsOf: file))
            touch(libraryItemId)
            return book
        } catch {
            AbsLogger.error(message: "TTSBookCache: Failed to load book \(libraryItemId): \(error)")
            return nil
        }
    }

    func has(_ libraryItemId: String) -> Bool {
        return fileManager.fileExists(atPath: bookFile(libraryItemId).path)
    }

    /// Cached books, most recently accessed first
    func list() -> [TTSBookSummary] {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return [] }
        var summaries: [TTSBookSummary] = []
        for file in files where file.lastPathComponent.hasSuffix(".meta.json") {
            do {
                summaries.append(try decoder.decode(TTSBookSummary.self, from: Data(contentsOf: file)))
            } catch {
                AbsLogger.error(message: "TTSBookCache: Failed to read summary \(file.lastPathComponent): \(error)")
            }
        }
        return summaries.sorted { $0.lastAccessed > $1.lastAccessed }
    }

    func remove(_ libraryItemId: String) {
        try? fileManager.removeItem(at: bookFile(libraryItemId))
        try? fileManager.removeItem(at: metaFile(libraryItemId))
    }

    private func touch(_ libraryItemId: String) {
        let file = metaFile(libraryItemId)
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            var summary = try decoder.decode(TTSBookSummary.self, from: Data(contentsOf: file))
            summary.lastAccessed = Date().timeIntervalSince1970 * 1000
            try encoder.encode(summary).write(to: file, options: .atomic)
        } catch {
            AbsLogger.error(message: "TTSBookCache: Failed to touch \(libraryItemId): \(error)")
        }
    }

    private func evictOverLimit() {
        let summaries = list() // newest first
        var totalBytes: Int64 = 0
        if let files = try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
            totalBytes = files.reduce(0) { $0 + $1.fileSize }
        }
        for (index, summary) in summaries.enumerated() where index >= TTSBookCache.maxBooks || totalBytes > TTSBookCache.maxTotalBytes {
            let size = bookFile(summary.libraryItemId).fileSize + metaFile(summary.libraryItemId).fileSize
            AbsLogger.info(message: "TTSBookCache: Evicting cached book \(summary.libraryItemId) (\(size) bytes)")
            remove(summary.libraryItemId)
            totalBytes -= size
        }
    }
}
