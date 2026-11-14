import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Events of `ProfileBloc`.
sealed class ProfileEvent extends Equatable {
  const ProfileEvent();

  @override
  List<Object?> get props => [];
}

/// A request to read the profile: [ProfileStarted] or [ProfileRetried].
///
/// Both go through one handler, so a read asked for while another is out
/// replaces it, and an earlier read that answers later never lands.
sealed class ProfileReadEvent extends ProfileEvent {
  const ProfileReadEvent();
}

/// The screen opened: read the profile.
final class ProfileStarted extends ProfileReadEvent {
  const ProfileStarted();
}

/// The user asked to read the profile again after a read that didn't land.
final class ProfileRetried extends ProfileReadEvent {
  const ProfileRetried();
}

/// The user saved [patch], which holds only the fields that changed.
///
/// One save at a time: a save asked for while another is out is dropped.
final class ProfileSaveRequested extends ProfileEvent {
  const ProfileSaveRequested(this.patch);

  final ProfilePatch patch;

  @override
  List<Object?> get props => [patch];
}

/// The user edited a field, which retires the last save's outcome: it
/// describes values being replaced.
final class ProfileEdited extends ProfileEvent {
  const ProfileEdited();
}
