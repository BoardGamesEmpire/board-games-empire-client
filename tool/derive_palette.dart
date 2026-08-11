// Derives the "storm over walnut" palette — the four `ColorScheme`s in
// `packages/ui/tokens/lib/src/bge_color_schemes.dart` (#32).
//
// Those schemes are GENERATED, not hand-picked. This script is committed so
// the palette stays reproducible: a numerically-derived palette that cannot be
// re-derived is a maintenance trap, because the next person to touch a colour
// has no way to know which constraint each value was satisfying.
//
// Usage:
//   dart tool/derive_palette.dart                 # verify + print the report
//   dart -Demit=true tool/derive_palette.dart \
//     > packages/ui/tokens/lib/src/bge_color_schemes.dart
//
// After regenerating, run the token tests — they are the authority, since they
// use Flutter's own `Color.computeLuminance` rather than the copy here:
//   melos run test --scope=ui_tokens
//   melos run goldens:update
//
// ── How it works ───────────────────────────────────────────────────────
//
// Each role has a fixed OKLCH hue and chroma — those carry the identity — and
// its lightness is solved numerically for an exact WCAG contrast target. OKLCH
// rather than HSL because it is perceptually uniform: holding chroma constant
// across a hue sweep actually looks constant, which HSL does not give you.
//
// Design rules encoded here:
//  - Hue and chroma ARE the identity; lightness is solved for contrast.
//  - Accents target just-above-minimum against surface, which keeps them
//    saturated (electric) rather than washed toward white. Raising these
//    targets to "improve" contrast will desaturate the palette.
//  - on-* roles target comfortably ABOVE minimum, so they read crisp — but not
//    so far above that the solver clamps them to pure black or white.
//  - Ember (tertiary) and error are held ~54° apart in hue deliberately. That
//    separation is the palette's one genuine weak point and is asserted by
//    `bge_color_schemes_test.dart`.

import 'dart:io';
import 'dart:math' as math;

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _linearToSrgb(double c) => c <= 0.0031308
    ? c * 12.92
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

double luminance(int rgb) {
  final r = _srgbToLinear(((rgb >> 16) & 0xFF) / 255);
  final g = _srgbToLinear(((rgb >> 8) & 0xFF) / 255);
  final b = _srgbToLinear((rgb & 0xFF) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double contrast(int a, int b) {
  final la = luminance(a), lb = luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

int? oklchToRgb(double L, double C, double hDeg) {
  final h = hDeg * math.pi / 180;
  final a = C * math.cos(h), bb = C * math.sin(h);
  final l_ = L + 0.3963377774 * a + 0.2158037573 * bb;
  final m_ = L - 0.1055613458 * a - 0.0638541728 * bb;
  final s_ = L - 0.0894841775 * a - 1.2914855480 * bb;
  final l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  final lr = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  final lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  final lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
  const eps = 0.001;
  if (lr < -eps || lg < -eps || lb < -eps) return null;
  if (lr > 1 + eps || lg > 1 + eps || lb > 1 + eps) return null;
  int ch(double v) =>
      (_linearToSrgb(v.clamp(0.0, 1.0)) * 255).round().clamp(0, 255);
  return (ch(lr) << 16) | (ch(lg) << 8) | ch(lb);
}

/// Approximate OKLCH hue of an sRGB colour (for the separation check).
double rgbToOklchHue(int rgb) {
  final r = _srgbToLinear(((rgb >> 16) & 0xFF) / 255);
  final g = _srgbToLinear(((rgb >> 8) & 0xFF) / 255);
  final b = _srgbToLinear((rgb & 0xFF) / 255);
  final l = math
      .pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3)
      .toDouble();
  final m = math
      .pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3)
      .toDouble();
  final s = math
      .pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3)
      .toDouble();
  final A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  final B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  var h = math.atan2(B, A) * 180 / math.pi;
  if (h < 0) h += 360;
  return h;
}

double hueDelta(int a, int b) {
  final d = (rgbToOklchHue(a) - rgbToOklchHue(b)).abs();
  return d > 180 ? 360 - d : d;
}

double maxChroma(double L, double hue) {
  var lo = 0.0, hi = 0.45;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (oklchToRgb(L, mid, hue) != null) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Solves lightness so the colour hits [target] contrast against [bg].
/// [lighter] chooses which side of [bg] to search.
int solve(
  double hue,
  double chroma,
  int bg,
  double target, {
  required bool lighter,
}) {
  var best = lighter ? 0xFFFFFF : 0x000000;
  var bestErr = double.infinity;
  final bgLum = luminance(bg);
  for (var i = 0; i <= 1000; i++) {
    final L = i / 1000;
    final c = math.min(chroma, maxChroma(L, hue));
    final rgb = oklchToRgb(L, c, hue);
    if (rgb == null) continue;
    final lum = luminance(rgb);
    if (lighter && lum <= bgLum) continue;
    if (!lighter && lum >= bgLum) continue;
    final ratio = contrast(rgb, bg);
    if (ratio >= target) {
      final err = ratio - target;
      if (err < bestErr) {
        bestErr = err;
        best = rgb;
      }
    }
  }
  return best;
}

String hex(int rgb) =>
    '#${rgb.toRadixString(16).toUpperCase().padLeft(6, '0')}';
String dart(int rgb) =>
    '0xFF${rgb.toRadixString(16).toUpperCase().padLeft(6, '0')}';

// ── Identity: the hues ─────────────────────────────────────────────────
const hBlue = 252.0; // electric blue — the strike
const hViolet = 303.0; // storm violet
const hEmber = 68.0; // ember orange — kept genuinely orange, not gold
const hRed = 14.0; // error — pushed toward crimson to buy the separation
// that ember would otherwise have had to give up
const hWalnut = 62.0; // warm earth; very low chroma on surfaces

class Scheme {
  Scheme(this.name, this.isDark, this.min);
  final String name;
  final bool isDark;
  final double min;
  final Map<String, int> v = {};

  void report() {
    final pairs = <String, (int, int)>{
      'onPrimary/primary': (v['onPrimary']!, v['primary']!),
      'onPrimaryContainer/primaryContainer': (
        v['onPrimaryContainer']!,
        v['primaryContainer']!,
      ),
      'onSecondary/secondary': (v['onSecondary']!, v['secondary']!),
      'onSecondaryContainer/secondaryContainer': (
        v['onSecondaryContainer']!,
        v['secondaryContainer']!,
      ),
      'onTertiary/tertiary': (v['onTertiary']!, v['tertiary']!),
      'onTertiaryContainer/tertiaryContainer': (
        v['onTertiaryContainer']!,
        v['tertiaryContainer']!,
      ),
      'onError/error': (v['onError']!, v['error']!),
      'onErrorContainer/errorContainer': (
        v['onErrorContainer']!,
        v['errorContainer']!,
      ),
      'onSurface/surface': (v['onSurface']!, v['surface']!),
      'onSurfaceVariant/surface': (v['onSurfaceVariant']!, v['surface']!),
      'onInverseSurface/inverseSurface': (
        v['onInverseSurface']!,
        v['inverseSurface']!,
      ),
    };
    var ok = true;
    final worst = <String, double>{};
    pairs.forEach((k, p) {
      final r = contrast(p.$1, p.$2);
      worst[k] = r;
      if (r < min) ok = false;
    });
    final lowest = worst.entries.reduce((a, b) => a.value < b.value ? a : b);
    print(
      '$name  target ${min.toStringAsFixed(1)}:1  '
      '${ok ? "ALL PASS" : "*** FAIL ***"}  '
      '(tightest: ${lowest.key} ${lowest.value.toStringAsFixed(2)}:1)',
    );
    if (!ok) {
      pairs.forEach((k, p) {
        final r = contrast(p.$1, p.$2);
        if (r < min) print('    FAIL $k ${r.toStringAsFixed(2)}:1');
      });
    }

    // Accents must also read on the surface — they're used for icons/labels.
    for (final role in ['primary', 'secondary', 'tertiary', 'error']) {
      final r = contrast(v[role]!, v['surface']!);
      if (r < 4.5) {
        print('    WARN $role on surface only ${r.toStringAsFixed(2)}:1');
      }
    }
    // Body text sits on the containers too, not just on `surface`.
    for (final c in [
      'surfaceDim',
      'surfaceBright',
      'surfaceContainerLowest',
      'surfaceContainerLow',
      'surfaceContainer',
      'surfaceContainerHigh',
      'surfaceContainerHighest',
    ]) {
      final r1 = contrast(v['onSurface']!, v[c]!);
      final r2 = contrast(v['onSurfaceVariant']!, v[c]!);
      if (r1 < min) {
        print('    FAIL onSurface/$c ${r1.toStringAsFixed(2)}:1');
      }
      if (r2 < min) {
        print('    FAIL onSurfaceVariant/$c ${r2.toStringAsFixed(2)}:1');
      }
    }
    final hd = hueDelta(v['tertiary']!, v['error']!);
    print('    ember/error hue separation: ${hd.toStringAsFixed(1)}°');
  }

  /// Emits the `ColorScheme` body as compilable Dart.
  String emit(String fieldName, String brightness, String doc) {
    final b = StringBuffer()
      ..writeln('  $doc')
      ..writeln('  static const ColorScheme $fieldName = ColorScheme(')
      ..writeln('    brightness: Brightness.$brightness,');
    for (final k in _order) {
      b.writeln('    $k: Color(${dart(v[k]!)}),');
    }
    b.writeln('  );');
    return b.toString();
  }

  static const _order = [
    'primary',
    'onPrimary',
    'primaryContainer',
    'onPrimaryContainer',
    'secondary',
    'onSecondary',
    'secondaryContainer',
    'onSecondaryContainer',
    'tertiary',
    'onTertiary',
    'tertiaryContainer',
    'onTertiaryContainer',
    'error',
    'onError',
    'errorContainer',
    'onErrorContainer',
    'surface',
    'onSurface',
    'onSurfaceVariant',
    'outline',
    'outlineVariant',
    'surfaceDim',
    'surfaceBright',
    'surfaceContainerLowest',
    'surfaceContainerLow',
    'surfaceContainer',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
    'inverseSurface',
    'onInverseSurface',
    'inversePrimary',
    'scrim',
    'surfaceTint',
  ];

  void dump() {
    print('\n  // $name');
    for (final k in [
      'primary',
      'onPrimary',
      'primaryContainer',
      'onPrimaryContainer',
      'secondary',
      'onSecondary',
      'secondaryContainer',
      'onSecondaryContainer',
      'tertiary',
      'onTertiary',
      'tertiaryContainer',
      'onTertiaryContainer',
      'error',
      'onError',
      'errorContainer',
      'onErrorContainer',
      'surface',
      'onSurface',
      'onSurfaceVariant',
      'outline',
      'outlineVariant',
      'surfaceDim',
      'surfaceBright',
      'surfaceContainerLowest',
      'surfaceContainerLow',
      'surfaceContainer',
      'surfaceContainerHigh',
      'surfaceContainerHighest',
      'inverseSurface',
      'onInverseSurface',
      'inversePrimary',
      'scrim',
      'surfaceTint',
    ]) {
      print('  ${k.padRight(22)} Color(${dart(v[k]!)}),');
    }
  }
}

/// Builds a scheme. [aa] is the authored-pair floor (4.5 or 7.0).
Scheme build(
  String name, {
  required bool dark,
  required double aa,
  required bool hc,
}) {
  final s = Scheme(name, dark, aa);
  // Surface anchors the whole scheme.
  final surface = dark
      ? (hc ? 0x000000 : oklchToRgb(0.190, 0.014, hWalnut)!)
      : (hc ? 0xFFFFFF : oklchToRgb(0.975, 0.008, hWalnut)!);
  s.v['surface'] = surface;

  // Accent-on-surface target: just above the floor keeps chroma high, which
  // is what makes the blue read as "electric" rather than pastel.
  final accentTarget = hc ? 7.2 : 5.5;
  // on-accent: high enough to be crisp, low enough that the solver can pick a
  // TINTED dark/light rather than clamping to pure black or white.
  final onAccentTarget = hc ? 7.2 : 5.5;
  // on-container: containers sit near the surface, so there is headroom here.
  final onContainerTarget = hc ? 8.5 : 7.0;

  int accent(double hue, double chroma) =>
      solve(hue, chroma, surface, accentTarget, lighter: dark);
  int onOf(double hue, double chroma, int bg) =>
      solve(hue, chroma, bg, onAccentTarget, lighter: !dark);

  s.v['primary'] = accent(hBlue, hc ? 0.20 : 0.17);
  s.v['secondary'] = accent(hViolet, hc ? 0.18 : 0.15);
  s.v['tertiary'] = accent(hEmber, hc ? 0.16 : 0.14);
  s.v['error'] = accent(hRed, hc ? 0.20 : 0.18);

  s.v['onPrimary'] = onOf(hBlue, 0.10, s.v['primary']!);
  s.v['onSecondary'] = onOf(hViolet, 0.10, s.v['secondary']!);
  s.v['onTertiary'] = onOf(hEmber, 0.10, s.v['tertiary']!);
  s.v['onError'] = onOf(hRed, 0.12, s.v['error']!);

  // Containers sit close to the surface; their on-roles carry the contrast.
  // Deliberately NOT separated from the surface in high contrast: pushing the
  // container away from the surface eats the headroom its on-role needs, which
  // is exactly what made the 7:1 variants unsatisfiable on the first pass.
  int container(double hue, double chroma) => solve(
    hue,
    chroma,
    surface,
    dark ? (hc ? 2.1 : 1.9) : (hc ? 1.4 : 1.35),
    lighter: dark,
  );
  int onContainer(double hue, double chroma, int bg) =>
      solve(hue, chroma, bg, onContainerTarget, lighter: dark);

  s.v['primaryContainer'] = container(hBlue, 0.11);
  s.v['onPrimaryContainer'] = onContainer(
    hBlue,
    0.10,
    s.v['primaryContainer']!,
  );
  s.v['secondaryContainer'] = container(hViolet, 0.10);
  s.v['onSecondaryContainer'] = onContainer(
    hViolet,
    0.09,
    s.v['secondaryContainer']!,
  );
  s.v['tertiaryContainer'] = container(hEmber, 0.10);
  s.v['onTertiaryContainer'] = onContainer(
    hEmber,
    0.09,
    s.v['tertiaryContainer']!,
  );
  s.v['errorContainer'] = container(hRed, 0.12);
  s.v['onErrorContainer'] = onContainer(hRed, 0.10, s.v['errorContainer']!);

  // Surface containers: elevation expressed as warm tone steps, all on the
  // walnut hue so stacked surfaces stay in the same family.
  final surfaceL = dark ? 0.190 : 0.975;
  int tone(double delta) {
    final L = (surfaceL + (dark ? delta : -delta)).clamp(0.0, 1.0);
    return oklchToRgb(L, 0.014, hWalnut) ?? (dark ? 0x000000 : 0xFFFFFF);
  }

  // Elevation ramp: "higher" means lighter in dark themes and darker in light
  // themes, which is what `tone`'s sign flip encodes.
  s.v['surfaceContainerLowest'] = tone(-0.030);
  s.v['surfaceContainerLow'] = tone(0.022);
  s.v['surfaceContainer'] = tone(0.040);
  s.v['surfaceContainerHigh'] = tone(0.062);
  s.v['surfaceContainerHighest'] = tone(0.086);

  // Dim/Bright are ABSOLUTE, not elevation steps: surfaceDim is the dimmest
  // member of the family in BOTH brightnesses and surfaceBright the brightest.
  // Generating them from the elevation ramp inverts them in light themes —
  // which is how `surfaceDim` first came out pure white.
  int absTone(double L) =>
      oklchToRgb(L, 0.014, hWalnut) ?? (L < 0.5 ? 0x000000 : 0xFFFFFF);
  s.v['surfaceDim'] = dark ? absTone(0.160) : absTone(0.880);
  s.v['surfaceBright'] = dark ? absTone(0.310) : absTone(0.995);

  s.v['outlineVariant'] = solve(
    hWalnut,
    0.016,
    surface,
    hc ? 2.4 : 1.7,
    lighter: dark,
  );

  // Solve the on-surface roles against the HARDEST background in the family,
  // not against `surface`. Text sits on containers as often as on the bare
  // surface, and solving against `surface` alone leaves the top containers
  // failing while the authored-pair test still reports green.
  // Hardest = the member closest in luminance to the text: the lightest
  // surface in a dark theme, the darkest surface in a light theme.
  final family = [
    s.v['surface']!,
    s.v['surfaceDim']!,
    s.v['surfaceBright']!,
    s.v['surfaceContainerLowest']!,
    s.v['surfaceContainerLow']!,
    s.v['surfaceContainer']!,
    s.v['surfaceContainerHigh']!,
    s.v['surfaceContainerHighest']!,
  ];
  family.sort((a, b) => luminance(a).compareTo(luminance(b)));
  final worstBg = dark ? family.last : family.first;
  s.v['onSurface'] = solve(
    hWalnut,
    0.016,
    worstBg,
    hc ? 15.0 : 12.0,
    lighter: dark,
  );
  s.v['onSurfaceVariant'] = solve(
    hWalnut,
    0.020,
    worstBg,
    hc ? math.max(aa, 7.4) : 5.0,
    lighter: dark,
  );
  s.v['outline'] = solve(
    hWalnut,
    0.018,
    worstBg,
    hc ? 7.2 : 4.6,
    lighter: dark,
  );

  // Authored rather than left to ColorScheme's default (opaque neutral
  // black). A scrim over a warm palette should be warm — a neutral black
  // veil over cream reads cold. Alpha is applied at the call site.
  s.v['scrim'] = absTone(0.04);
  // The tint M3 blends into elevated surfaces; primary keeps elevation
  // reading as part of the identity rather than as grey.
  s.v['surfaceTint'] = s.v['primary']!;

  s.v['inverseSurface'] = solve(hWalnut, 0.014, surface, 12.5, lighter: dark);
  s.v['onInverseSurface'] = solve(
    hWalnut,
    0.014,
    s.v['inverseSurface']!,
    12.5,
    lighter: !dark,
  );
  // inversePrimary: the primary of the opposite brightness.
  s.v['inversePrimary'] = solve(
    hBlue,
    0.17,
    dark
        ? oklchToRgb(0.975, 0.008, hWalnut)!
        : oklchToRgb(0.190, 0.014, hWalnut)!,
    5.2,
    lighter: !dark,
  );
  return s;
}

void main() {
  final schemes = [
    build('dark             ', dark: true, aa: 4.5, hc: false),
    build('light            ', dark: false, aa: 4.5, hc: false),
    build('highContrastDark ', dark: true, aa: 7.0, hc: true),
    build('highContrastLight', dark: false, aa: 7.0, hc: true),
  ];
  if (!emitMode) {
    for (final s in schemes) {
      s.report();
    }
  }
  if (!emitMode) {
    for (final s in schemes) {
      s.dump();
    }
    return;
  }

  final out = StringBuffer()
    ..writeln("import 'package:flutter/material.dart';")
    ..writeln()
    ..writeln('/// The four authored [ColorScheme]s of the "storm over walnut"')
    ..writeln('/// identity (#32) — the default `BgePalette`.')
    ..writeln('///')
    ..writeln(
      '/// Hand-authored rather than `ColorScheme.fromSeed`: seed generation',
    )
    ..writeln(
      '/// does not guarantee WCAG contrast, and the project target (2.1 AA)',
    )
    ..writeln(
      '/// is test-enforced. Every authored on-role/role pair holds ≥ 4.5:1 in',
    )
    ..writeln(
      '/// [light]/[dark] and ≥ 7.0:1 in the high-contrast variants (see',
    )
    ..writeln('/// `bge_color_schemes_test.dart`).')
    ..writeln('///')
    ..writeln('/// ## How these values were produced')
    ..writeln('///')
    ..writeln(
      '/// Not picked by eye. Each role has a fixed OKLCH **hue** and **chroma**',
    )
    ..writeln(
      '/// — those carry the identity — and its **lightness** was solved',
    )
    ..writeln(
      '/// numerically for an exact contrast target. Consequences worth knowing',
    )
    ..writeln('/// before editing any value here:')
    ..writeln('///')
    ..writeln(
      '/// - Accents target only slightly above the 4.5:1 floor **on purpose**.',
    )
    ..writeln(
      '///   Pushing them lighter to "improve" contrast desaturates them, and',
    )
    ..writeln('///   the electric blue stops reading as electric.')
    ..writeln(
      '/// - `onSurface`/`onSurfaceVariant`/`outline` are solved against the',
    )
    ..writeln(
      '///   HARDEST member of the surface family (the lightest surface in a',
    )
    ..writeln('///   dark scheme, the darkest in a light one) — not against')
    ..writeln(
      '///   [ColorScheme.surface]. Text sits on the containers too, and',
    )
    ..writeln(
      '///   solving against the bare surface leaves the top containers failing',
    )
    ..writeln('///   while the authored-pair test still reports green.')
    ..writeln(
      '/// - [ColorScheme.surfaceDim]/[ColorScheme.surfaceBright] are ABSOLUTE',
    )
    ..writeln(
      '///   (dimmest/brightest in both brightnesses), not elevation steps.',
    )
    ..writeln(
      '/// - `tertiary` (ember) and `error` (crimson) are held ~54° apart in',
    )
    ..writeln(
      '///   OKLCH hue. That separation is load-bearing and is asserted by',
    )
    ..writeln(
      '///   `bge_color_schemes_test.dart`; it is the one pair in this palette',
    )
    ..writeln('///   that can otherwise collapse into "some warm colour".')
    ..writeln('///')
    ..writeln(
      '/// Only the authored pairs carry the contrast guarantee, so widgets',
    )
    ..writeln(
      '/// should pair on-roles with their own role (`onPrimary` on `primary`,',
    )
    ..writeln('/// never `onPrimary` on `surface`).')
    ..writeln('abstract final class BgeColorSchemes {');

  final docs = {
    'light':
        '/// Light scheme; authored pairs ≥ 4.5:1 (WCAG 2.1 AA, normal text).',
    'dark':
        '/// Dark scheme — the **reference** the identity was authored against;\n'
        '  /// authored pairs ≥ 4.5:1 (WCAG 2.1 AA, normal text).',
    'highContrastLight':
        '/// High-contrast light scheme; authored pairs ≥ 7.0:1.',
    'highContrastDark':
        '/// High-contrast dark scheme; authored pairs ≥ 7.0:1.',
  };
  final order = {
    'light': ('light', 'light'),
    'dark': ('dark', 'dark'),
    'highContrastLight': ('highContrastLight', 'light'),
    'highContrastDark': ('highContrastDark', 'dark'),
  };
  for (final e in order.entries) {
    final s = schemes.firstWhere((x) => x.name.trim() == e.key);
    out
      ..writeln()
      ..write(s.emit(e.value.$1, e.value.$2, docs[e.key]!));
  }
  out.writeln('}');
  stdout.write(out);
}

const emitMode = bool.fromEnvironment('emit');
