import 'package:flutter/foundation.dart';
import 'package:models/domain.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';

/// What the screen hands a settings group's form (#807, #894): the settings,
/// where the group's save stands, and where its saves and edits go. Every
/// group's form takes one, so a group adds only what is its own.
final class SettingsGroupBinding {
  const SettingsGroupBinding({
    required this.settings,
    required this.revision,
    required this.maySave,
    required this.saving,
    required this.otherGroupSaving,
    required this.onSave,
    required this.onEdited,
    this.failure,
    this.saved = false,
  });

  /// The settings as the server last sent them.
  final SystemSettings settings;

  /// Moves when [settings] were read again or a save landed.
  final int revision;

  /// Whether the caller may change the settings.
  final bool maySave;

  /// Whether this group's save is in flight.
  final bool saving;

  /// Whether another group's save is in flight. One save at a time.
  final bool otherGroupSaving;

  /// Why this group's last save didn't land, until the group is edited.
  final SettingsSaveFailure? failure;

  /// Whether this group's last save landed, until the group is edited.
  final bool saved;

  /// Gets the patch of what the group changed.
  final void Function(SystemSettingsPatch patch) onSave;

  /// Called on every edit by the user, so the caller can retire an outcome
  /// that describes the values being replaced.
  final VoidCallback onEdited;
}
