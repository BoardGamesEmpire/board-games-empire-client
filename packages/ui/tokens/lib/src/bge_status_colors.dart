import 'package:flutter/material.dart';

/// Colors for the app's **domain** states — sync, connectivity, ownership —
/// as distinct from Material's UI roles (#32).
///
/// ## Why these are not just the M3 accent roles
///
/// The collection and sync surfaces (#47, #49) need to show "saved", "waiting
/// to sync", "offline", "conflict". The tempting shortcut is to reach for
/// `tertiary` for one and `secondary` for another. Don't: those roles mean
/// *visual emphasis*, not domain meaning. Overloading them couples a
/// re-theming decision to a semantics decision, so changing the accent to make
/// a button feel right silently changes what "pending" looks like — and the
/// two will drift apart the moment a palette changes.
///
/// Naming them here also makes the palette's one real risk explicit: `pending`
/// is ember, and ember sits near `error` crimson. They are held apart in hue
/// (see `Oklch.minAccentSeparation`), and the icon-pairing rule below is the
/// second line of defence.
///
/// ## The icon rule is not optional
///
/// **Every use of these colors must be paired with an icon or text.** This is
/// the project's stated answer to color-vision deficiency — no per-CVD
/// palettes, no color-only meaning — and status indicators are exactly where
/// that rule is most often broken, because a colored dot is such an easy thing
/// to build. A colored dot alone is not an acceptable status indicator here.
/// [iconFor] exists so the pairing is the path of least resistance.
///
/// Consumed via `BgeStatusColors.of(context)`; installed on every `BgeTheme`.
@immutable
class BgeStatusColors extends ThemeExtension<BgeStatusColors> {
  /// Creates a status color set. Prefer [BgeStatusColors.forScheme].
  const BgeStatusColors({
    required this.synced,
    required this.pending,
    required this.offline,
    required this.conflict,
    required this.onStatus,
  });

  /// Derives the status colors from a [ColorScheme].
  ///
  /// Deliberately derived rather than authored as fresh constants: these must
  /// track the palette, and a second hand-authored color table would be a
  /// second thing to keep WCAG-verified. Each maps onto a role whose contrast
  /// is already guaranteed against the surface family.
  factory BgeStatusColors.forScheme(ColorScheme scheme) => BgeStatusColors(
    // Settled state — the calm, structural accent.
    synced: scheme.secondary,
    // In-flight — ember, the palette's "look here" accent.
    pending: scheme.tertiary,
    // Not a fault, just a fact: reuses the muted on-surface role rather than
    // an accent, because offline is the app working as designed (offline-first)
    // and must not read as an alarm.
    offline: scheme.onSurfaceVariant,
    // Needs the user — the only status that borrows the error role.
    conflict: scheme.error,
    onStatus: scheme.surface,
  );

  /// Local state matches the server.
  final Color synced;

  /// A local change is queued and not yet acknowledged by the server.
  final Color pending;

  /// The server is unreachable; cached data is being shown.
  final Color offline;

  /// A change needs the user to resolve it.
  final Color conflict;

  /// Foreground for a filled status chip.
  final Color onStatus;

  /// The ambient status colors, or a set derived from the ambient
  /// [ColorScheme] when no theme provides them.
  ///
  /// The fallback mirrors `BgeTokens.of` — a widget test pumping a bare
  /// `MaterialApp` still gets a coherent, correctly-derived set.
  // `X.of(context)` is the Flutter idiom for an ambient lookup and reads as
  // one at every call site; a constructor named `fromContext` would satisfy
  // the lint and surprise every reader.
  // ignore: prefer_constructors_over_static_methods
  static BgeStatusColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<BgeStatusColors>() ??
        BgeStatusColors.forScheme(theme.colorScheme);
  }

  /// The icon that must accompany each status.
  ///
  /// Centralized so the same state looks the same everywhere, and so the
  /// icon-pairing rule is easier to follow than to break.
  static IconData iconFor(BgeStatus status) => switch (status) {
    BgeStatus.synced => Icons.cloud_done_outlined,
    BgeStatus.pending => Icons.cloud_upload_outlined,
    BgeStatus.offline => Icons.cloud_off_outlined,
    BgeStatus.conflict => Icons.error_outline,
  };

  /// The color for [status].
  Color colorFor(BgeStatus status) => switch (status) {
    BgeStatus.synced => synced,
    BgeStatus.pending => pending,
    BgeStatus.offline => offline,
    BgeStatus.conflict => conflict,
  };

  @override
  BgeStatusColors copyWith({
    Color? synced,
    Color? pending,
    Color? offline,
    Color? conflict,
    Color? onStatus,
  }) => BgeStatusColors(
    synced: synced ?? this.synced,
    pending: pending ?? this.pending,
    offline: offline ?? this.offline,
    conflict: conflict ?? this.conflict,
    onStatus: onStatus ?? this.onStatus,
  );

  @override
  BgeStatusColors lerp(ThemeExtension<BgeStatusColors>? other, double t) {
    if (other is! BgeStatusColors) return this;
    return BgeStatusColors(
      synced: Color.lerp(synced, other.synced, t)!,
      pending: Color.lerp(pending, other.pending, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
      conflict: Color.lerp(conflict, other.conflict, t)!,
      onStatus: Color.lerp(onStatus, other.onStatus, t)!,
    );
  }
}

/// The domain states [BgeStatusColors] covers.
enum BgeStatus {
  /// Local state matches the server.
  synced,

  /// A local change is queued.
  pending,

  /// The server is unreachable; cached data is shown.
  offline,

  /// A change needs the user to resolve it.
  conflict,
}
