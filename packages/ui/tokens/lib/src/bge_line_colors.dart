import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

/// The two line colors the app draws between and around content: the
/// [separator] between rows and sections, and the [rowOutline] around a row
/// that is a card (#659).
///
/// ## Why these are derived
///
/// Both roles are read off the [ColorScheme] of whichever palette builds the
/// theme, rather than authored as constants. A palette the user customizes
/// therefore brings its own lines, already held to the contrast the scheme
/// guarantees, and no second color table needs verifying.
///
/// ## What the separator must not be
///
/// `separator` must not be `error`. A rule between rows that reads as a
/// fault tells the user something is wrong where nothing is; it is the
/// neutral `outline` role, which holds 3:1 against every surface in all four
/// schemes.
///
/// Consumed via `BgeLineColors.of(context)`; installed on every `BgeTheme`.
@immutable
class BgeLineColors extends ThemeExtension<BgeLineColors> {
  /// Creates a line color set. Prefer [BgeLineColors.forScheme].
  const BgeLineColors({required this.separator, required this.rowOutline});

  /// Derives the line colors from a [ColorScheme].
  ///
  /// The separator is always `outline`. The row outline is the quieter
  /// `outlineVariant`, except under [highContrast], where it is `outline` so
  /// the row's edge stays as visible as the separator.
  factory BgeLineColors.forScheme(
    ColorScheme scheme, {
    required bool highContrast,
  }) => BgeLineColors(
    separator: scheme.outline,
    rowOutline: highContrast ? scheme.outline : scheme.outlineVariant,
  );

  /// The rule between rows and sections.
  final Color separator;

  /// The outline around a row that is drawn as a card.
  final Color rowOutline;

  /// The ambient line colors, or a set derived from the ambient
  /// [ColorScheme] and the platform's contrast setting when no theme provides
  /// them.
  ///
  /// The fallback mirrors `BgeStatusColors.of`, so a widget test pumping a
  /// bare `MaterialApp` still gets a coherent set.
  // `X.of(context)` is the Flutter idiom for an ambient lookup and reads as
  // one at every call site; a constructor named `fromContext` would satisfy
  // the lint and surprise every reader.
  // ignore: prefer_constructors_over_static_methods
  static BgeLineColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<BgeLineColors>() ??
        BgeLineColors.forScheme(
          theme.colorScheme,
          highContrast: MediaQuery.maybeHighContrastOf(context) ?? false,
        );
  }

  /// Every field, in declaration order: the one list [==] and [hashCode] both
  /// read, as on `BgeStatusColors`.
  List<Object> get _fields => [separator, rowOutline];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BgeLineColors && listEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  @override
  BgeLineColors copyWith({Color? separator, Color? rowOutline}) =>
      BgeLineColors(
        separator: separator ?? this.separator,
        rowOutline: rowOutline ?? this.rowOutline,
      );

  @override
  BgeLineColors lerp(ThemeExtension<BgeLineColors>? other, double t) {
    if (other is! BgeLineColors) return this;
    return BgeLineColors(
      separator: Color.lerp(separator, other.separator, t)!,
      rowOutline: Color.lerp(rowOutline, other.rowOutline, t)!,
    );
  }
}
