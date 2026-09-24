package com.audiobookshelf.app.data

import com.fasterxml.jackson.annotation.JsonIgnore
import com.fasterxml.jackson.annotation.JsonIgnoreProperties

@JsonIgnoreProperties(ignoreUnknown = true)
class MediaProgress(
  var id:String,
  var libraryItemId:String,
  var episodeId:String?,
  var duration:Double, // seconds
  progress:Double, // 0 to 1
  currentTime:Double,
  isFinished:Boolean,
  var ebookLocation:String?, // cfi tag
  var ebookProgress:Double?, // 0 to 1
  var lastUpdate:Long,
  var startedAt:Long,
  var finishedAt:Long?,
  // Per-book ereader settings the reader stores with the progress (fork
  // server): the read aloud language of the book at the top level, the
  // appearance per device under `devices`. Kept as sent - only ttsLanguage is
  // read natively (see PlayerNotificationService.resolveTTSLanguage)
  var ebookSettings:Map<String, Any?>? = null,
  // Furthest place ever reached in the ebook (fork server, kept from
  // ebookProgress): Android Auto offers to go back there while reading aloud
  var furthestEbookLocation:String? = null,
  var furthestEbookProgress:Double? = null
) : MediaProgressWrapper(isFinished, currentTime, progress) {

  @get:JsonIgnore
  override val mediaItemId get() = if (episodeId.isNullOrEmpty()) libraryItemId else "$libraryItemId-$episodeId"

  /** Read aloud language saved for the book by the reader, null when none */
  @get:JsonIgnore
  val ebookTtsLanguage:String? get() = ebookSettings?.get("ttsLanguage") as? String
}
