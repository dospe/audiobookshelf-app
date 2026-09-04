package com.audiobookshelf.app.data

import com.fasterxml.jackson.annotation.JsonIgnoreProperties

/**
 * Extracted ebook text for the native read aloud (TTS) player.
 * Produced by the ebook readers in the WebView (ttsExtractBook hooks)
 * and cached on disk by TTSBookCache.
 * See docs/native-tts-player-design.md
 */
@JsonIgnoreProperties(ignoreUnknown = true)
data class TTSBook(
  var libraryItemId: String,
  var serverAddress: String?,
  var title: String,
  var author: String?,
  var language: String,
  var rate: Float,
  // TTS engine package name and voice name; null/empty = engine keeps its current values
  var ttsEngine: String? = null,
  var voice: String? = null,
  var ebookFormat: String,
  var chapters: MutableList<TTSChapter>,
  var totalChars: Int,
  /**
   * Page skips from the media session (notification, lock screen, Android
   * Auto): pages per skip and the reader's estimate of characters on one
   * displayed page (0 = unknown, the engine falls back to a default).
   */
  var pageStep: Int = DEFAULT_PAGE_STEP,
  var pageChars: Int = 0
) {
  constructor() : this("", null, "", null, "en-US", 1f, null, null, "", mutableListOf(), 0)

  companion object {
    const val DEFAULT_PAGE_STEP = 3
    const val DEFAULT_PAGE_CHARS = 1500
  }

  /** Total characters before the given position, for progress and time estimates */
  fun charsBefore(chapterIndex: Int, paragraphIndex: Int): Int {
    var chars = 0
    chapters.forEachIndexed { ci, chapter ->
      chapter.paragraphs.forEachIndexed { pi, paragraph ->
        if (ci < chapterIndex || (ci == chapterIndex && pi < paragraphIndex)) {
          chars += paragraph.chars
        }
      }
    }
    return chars
  }

  /** Position of the paragraph with the given saved ebookLocation, or null when not found */
  fun positionForLocation(location: String?): Pair<Int, Int>? {
    if (location.isNullOrEmpty()) return null
    chapters.forEachIndexed { ci, chapter ->
      chapter.paragraphs.forEachIndexed { pi, paragraph ->
        if (paragraph.location == location) return Pair(ci, pi)
      }
    }
    return null
  }

  /** Position of the paragraph containing the given ebookProgress ratio (by character count) */
  fun positionForProgress(progressRatio: Double): Pair<Int, Int> {
    val targetChars = (progressRatio.coerceIn(0.0, 1.0) * totalChars).toInt()
    var chars = 0
    chapters.forEachIndexed { ci, chapter ->
      chapter.paragraphs.forEachIndexed { pi, paragraph ->
        chars += paragraph.chars
        if (chars > targetChars) return Pair(ci, pi)
      }
    }
    val lastChapterIndex = maxOf(0, chapters.size - 1)
    return Pair(lastChapterIndex, maxOf(0, (chapters.lastOrNull()?.paragraphs?.size ?: 1) - 1))
  }
}

@JsonIgnoreProperties(ignoreUnknown = true)
data class TTSChapter(
  var title: String?,
  var startLocation: String?,
  var paragraphs: MutableList<TTSParagraph>,
  /**
   * Chapter start as an epub cfi, when the extraction could build one. Saved as
   * the reading position for paragraphs without their own cfi - unlike the
   * spine href in [startLocation] every ebook reader can resume from it.
   */
  var startCfi: String? = null
) {
  constructor() : this(null, null, mutableListOf())
}

@JsonIgnoreProperties(ignoreUnknown = true)
data class TTSParagraph(
  var text: String,
  var location: String?,
  var chars: Int
) {
  constructor() : this("", null, 0)
}

/** Lightweight summary stored next to the full book for fast listing (Android Auto browse) */
@JsonIgnoreProperties(ignoreUnknown = true)
data class TTSBookSummary(
  var libraryItemId: String,
  var serverAddress: String?,
  var title: String,
  var author: String?,
  var language: String,
  var ebookFormat: String,
  var totalChars: Int,
  var lastAccessed: Long
) {
  constructor() : this("", null, "", null, "en-US", "", 0, 0L)
}
