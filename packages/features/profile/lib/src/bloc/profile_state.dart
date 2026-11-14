import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of the caller's profile stands (#547).
enum ProfileLoadStatus {
  /// Being read.
  loading,

  /// Read: `ProfileState.profile` holds it.
  loaded,

  /// The server has no profile for the caller yet.
  notReady,

  /// No usable answer, or any other failure. Also a save the server
  /// answered with a success that couldn't be read: it stored something,
  /// and only a new read says what.
  failed,
}

/// Why a save of the profile did not land.
enum ProfileSaveFailure {
  /// The values were refused, by the server (a 400, or any other permanent
  /// refusal) or by the remote's own checks before sending, and sending them
  /// again won't change that.
  rejected,

  /// The server refused the caller (403).
  refused,

  /// No usable answer, or any other failure.
  failed,
}

/// The state of `ProfileBloc`.
final class ProfileState extends Equatable {
  const ProfileState({
    this.status = ProfileLoadStatus.loading,
    this.profile,
    this.saving = false,
    this.saved = false,
    this.saveFailure,
  });

  final ProfileLoadStatus status;

  /// The profile as the server last sent it: read, or answered by a save.
  /// Set while [status] is [ProfileLoadStatus.loaded].
  final UserProfile? profile;

  /// Whether a save is in flight.
  final bool saving;

  /// Whether the last save landed, until the next edit or save.
  final bool saved;

  /// Why the last save didn't land, until the next edit or save.
  final ProfileSaveFailure? saveFailure;

  ProfileState copyWith({
    ProfileLoadStatus? status,
    UserProfile? profile,
    bool? saving,
    bool? saved,
    ProfileSaveFailure? Function()? saveFailure,
  }) => ProfileState(
    status: status ?? this.status,
    profile: profile ?? this.profile,
    saving: saving ?? this.saving,
    saved: saved ?? this.saved,
    saveFailure: saveFailure != null ? saveFailure() : this.saveFailure,
  );

  @override
  List<Object?> get props => [status, profile, saving, saved, saveFailure];
}
