package com.whim.app.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Flomo-inspired calm dark-first design tokens shared with macOS:
 * - Deep charcoal canvas (#141414) + elevated card (#1E1E1E)
 * - Sage forest green accent (#4E7D5E)
 * - Slate-blue tag pills (#1E2A3A bg / #5B9BFF text)
 */
@Immutable
data class FlomoColors(
    val canvas: Color,
    val sidebar: Color,
    val card: Color,
    val composer: Color,
    val searchBg: Color,
    val border: Color,
    val accent: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textMuted: Color,
    val tagBg: Color,
    val tagText: Color,
    val heatmapEmpty: Color,
    val heatmapL1: Color,
    val heatmapL2: Color,
    val heatmapL3: Color,
    val heatmapL4: Color
)

val DarkFlomoColors = FlomoColors(
    canvas = Color(0xFF141414),
    sidebar = Color(0xFF141414),
    card = Color(0xFF1E1E1E),
    composer = Color(0xFF1A1A1A),
    searchBg = Color(0xFF1E1E1E),
    border = Color(0x14FFFFFF),
    accent = Color(0xFF4E7D5E),
    textPrimary = Color(0xFFE6E6E6),
    textSecondary = Color(0xFF8A8A8A),
    textMuted = Color(0xFF626262),
    tagBg = Color(0xFF1E2A3A),
    tagText = Color(0xFF5B9BFF),
    heatmapEmpty = Color(0xFF282828),
    heatmapL1 = Color(0xFF2D4636),
    heatmapL2 = Color(0xFF3D634A),
    heatmapL3 = Color(0xFF4E7D5E),
    heatmapL4 = Color(0xFF6AA57D)
)

val LightFlomoColors = FlomoColors(
    canvas = Color(0xFFF5F5F5),
    sidebar = Color(0xFFEFEFEF),
    card = Color(0xFFFFFFFF),
    composer = Color(0xFFFFFFFF),
    searchBg = Color(0xFFE8E8E8),
    border = Color(0x14000000),
    accent = Color(0xFF4E7D5E),
    textPrimary = Color(0xFF1E1E1E),
    textSecondary = Color(0xFF707070),
    textMuted = Color(0xFF999999),
    tagBg = Color(0xFFEAF2FF),
    tagText = Color(0xFF2F6FE4),
    heatmapEmpty = Color(0xFFE3E5E4),
    heatmapL1 = Color(0xFFC6DEC9),
    heatmapL2 = Color(0xFF92C19B),
    heatmapL3 = Color(0xFF639E72),
    heatmapL4 = Color(0xFF467956)
)

fun FlomoColors.heatmapColor(count: Int): Color = when {
    count <= 0 -> heatmapEmpty
    count == 1 -> heatmapL1
    count == 2 -> heatmapL2
    count <= 4 -> heatmapL3
    else -> heatmapL4
}

@Immutable
data class WhimTypography(
    val title: TextStyle,
    val statNumber: TextStyle,
    val section: TextStyle,
    val body: TextStyle,
    val meta: TextStyle
)

fun createWhimTypography(fontFamily: FontFamily = FontFamily.SansSerif): WhimTypography =
    WhimTypography(
        title = TextStyle(
            fontFamily = fontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 18.sp,
            lineHeight = 24.sp,
            letterSpacing = (-0.3).sp
        ),
        statNumber = TextStyle(
            fontFamily = fontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 22.sp,
            lineHeight = 26.sp,
            letterSpacing = (-0.5).sp
        ),
        section = TextStyle(
            fontFamily = fontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
            lineHeight = 20.sp
        ),
        body = TextStyle(
            fontFamily = fontFamily,
            fontWeight = FontWeight.Normal,
            fontSize = 14.5.sp,
            lineHeight = 22.sp,
            letterSpacing = 0.2.sp
        ),
        meta = TextStyle(
            fontFamily = fontFamily,
            fontWeight = FontWeight.Normal,
            fontSize = 12.sp,
            lineHeight = 16.sp
        )
    )

val LocalFlomoColors = staticCompositionLocalOf { DarkFlomoColors }
val LocalWhimTypography = staticCompositionLocalOf { createWhimTypography() }

object WhimTheme {
    val colors: FlomoColors
        @Composable get() = LocalFlomoColors.current
    val typography: WhimTypography
        @Composable get() = LocalWhimTypography.current
}

@Composable
fun WhimThemeProvider(
    darkTheme: Boolean = true,
    content: @Composable () -> Unit
) {
    val colors = if (darkTheme) DarkFlomoColors else LightFlomoColors
    val typography = remember { createWhimTypography() }
    CompositionLocalProvider(
        LocalFlomoColors provides colors,
        LocalWhimTypography provides typography,
        content = content
    )
}

@Composable
fun WhimDivider(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(WhimTheme.colors.border)
    )
}
