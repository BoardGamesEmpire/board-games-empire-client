import 'package:models/domain.dart';

/// Maps an embedded server user row to [UserSummary]: an invite's inviter, or a
/// user search result (#455, #499).
///
/// Explicit rather than generated, so the mapping reads only what the model
/// holds. The display name is on the profile, which may be absent.
UserSummary userSummaryFromJson(Map<String, dynamic> json) {
  final profile = json['profile'] as Map<String, dynamic>?;
  return UserSummary(
    id: json['id'] as String,
    username: json['username'] as String,
    displayName: profile?['displayName'] as String?,
  );
}
