import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

/// Design tokens ported from theme.css / App.tsx
class K {
  static const bg = Color(0xFF0B1411);
  static const bg2 = Color(0xFF101B17);
  static const card = Color(0xFF16231F);
  static const sheet = Color(0xFF17241F);
  static const lime = Color(0xFFC9FF55);
  static const ink = Color(0xFF0D1714);
  static const muted = Color(0xFF8B9A94);
  static const dim = Color(0xFF65766E);
  static const danger = Color(0xFFFF765F);
  static const amber = Color(0xFFFFC85A);
  static const glass = Color(0x0BFFFFFF); // white 4.5%
  static const glass2 = Color(0x14FFFFFF); // white 8%
  static const border = Color(0x12FFFFFF); // white 7%
}

TextStyle t(double size,
        {FontWeight w = FontWeight.w700, Color c = Colors.white, double ls = 0, double? h}) =>
    GoogleFonts.manrope(fontSize: size, fontWeight: w, color: c, letterSpacing: ls, height: h);

TextStyle mono(double size, {FontWeight w = FontWeight.w500, Color c = Colors.white}) =>
    GoogleFonts.dmMono(fontSize: size, fontWeight: w, color: c);

final _money = NumberFormat('#,##0', 'en_US');
String money(num v) => 'TZS ${_money.format(v)}';
String num0(num v) => _money.format(v);
String compact(num v) {
  if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
  if (v.abs() >= 1e3) return '${(v / 1e3).toStringAsFixed(0)}K';
  return v.toStringAsFixed(0);
}

InputDecoration dec(String? label, {String? hint, Widget? suffix, Widget? prefix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffix,
      prefixIcon: prefix,
      labelStyle: t(12, w: FontWeight.w600, c: K.muted),
      hintStyle: t(12, w: FontWeight.w500, c: K.dim),
      filled: true,
      fillColor: K.glass,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: K.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: K.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: K.lime)),
    );

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: K.bg,
    colorScheme: const ColorScheme.dark(
      primary: K.lime,
      onPrimary: K.ink,
      surface: K.card,
      error: K.danger,
    ),
    textTheme: GoogleFonts.manropeTextTheme(base.textTheme).apply(bodyColor: Colors.white, displayColor: Colors.white),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF223630),
      behavior: SnackBarBehavior.floating,
      contentTextStyle: t(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(backgroundColor: K.sheet, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? K.ink : K.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? K.lime : const Color(0xFF34453E)),
    ),
  );
}
