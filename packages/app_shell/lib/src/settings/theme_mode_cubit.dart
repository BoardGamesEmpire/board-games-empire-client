import 'package:flutter/material.dart' show ThemeMode;
import 'package:hydrated_bloc/hydrated_bloc.dart';

/// App-level, persisted theme-mode selection (#120; the persistence half
/// of #78) feeding `MaterialApp.themeMode`.
///
/// Deliberately only system / light / dark — the high-contrast variants
/// are an orthogonal accessibility axis selected automatically by the OS
/// via `MaterialApp.highContrastTheme` (#32/#120 Q4), not an in-app mode.
///
/// This is a [HydratedCubit], so it must be constructed only after
/// `HydratedBloc.storage` is initialized. `AppBootstrapCubit` initializes
/// storage during bootstrap before emitting any post-init state, and the
/// shell constructs this lazily on the first such state — never eagerly,
/// which would call [hydrate] before storage exists and throw.
class ThemeModeCubit extends HydratedCubit<ThemeMode> {
  /// Seeds [initialThemeMode] (default [ThemeMode.system]) — the value
  /// used until a stored selection is hydrated, and the fresh-install
  /// default. The embedder/`runBgeApp` value flows in here, so an app can
  /// set the default theme without it being discarded once storage is
  /// ready; a persisted user selection still overrides it.
  ThemeModeCubit({ThemeMode initialThemeMode = ThemeMode.system})
    : super(initialThemeMode);

  /// Records an explicit theme-mode choice; persisted via [toJson].
  void select(ThemeMode mode) => emit(mode);

  @override
  ThemeMode fromJson(Map<String, dynamic> json) {
    final name = json['themeMode'];
    if (name is! String) return ThemeMode.system;
    // Tolerate an unknown/removed value (e.g. a dropped high-contrast
    // mode from an older build) by falling back rather than throwing.
    return ThemeMode.values.asNameMap()[name] ?? ThemeMode.system;
  }

  @override
  Map<String, dynamic>? toJson(ThemeMode state) => {'themeMode': state.name};
}
