package ch.lkmc.monkeyspaw.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val LightColors = lightColorScheme(
    primary = Color(0xFF4355A1), onPrimary = Color.White,
    primaryContainer = Color(0xFFDEE1FF), onPrimaryContainer = Color(0xFF101A48),
    secondary = Color(0xFF5B5F71), onSecondary = Color.White,
    secondaryContainer = Color(0xFFE1E2F0), onSecondaryContainer = Color(0xFF181B2A),
    tertiary = Color(0xFF785820), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFDEAC), onTertiaryContainer = Color(0xFF281900),
    background = Color(0xFFF9F9FD), onBackground = Color(0xFF1B1B21),
    surface = Color(0xFFF9F9FD), onSurface = Color(0xFF1B1B21),
    surfaceVariant = Color(0xFFE3E1EC), onSurfaceVariant = Color(0xFF464650),
    outline = Color(0xFF777680), outlineVariant = Color(0xFFC7C5D0),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF2F3F9),
    surfaceContainer = Color(0xFFECEDF5), surfaceContainerHigh = Color(0xFFE6E7EF),
    surfaceContainerHighest = Color(0xFFDFE1EA),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFBAC3FF), onPrimary = Color(0xFF11225F),
    primaryContainer = Color(0xFF2B3B86), onPrimaryContainer = Color(0xFFDEE1FF),
    secondary = Color(0xFFC4C5D6), onSecondary = Color(0xFF2D3040),
    secondaryContainer = Color(0xFF434656), onSecondaryContainer = Color(0xFFE1E2F0),
    tertiary = Color(0xFFE9C184), onTertiary = Color(0xFF432D04),
    tertiaryContainer = Color(0xFF5F4311), onTertiaryContainer = Color(0xFFFFDEAC),
    background = Color(0xFF121318), onBackground = Color(0xFFE4E1E9),
    surface = Color(0xFF121318), onSurface = Color(0xFFE4E1E9),
    surfaceVariant = Color(0xFF464650), onSurfaceVariant = Color(0xFFC7C5D0),
    outline = Color(0xFF918F9A), outlineVariant = Color(0xFF464650),
    surfaceContainerLowest = Color(0xFF0D0E13), surfaceContainerLow = Color(0xFF1A1B21),
    surfaceContainer = Color(0xFF1F1F26), surfaceContainerHigh = Color(0xFF292930),
    surfaceContainerHighest = Color(0xFF34343B),
)

private val PawTypography = Typography(
    headlineLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 32.sp, lineHeight = 38.sp, letterSpacing = (-0.5).sp),
    headlineMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 28.sp, lineHeight = 34.sp, letterSpacing = (-0.3).sp),
    headlineSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 24.sp, lineHeight = 30.sp),
    titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 24.sp),
    titleSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 18.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, lineHeight = 20.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp),
)

private val PawShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp), small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp), large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

/** Resource-only theming is shared by activities and the local-only IME graph. */
@Composable
internal fun MonkeysPawTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val context = LocalContext.current
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else if (dark) DarkColors else LightColors

    MaterialTheme(colorScheme = colors, typography = PawTypography, shapes = PawShapes, content = content)
}
