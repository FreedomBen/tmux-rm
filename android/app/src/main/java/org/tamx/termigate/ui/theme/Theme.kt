package org.tamx.termigate.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val TerminalGreen = Color(0xFF4EC94E)
private val TerminalGreenDark = Color(0xFF3AA33A)
private val DarkBackground = Color(0xFF121212)
private val DarkSurface = Color(0xFF1E1E1E)

private val DarkColorScheme = darkColorScheme(
    primary = TerminalGreen,
    onPrimary = Color.Black,
    primaryContainer = TerminalGreenDark,
    onPrimaryContainer = Color.White,
    background = DarkBackground,
    surface = DarkSurface,
    onBackground = Color(0xFFE0E0E0),
    onSurface = Color(0xFFE0E0E0),
    // Bug 8 in ANDROID_DRIVE_01.md: leaving these to M3's defaults
    // gave us a purple-tinged onSurfaceVariant / outline pair that
    // disappeared against our custom #1E1E1E surface — so unfocused
    // OutlinedTextFields rendered with no visible label or border
    // and only "lit up" once focus flipped the label to primary
    // (terminal green). Pinning explicit mid-grays keeps unfocused
    // fields readable.
    surfaceVariant = Color(0xFF2A2A2A),
    onSurfaceVariant = Color(0xFFB0B0B0),
    outline = Color(0xFF606060),
    error = Color(0xFFCF6679)
)

private val LightColorScheme = lightColorScheme(
    primary = TerminalGreenDark,
    onPrimary = Color.White
)

@Composable
fun TermigateTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        content = content
    )
}
