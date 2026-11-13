import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// A group of settings that is saved on its own (#807).
enum SettingsGroup { mail, signIn }

/// Why a save of one group did not land.
enum SettingsSaveFailure {
  /// The patch was empty, so nothing was sent.
  nothingChanged,

  /// The server wants a password with the new mail server.
  passwordRequired,

  /// The server refused the caller (403).
  refused,

  /// The server refused the values, and sending them again won't change that.
  rejected,

  /// No usable answer, or any other failure.
  failed,
}

/// States of `ServerSettingsBloc`.
sealed class ServerSettingsState extends Equatable {
  const ServerSettingsState();

  @override
  List<Object?> get props => [];
}

/// The settings are being read.
final class ServerSettingsLoading extends ServerSettingsState {
  const ServerSettingsLoading();
}

/// The read failed for a reason other than the caller's role.
final class ServerSettingsLoadFailed extends ServerSettingsState {
  const ServerSettingsLoadFailed();
}

/// The server refused the read.
final class ServerSettingsDenied extends ServerSettingsState {
  const ServerSettingsDenied();
}

/// The settings were read.
final class ServerSettingsLoaded extends ServerSettingsState {
  const ServerSettingsLoaded({
    required this.settings,
    required this.mayUpdate,
    required this.accessKnown,
    required this.revision,
    this.saving,
    this.failures = const {},
    this.savedGroup,
  });

  final SystemSettings settings;

  /// Whether the caller's access allows update. False while the answer is
  /// unknown.
  final bool mayUpdate;

  /// Whether the caller's access has answered.
  final bool accessKnown;

  /// The group being saved, if any.
  final SettingsGroup? saving;

  /// Why each group's last save did not land, until that group is edited.
  final Map<SettingsGroup, SettingsSaveFailure> failures;

  /// The group whose last save landed, until that group is edited or saved
  /// again.
  final SettingsGroup? savedGroup;

  /// Moves on every read and every save that landed. A form takes the
  /// settings' values again when it changes.
  final int revision;

  ServerSettingsLoaded copyWith({
    SystemSettings? settings,
    bool? mayUpdate,
    bool? accessKnown,
    SettingsGroup? Function()? saving,
    Map<SettingsGroup, SettingsSaveFailure>? failures,
    SettingsGroup? Function()? savedGroup,
    int? revision,
  }) => ServerSettingsLoaded(
    settings: settings ?? this.settings,
    mayUpdate: mayUpdate ?? this.mayUpdate,
    accessKnown: accessKnown ?? this.accessKnown,
    saving: saving != null ? saving() : this.saving,
    failures: failures ?? this.failures,
    savedGroup: savedGroup != null ? savedGroup() : this.savedGroup,
    revision: revision ?? this.revision,
  );

  @override
  List<Object?> get props => [
    settings,
    mayUpdate,
    accessKnown,
    saving,
    failures,
    savedGroup,
    revision,
  ];
}
