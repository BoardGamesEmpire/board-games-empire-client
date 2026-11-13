import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:server_settings/src/bloc/server_settings_event.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';

/// Drives the server settings screen (#807): reads the one settings row, and
/// saves it one [SettingsGroup] at a time.
///
/// A save sends the patch it is given, one at a time. An empty patch sends
/// nothing. A save that lands replaces the settings and moves `revision`, so
/// the forms take the server's values again.
///
/// ## Access
///
/// A save is offered while the caller's access, as the server answers it,
/// allows update on system settings (#456). While the answer is unknown, and
/// with no `access` to ask, a save is dropped. The bloc follows `access` as
/// its answer changes. A refusal, on the read or on a save, asks `access`
/// again: it is the server's word that the answer here may be out of date.
class ServerSettingsBloc
    extends Bloc<ServerSettingsEvent, ServerSettingsState> {
  ServerSettingsBloc({
    required this._remote,
    this._access,
  }) : super(const ServerSettingsLoading()) {
    on<ServerSettingsStarted>((_, emit) => _load(emit));
    on<ServerSettingsRetried>((_, emit) => _load(emit));
    on<ServerSettingsGroupSaved>(_onGroupSaved);
    on<ServerSettingsGroupEdited>(_onGroupEdited);
    on<ServerSettingsAccessChanged>(_onAccessChanged);
    _accessChanges = _access?.changes.listen((_) {
      if (!isClosed) add(const ServerSettingsAccessChanged());
    });
  }

  final SystemSettingsRemoteDataSource _remote;
  final CallerAccessRepository? _access;
  StreamSubscription<CallerAccess>? _accessChanges;

  /// Whether the caller's access lets them save now. False while the answer
  /// is unknown, and with no [_access] to ask.
  bool get _mayUpdate =>
      _access?.current.allows(
        ResourceType.systemSetting,
        AccessAction.update,
      ) ??
      false;

  /// Whether the caller's access has answered. False with no [_access] to
  /// ask.
  bool get _accessKnown => _access?.current.isKnown ?? false;

  Future<void> _load(Emitter<ServerSettingsState> emit) async {
    final previous = state;
    emit(const ServerSettingsLoading());
    try {
      final settings = await _remote.fetch();
      emit(
        ServerSettingsLoaded(
          settings: settings,
          mayUpdate: _mayUpdate,
          accessKnown: _accessKnown,
          revision:
              (previous is ServerSettingsLoaded ? previous.revision : 0) + 1,
        ),
      );
    } on SystemSettingsForbiddenException {
      emit(const ServerSettingsDenied());
      unawaited(_access?.refresh());
    } on Object {
      emit(const ServerSettingsLoadFailed());
    }
  }

  Future<void> _onGroupSaved(
    ServerSettingsGroupSaved event,
    Emitter<ServerSettingsState> emit,
  ) async {
    final current = state;
    if (current is! ServerSettingsLoaded ||
        current.saving != null ||
        !_mayUpdate) {
      return;
    }
    final group = event.group;
    // A save of the group that last saved retires its saved mark, so an
    // outcome never shows above an older one.
    final savedGroup = current.savedGroup == group ? () => null : null;
    if (event.patch.isEmpty) {
      emit(
        current.copyWith(
          failures: {
            ...current.failures,
            group: SettingsSaveFailure.nothingChanged,
          },
          savedGroup: savedGroup,
        ),
      );
      return;
    }
    emit(current.copyWith(saving: () => group, savedGroup: savedGroup));
    try {
      final settings = await _remote.update(current.settings.id, event.patch);
      // Access can change while the save is out: build on what the state is
      // now, not on what it was when the save started.
      final latest = state;
      // A read started while the save was out: its answer stands, and this
      // save's outcome is dropped unshown. The screen can't get here: it
      // reads again only on Retry, which shows only after a failed read,
      // when no save can be out.
      if (latest is! ServerSettingsLoaded) return;
      emit(
        latest.copyWith(
          settings: settings,
          saving: () => null,
          failures: {...latest.failures}..remove(group),
          savedGroup: () => group,
          revision: latest.revision + 1,
        ),
      );
    } on Object catch (error) {
      final failure = switch (error) {
        SmtpPasswordRequiredException() => SettingsSaveFailure.passwordRequired,
        SystemSettingsForbiddenException() => SettingsSaveFailure.refused,
        SystemSettingsPermanentException() => SettingsSaveFailure.rejected,
        _ => SettingsSaveFailure.failed,
      };
      if (failure == SettingsSaveFailure.refused) unawaited(_access?.refresh());
      final latest = state;
      // A read started meanwhile, as above.
      if (latest is! ServerSettingsLoaded) return;
      emit(
        latest.copyWith(
          saving: () => null,
          failures: {...latest.failures, group: failure},
        ),
      );
    }
  }

  void _onGroupEdited(
    ServerSettingsGroupEdited event,
    Emitter<ServerSettingsState> emit,
  ) {
    final current = state;
    if (current is! ServerSettingsLoaded) return;
    final hasFailure = current.failures.containsKey(event.group);
    final wasSaved = current.savedGroup == event.group;
    if (!hasFailure && !wasSaved) return;
    emit(
      current.copyWith(
        failures: {...current.failures}..remove(event.group),
        savedGroup: wasSaved ? () => null : null,
      ),
    );
  }

  void _onAccessChanged(
    ServerSettingsAccessChanged event,
    Emitter<ServerSettingsState> emit,
  ) {
    final current = state;
    if (current is! ServerSettingsLoaded) return;
    emit(current.copyWith(mayUpdate: _mayUpdate, accessKnown: _accessKnown));
  }

  @override
  Future<void> close() {
    // Not awaited first, so that the bloc reads as closed from the turn this
    // starts in, as the other blocs here do.
    unawaited(_accessChanges?.cancel());
    return super.close();
  }
}
