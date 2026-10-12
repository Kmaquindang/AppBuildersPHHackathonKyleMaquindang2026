package app.libre.android

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object LibreColors {
    val Emerald = Color(0xFF0B7A55)
    val EmeraldDark = Color(0xFF12B886)
    val Incoming = Color(0xFFE9ECEF)
    val IncomingDark = Color(0xFF2B2F33)
}

@Composable
fun LibreTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) darkColorScheme(primary = LibreColors.EmeraldDark, onPrimary = Color.Black, secondary = LibreColors.EmeraldDark)
    else lightColorScheme(primary = LibreColors.Emerald, onPrimary = Color.White, secondary = LibreColors.Emerald)
    MaterialTheme(colorScheme = scheme, content = content)
}
