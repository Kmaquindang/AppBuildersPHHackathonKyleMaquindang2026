// LinkStatusWords.kt: plain words for link status, same text as
// Libre/Sources/Core/LinkStatusWords.swift (Oct 12, 2026). Our own design.
package app.libre.core

object LinkStatusWords {
    /** Header line: who is linked (Android links over Bluetooth only) and what waits to send. */
    fun header(linked: Int, queued: Int): String {
        val base = if (linked == 0) "Looking for nearby devices" else if (linked == 1) "1 linked over Bluetooth" else "$linked linked over Bluetooth"
        val wait = when (queued) { 0 -> null; 1 -> "1 message waiting to send"; else -> "$queued messages waiting to send" }
        return if (wait == null) base else "$base. $wait"
    }

    fun aiDistance(hops: Int?): String? = when {
        hops == null || hops < 0 -> null
        hops == 0 -> "Linked directly to the AI Mac"
        hops == 1 -> "1 hop to the AI Mac (through 1 device)"
        else -> "$hops hops to the AI Mac (through $hops devices)"
    }
}
