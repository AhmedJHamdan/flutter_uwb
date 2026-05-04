import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand tokens — keep in sync with `/assets/brand/README.md`.
class Brand {
  static const Color background = Color(0xFF0A0E21);
  static const Color primary = Color(0xFF00E5FF);
  static const Color secondary = Color(0xFF02569B);
  static const Color text = Color(0xFFE6ECFF);
  static const Color muted = Color(0xFF6B7392);
}

ThemeData buildBrandTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Brand.background,
    colorScheme: base.colorScheme.copyWith(
      primary: Brand.primary,
      secondary: Brand.secondary,
      surface: Brand.background,
      onPrimary: Brand.background,
      onSurface: Brand.text,
    ),
    textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: Brand.text,
      displayColor: Brand.text,
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF13182F),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Brand.muted.withValues(alpha: 0.25)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF13182F),
      contentTextStyle: TextStyle(color: Brand.text),
    ),
    iconTheme: const IconThemeData(color: Brand.text),
  );
}

/// Eyebrow text style ("UWB · RANGING") — JetBrains Mono, tracked, uppercase.
TextStyle eyebrowStyle() => GoogleFonts.jetBrainsMono(
      color: Brand.primary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 2.4,
    );

/// Big readout numeric style.
TextStyle readoutValueStyle() => GoogleFonts.jetBrainsMono(
      color: Brand.text,
      fontSize: 28,
      fontWeight: FontWeight.w600,
    );

TextStyle readoutLabelStyle() => GoogleFonts.inter(
      color: Brand.muted,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.6,
    );
