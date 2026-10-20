import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_summary.freezed.dart';

/// Another user as the server embeds them in someone else's record: an
/// invite's sender, or a user search result (#455).
///
/// Read from the server when a screen opens and never stored on the device.
@freezed
abstract class UserSummary with _$UserSummary {
  const UserSummary._();

  const factory UserSummary({
    required String id,
    required String username,

    /// From the user's profile, which may be absent.
    String? displayName,
  }) = _UserSummary;

  /// What to call this user on screen.
  String get label => displayName ?? username;
}
