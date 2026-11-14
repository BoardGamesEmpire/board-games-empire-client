import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:network_interface/network_interface.dart';

import 'package:profile/src/bloc/profile_event.dart';
import 'package:profile/src/bloc/profile_state.dart';

/// Drives "Your profile" (#547): reads the caller's own profile, then saves
/// the changes the form hands it.
///
/// Online only: nothing is cached, so every open reads again.
///
/// - **The read.** A profile the server doesn't have yet is
///   [ProfileLoadStatus.notReady]; anything else that doesn't land is
///   [ProfileLoadStatus.failed], and [ProfileRetried] reads again. A read
///   asked for while another is out replaces it, so an earlier read that
///   answers later never lands.
/// - **A save.** One at a time: a [ProfileSaveRequested] while one is out
///   is dropped, as is an empty patch. A save that lands takes the server's
///   answer as the profile, which is what the server stored: trimmed, and
///   its bio sanitized. A failed save keeps the profile, so the form keeps
///   what was typed. A save the server answers with no profile is
///   [ProfileLoadStatus.notReady], as a read so answered is: the screen
///   then offers to read again rather than to save again. So is a save
///   answered with a success this client can't read, which is
///   [ProfileLoadStatus.failed]: the server stored the values, so the save
///   didn't fail, but what it stored is unknown.
/// - **Refused values.** A 400 is [ProfileSaveFailure.rejected], and so is
///   the [ArgumentError] the remote throws before sending, which is also
///   reported as an error: the form checks what the remote does, so it is
///   a bug, and the user can still only change the values.
/// - **The session.** On web every tab shares one session cookie, and a
///   sign-in in another tab can move it to another user under this screen
///   (#432). The save goes to whoever the session is, so [_confirmSession]
///   is asked before it goes out. A no, or a throw, sends nothing and is
///   [ProfileSaveFailure.failed]. Null, as on native, is always yes.
/// - **Outcomes.** A save's outcome, saved or failed, stays until the next
///   [ProfileEdited] or save.
class ProfileBloc extends Bloc<ProfileEvent, ProfileState> {
  ProfileBloc({required this._remote, this._confirmSession})
    : super(const ProfileState()) {
    on<ProfileReadEvent>(_onRead, transformer: restartable());
    on<ProfileSaveRequested>(_onSaveRequested, transformer: droppable());
    on<ProfileEdited>(_onEdited);
  }

  final UserProfileRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;

  Future<void> _onRead(
    ProfileReadEvent event,
    Emitter<ProfileState> emit,
  ) async {
    emit(const ProfileState());
    try {
      final profile = await _remote.fetchOwn();
      emit(ProfileState(status: ProfileLoadStatus.loaded, profile: profile));
    } on UserProfileNotFoundException {
      emit(const ProfileState(status: ProfileLoadStatus.notReady));
    } on Object {
      emit(const ProfileState(status: ProfileLoadStatus.failed));
    }
  }

  Future<void> _onSaveRequested(
    ProfileSaveRequested event,
    Emitter<ProfileState> emit,
  ) async {
    if (state.status != ProfileLoadStatus.loaded || event.patch.isEmpty) {
      return;
    }
    emit(state.copyWith(saving: true, saved: false, saveFailure: () => null));
    try {
      final confirm = _confirmSession;
      if (confirm != null && !await confirm()) {
        emit(
          state.copyWith(
            saving: false,
            saveFailure: () => ProfileSaveFailure.failed,
          ),
        );
        return;
      }
      final profile = await _remote.updateOwn(event.patch);
      emit(state.copyWith(profile: profile, saving: false, saved: true));
    } on UserProfileNotFoundException {
      emit(const ProfileState(status: ProfileLoadStatus.notReady));
    } on Object catch (error, stackTrace) {
      if (error is UserProfileRemoteException && _answeredOk(error)) {
        emit(const ProfileState(status: ProfileLoadStatus.failed));
        return;
      }
      if (error is ArgumentError) addError(error, stackTrace);
      final failure = switch (error) {
        UserProfilePermanentException() ||
        ArgumentError() => ProfileSaveFailure.rejected,
        UserProfileRefusedException() => ProfileSaveFailure.refused,
        _ => ProfileSaveFailure.failed,
      };
      emit(state.copyWith(saving: false, saveFailure: () => failure));
    }
  }

  /// Whether [error] came with a 2xx: the server did what was asked, and
  /// only its answer couldn't be read.
  static bool _answeredOk(UserProfileRemoteException error) {
    final status = error.statusCode;
    return status != null && status >= 200 && status < 300;
  }

  void _onEdited(ProfileEdited event, Emitter<ProfileState> emit) {
    if (!state.saved && state.saveFailure == null) return;
    emit(state.copyWith(saved: false, saveFailure: () => null));
  }
}
