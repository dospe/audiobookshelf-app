//
//  TTSBook.swift
//  Audiobookshelf
//
//  Extracted ebook text for the native read aloud (TTS) player - the same
//  payload the Android engine speaks (android/.../data/TTSBook.kt). Produced
//  by the ebook readers in the WebView (ttsExtractBook hooks) and cached on
//  disk by TTSBookCache. See docs/native-tts-player-design.md
//

import Foundation

struct TTSBook: Codable {
    static let defaultPageStep = 3
    static let defaultPageChars = 1500

    var libraryItemId: String
    var serverAddress: String?
    var title: String
    var author: String?
    var language: String
    var rate: Float
    /// Engine package name (Android only) and voice identifier; nil/empty = keep the current values
    var ttsEngine: String?
    var voice: String?
    var ebookFormat: String
    var chapters: [TTSChapter]
    var totalChars: Int
    /// Page skips from the lock screen / remote commands: pages per skip and the
    /// reader's estimate of characters on one displayed page (0 = unknown, the
    /// engine falls back to a default)
    var pageStep: Int
    var pageChars: Int

    private enum CodingKeys: String, CodingKey {
        case libraryItemId, serverAddress, title, author, language, rate, ttsEngine, voice, ebookFormat, chapters, totalChars, pageStep, pageChars
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = try values.decodeIfPresent(String.self, forKey: .libraryItemId) ?? ""
        serverAddress = try values.decodeIfPresent(String.self, forKey: .serverAddress)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try values.decodeIfPresent(String.self, forKey: .author)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en-US"
        rate = try values.decodeIfPresent(Float.self, forKey: .rate) ?? 1
        ttsEngine = try values.decodeIfPresent(String.self, forKey: .ttsEngine)
        voice = try values.decodeIfPresent(String.self, forKey: .voice)
        ebookFormat = try values.decodeIfPresent(String.self, forKey: .ebookFormat) ?? ""
        chapters = try values.decodeIfPresent([TTSChapter].self, forKey: .chapters) ?? []
        totalChars = try values.decodeIfPresent(Int.self, forKey: .totalChars) ?? 0
        pageStep = try values.decodeIfPresent(Int.self, forKey: .pageStep) ?? TTSBook.defaultPageStep
        pageChars = try values.decodeIfPresent(Int.self, forKey: .pageChars) ?? 0
    }

    func chapter(at chapterIndex: Int) -> TTSChapter? {
        guard chapterIndex >= 0, chapterIndex < chapters.count else { return nil }
        return chapters[chapterIndex]
    }

    func paragraph(chapterIndex: Int, paragraphIndex: Int) -> TTSParagraph? {
        guard let chapter = chapter(at: chapterIndex), paragraphIndex >= 0, paragraphIndex < chapter.paragraphs.count else { return nil }
        return chapter.paragraphs[paragraphIndex]
    }

    /// Total characters before the given position, for progress and time estimates
    func charsBefore(chapterIndex: Int, paragraphIndex: Int) -> Int {
        var chars = 0
        for (ci, chapter) in chapters.enumerated() {
            for (pi, paragraph) in chapter.paragraphs.enumerated() {
                if ci < chapterIndex || (ci == chapterIndex && pi < paragraphIndex) {
                    chars += paragraph.chars
                }
            }
        }
        return chars
    }

    /// Position of the paragraph with the given saved ebookLocation, or nil when not found
    func position(forLocation location: String?) -> (chapterIndex: Int, paragraphIndex: Int)? {
        guard let location = location, !location.isEmpty else { return nil }
        for (ci, chapter) in chapters.enumerated() {
            if let pi = chapter.paragraphs.firstIndex(where: { $0.location == location }) {
                return (ci, pi)
            }
        }
        return nil
    }

    /// Position of the paragraph containing the given ebookProgress ratio (by character count)
    func position(forProgress progressRatio: Double) -> (chapterIndex: Int, paragraphIndex: Int) {
        let targetChars = Int(min(max(progressRatio, 0), 1) * Double(totalChars))
        var chars = 0
        for (ci, chapter) in chapters.enumerated() {
            for (pi, paragraph) in chapter.paragraphs.enumerated() {
                chars += paragraph.chars
                if chars > targetChars {
                    return (ci, pi)
                }
            }
        }
        return lastPosition
    }

    /// Last paragraph of the book ((0, 0) for an empty book)
    var lastPosition: (chapterIndex: Int, paragraphIndex: Int) {
        let lastChapterIndex = max(0, chapters.count - 1)
        return (lastChapterIndex, max(0, (chapters.last?.paragraphs.count ?? 1) - 1))
    }
}

struct TTSChapter: Codable {
    var title: String?
    var startLocation: String?
    /// Chapter start as an epub cfi, when the extraction could build one. Saved as
    /// the reading position for paragraphs without their own cfi - unlike the
    /// spine href in startLocation every ebook reader can resume from it.
    var startCfi: String?
    var paragraphs: [TTSParagraph]

    private enum CodingKeys: String, CodingKey {
        case title, startLocation, startCfi, paragraphs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        startLocation = try values.decodeIfPresent(String.self, forKey: .startLocation)
        startCfi = try values.decodeIfPresent(String.self, forKey: .startCfi)
        paragraphs = try values.decodeIfPresent([TTSParagraph].self, forKey: .paragraphs) ?? []
    }
}

struct TTSParagraph: Codable {
    var text: String
    var location: String?
    var chars: Int

    private enum CodingKeys: String, CodingKey {
        case text, location, chars
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        location = try values.decodeIfPresent(String.self, forKey: .location)
        // The readers count UTF-16 units (String.length in JS) - keep the same unit
        chars = try values.decodeIfPresent(Int.self, forKey: .chars) ?? (text as NSString).length
    }
}

/// Lightweight summary stored next to the full book for fast listing
struct TTSBookSummary: Codable {
    var libraryItemId: String
    var serverAddress: String?
    var title: String
    var author: String?
    var language: String
    var ebookFormat: String
    var totalChars: Int
    /// Unix time in ms of the last save/load, for the LRU eviction
    var lastAccessed: Double
}
