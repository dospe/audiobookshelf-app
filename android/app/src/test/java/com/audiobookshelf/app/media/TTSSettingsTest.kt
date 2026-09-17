package com.audiobookshelf.app.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TTSSettingsTest {

  @Test
  fun `book languages map onto the offered read aloud languages`() {
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage("cs"))
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage("ces"))
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage("cs_CZ"))
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage("cs-CZ"))
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage("Czech"))
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage(" čeština "))
    assertEquals("en-US", TTSLanguage.forBookLanguage("en-GB"))
    assertEquals("en-US", TTSLanguage.forBookLanguage("English"))
    assertEquals("en-US", TTSLanguage.forBookLanguage("eng"))
  }

  @Test
  fun `the first of several book languages counts`() {
    assertEquals("cs-CZ", TTSLanguage.forBookLanguage("cs; en"))
    assertEquals("en-US", TTSLanguage.forBookLanguage("en,cs"))
  }

  @Test
  fun `unknown and unoffered languages are null`() {
    assertNull(TTSLanguage.forBookLanguage(null))
    assertNull(TTSLanguage.forBookLanguage(""))
    assertNull(TTSLanguage.forBookLanguage("  "))
    assertNull(TTSLanguage.forBookLanguage("de-DE"))
    assertNull(TTSLanguage.forBookLanguage("German"))
  }

  @Test
  fun `stored ereader settings are read`() {
    val settings = TTSSettings.parse(
      """{"theme":"dark","ttsLanguage":"cs-CZ","ttsRate":1.25,"ttsEngine":"com.google.android.tts",
         "ttsVoices":{"cs-CZ":"cs-cz-x-abc-local","en-US":""},"ttsPageStep":5}"""
    )
    assertEquals("cs-CZ", settings.ttsLanguage)
    assertEquals(1.25f, settings.ttsRate)
    assertEquals("com.google.android.tts", settings.ttsEngine)
    assertEquals("cs-cz-x-abc-local", settings.voiceFor("cs-CZ"))
    assertEquals("", settings.voiceFor("en-US"))
    assertEquals(5, settings.ttsPageStep)
  }

  @Test
  fun `the system default engine is kept apart from a missing setting`() {
    assertEquals("", TTSSettings.parse("""{"ttsEngine":""}""").ttsEngine)
    assertNull(TTSSettings.parse("""{"ttsLanguage":"cs-CZ"}""").ttsEngine)
  }

  @Test
  fun `damaged or missing values are null`() {
    val settings = TTSSettings.parse("""{"ttsLanguage":"klingon","ttsRate":"fast","ttsPageStep":0,"ttsVoices":"nope"}""")
    assertNull(settings.ttsLanguage)
    assertNull(settings.ttsRate)
    assertNull(settings.ttsPageStep)
    assertTrue(settings.ttsVoices.isEmpty())

    assertEquals(TTSSettings.EMPTY, TTSSettings.parse(null))
    assertEquals(TTSSettings.EMPTY, TTSSettings.parse(""))
    assertEquals(TTSSettings.EMPTY, TTSSettings.parse("not json"))
    assertEquals(TTSSettings.EMPTY, TTSSettings.parse("[1,2]"))
  }

  @Test
  fun `an older language setting is normalized`() {
    assertEquals("cs-CZ", TTSSettings.parse("""{"ttsLanguage":"cs"}""").ttsLanguage)
    assertEquals("en-US", TTSSettings.parse("""{"ttsLanguage":"en-GB"}""").ttsLanguage)
  }

  @Test
  fun `a rate outside the offered range is ignored`() {
    assertNull(TTSSettings.parse("""{"ttsRate":4}""").ttsRate)
    assertEquals(0.5f, TTSSettings.parse("""{"ttsRate":0.5}""").ttsRate)
  }
}
