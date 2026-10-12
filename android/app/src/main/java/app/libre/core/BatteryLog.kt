// BatteryLog.kt: battery lines for device tests (issue #7), same format as BatteryLog.swift:
// "BAT pct=83 charging=0 links=2 bright=0.50 state=bg os=Android 15 model=Pixel 8". LibreApp writes
// one to logcat (tag LibreMesh) every 5 minutes and on each foreground or background change.
package app.libre.core

import java.util.Locale

object BatteryLog {
    const val EVERY_MS = 300_000L

    fun line(percent: Int?, charging: Boolean, links: Int, brightness: Double?, foreground: Boolean, os: String, model: String): String {
        val bright = brightness?.let { String.format(Locale.US, "%.2f", it) } ?: "-1"
        return "BAT pct=${percent ?: -1} charging=${if (charging) 1 else 0} links=$links bright=$bright state=${if (foreground) "fg" else "bg"} os=$os model=$model"
    }

    fun due(lastMs: Long?, nowMs: Long): Boolean = lastMs == null || nowMs - lastMs >= EVERY_MS
}
