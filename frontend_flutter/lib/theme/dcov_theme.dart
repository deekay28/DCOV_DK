import 'package:flutter/material.dart';

/// Design tokens ported 1:1 from web_demo/index.html's CSS custom properties,
/// so the Flutter app and the offline web demo read as the same product.
/// Rule: chrome is achromatic; a verdict colour is the only saturated colour
/// on screen, and it always means the same thing.
class DcovColors {
  DcovColors._();

  static const redD = Color(0xFFD6392A);
  static const greenD = Color(0xFF1FA463);
  static const amberD = Color(0xFFD19400);
  static const greyD = Color(0xFF7A858C);

  static const redL = Color(0xFFB32316);
  static const greenL = Color(0xFF136B3C);
  static const amberL = Color(0xFF8A6400);
  static const greyL = Color(0xFF5E686E);

  static const redBgD = Color(0xFF2A1210);
  static const greenBgD = Color(0xFF0E2318);
  static const amberBgD = Color(0xFF2A2008);
  static const greyBgD = Color(0xFF1B2126);

  static const redBgL = Color(0xFFFBE4E1);
  static const greenBgL = Color(0xFFDFF0E6);
  static const amberBgL = Color(0xFFFAEFD2);
  static const greyBgL = Color(0xFFE2E5E0);

  static Color forBanner(String banner, Brightness b) {
    final dark = b == Brightness.dark;
    switch (banner) {
      case 'RED': return dark ? redD : redL;
      case 'GREEN': return dark ? greenD : greenL;
      case 'YELLOW': return dark ? amberD : amberL;
      default: return dark ? greyD : greyL;
    }
  }

  static Color bgForBanner(String banner, Brightness b) {
    final dark = b == Brightness.dark;
    switch (banner) {
      case 'RED': return dark ? redBgD : redBgL;
      case 'GREEN': return dark ? greenBgD : greenBgL;
      case 'YELLOW': return dark ? amberBgD : amberBgL;
      default: return dark ? greyBgD : greyBgL;
    }
  }
}

class DcovTheme {
  DcovTheme._();

  static const _mono = 'RobotoMono'; // falls back to system monospace if unbundled

  static ThemeData dark() => _build(
        background: const Color(0xFF0F1417),
        panel: const Color(0xFF171F24),
        panel2: const Color(0xFF1D272D),
        rule: const Color(0xFF27333A),
        ink: const Color(0xFFE6EBE9),
        ink2: const Color(0xFF9EAEB6),
        silk: const Color(0xFF71838C),
        brightness: Brightness.dark,
      );

  static ThemeData light() => _build(
        background: const Color(0xFFE7E8E2),
        panel: const Color(0xFFF6F7F3),
        panel2: const Color(0xFFEDEFE9),
        rule: const Color(0xFFC7CAC1),
        ink: const Color(0xFF131A1E),
        ink2: const Color(0xFF4C575D),
        silk: const Color(0xFF6B767C),
        brightness: Brightness.light,
      );

  static ThemeData _build({
    required Color background, required Color panel, required Color panel2,
    required Color rule, required Color ink, required Color ink2,
    required Color silk, required Brightness brightness,
  }) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        surface: panel, onSurface: ink, primary: ink, onPrimary: background,
        secondary: ink2, outline: rule,
      ),
      dividerColor: rule,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      appBarTheme: AppBarTheme(
        backgroundColor: background, foregroundColor: ink, elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
            color: ink, fontFamily: _mono, fontWeight: FontWeight.w700,
            fontSize: 17, letterSpacing: 0.5),
      ),
      cardTheme: CardThemeData(
        color: panel, elevation: 0, margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3), side: BorderSide(color: rule)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: panel2,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: rule)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: rule)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2), borderSide: BorderSide(color: ink2)),
        hintStyle: TextStyle(color: silk, fontFamily: _mono),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ink, foregroundColor: background,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          textStyle: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w700,
              letterSpacing: 1.2, fontSize: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink, minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: rule),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          textStyle: const TextStyle(fontFamily: _mono, fontWeight: FontWeight.w700,
              letterSpacing: 1.2, fontSize: 12),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel, indicatorColor: Colors.transparent,
        surfaceTintColor: Colors.transparent, height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontFamily: _mono, fontSize: 9.5, letterSpacing: 0.8,
            color: states.contains(WidgetState.selected) ? ink : silk)),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? ink : silk, size: 20)),
      ),
      extensions: [DcovTokens(panel: panel, panel2: panel2, rule: rule, ink: ink, ink2: ink2, silk: silk)],
    );
  }
}

/// Non-standard tokens (silkscreen labels, panel-2, etc.) not covered by
/// ColorScheme, exposed the same way Material recommends for custom design
/// systems layered on top of Theme.
class DcovTokens extends ThemeExtension<DcovTokens> {
  final Color panel, panel2, rule, ink, ink2, silk;
  const DcovTokens({required this.panel, required this.panel2, required this.rule,
      required this.ink, required this.ink2, required this.silk});

  @override
  DcovTokens copyWith({Color? panel, Color? panel2, Color? rule, Color? ink,
      Color? ink2, Color? silk}) => DcovTokens(
        panel: panel ?? this.panel, panel2: panel2 ?? this.panel2,
        rule: rule ?? this.rule, ink: ink ?? this.ink, ink2: ink2 ?? this.ink2,
        silk: silk ?? this.silk);

  @override
  DcovTokens lerp(ThemeExtension<DcovTokens>? other, double t) =>
      other is DcovTokens ? this : this;
}

extension DcovContext on BuildContext {
  DcovTokens get tokens => Theme.of(this).extension<DcovTokens>()!;
}
