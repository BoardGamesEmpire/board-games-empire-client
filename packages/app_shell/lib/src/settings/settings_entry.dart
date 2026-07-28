import 'package:flutter/widgets.dart';

/// A single user-facing settings control (#120).
///
/// Kept app_shell-local and deliberately minimal: the shell composes
/// entries explicitly for now (only theme + language exist), but the
/// contract is shaped so it can be lifted to a `core/interfaces`
/// `SettingsRegistry` later — feature packages contributing entries —
/// without changing this surface, mirroring `UserDataExportRegistry`.
///
/// Implementations own their own reactivity (e.g. a `BlocBuilder` over the
/// backing cubit); [build] is called from within the settings list.
abstract interface class SettingsEntry {
  /// Stable identifier, used for the entry's [Key] and focus order.
  /// Must be unique within a section.
  String get id;

  /// Builds the entry's control. Called with a context beneath the
  /// settings [Scaffold] and the shell [Localizations].
  Widget build(BuildContext context);
}
