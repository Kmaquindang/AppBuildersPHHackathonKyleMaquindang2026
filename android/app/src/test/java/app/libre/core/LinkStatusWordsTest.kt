package app.libre.core

import org.junit.Assert.*
import org.junit.Test

class LinkStatusWordsTest {
    @Test fun headerWords() {
        assertEquals("Looking for nearby devices", LinkStatusWords.header(0, 0))
        assertEquals("Looking for nearby devices. 1 message waiting to send", LinkStatusWords.header(0, 1))
        assertEquals("2 linked over Bluetooth. 3 messages waiting to send", LinkStatusWords.header(2, 3))
        assertEquals("1 linked over Bluetooth", LinkStatusWords.header(1, 0))
    }

    @Test fun aiDistanceMatchesSwift() {
        assertNull(LinkStatusWords.aiDistance(null))
        assertEquals("Linked directly to the AI Mac", LinkStatusWords.aiDistance(0))
        assertEquals("1 hop to the AI Mac (through 1 device)", LinkStatusWords.aiDistance(1))
        assertEquals("3 hops to the AI Mac (through 3 devices)", LinkStatusWords.aiDistance(3))
    }
}
