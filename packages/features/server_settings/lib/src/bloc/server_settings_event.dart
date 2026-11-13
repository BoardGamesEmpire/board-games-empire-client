import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import 'package:server_settings/src/bloc/server_settings_state.dart';

/// Events of `ServerSettingsBloc`.
sealed class ServerSettingsEvent extends Equatable {
  const ServerSettingsEvent();

  @override
  List<Object?> get props => [];
}

/// The screen opened: read the settings.
final class ServerSettingsStarted extends ServerSettingsEvent {
  const ServerSettingsStarted();
}

/// The user asked to read the settings again after a failed read.
final class ServerSettingsRetried extends ServerSettingsEvent {
  const ServerSettingsRetried();
}

/// The user saved one group of settings with [patch], holding only the
/// fields that changed.
final class ServerSettingsGroupSaved extends ServerSettingsEvent {
  const ServerSettingsGroupSaved(this.group, this.patch);

  final SettingsGroup group;
  final SystemSettingsPatch patch;

  @override
  List<Object?> get props => [group, patch];
}

/// The user edited a field of [group], which retires that group's failure
/// and its "saved" mark: both describe the values being replaced.
final class ServerSettingsGroupEdited extends ServerSettingsEvent {
  const ServerSettingsGroupEdited(this.group);

  final SettingsGroup group;

  @override
  List<Object?> get props => [group];
}

/// The session's caller access changed.
final class ServerSettingsAccessChanged extends ServerSettingsEvent {
  const ServerSettingsAccessChanged();
}
