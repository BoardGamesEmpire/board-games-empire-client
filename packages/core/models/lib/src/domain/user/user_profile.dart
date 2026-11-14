import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/common/reach.dart';

part 'user_profile.freezed.dart';

/// A user's profile as the server shows it to the caller (#547).
///
/// There is no `fromJson`: the remote maps the server's JSON by hand, as it
/// does for `SystemSettings`.
///
/// [dietaryRestrictions], [accessibilityNeeds], [reach] and [isSearchable] are
/// the owner-only fields. The server sends them to the profile's owner and
/// leaves them out for anyone else, so they are null on another user's
/// profile (#540 reads them that way). On the owner's own profile a null text
/// field means "not set"; [reach] and [isSearchable] are then always present.
@freezed
abstract class UserProfile with _$UserProfile {
  const factory UserProfile({
    required String userId,
    required String username,
    required bool willingToTeach,
    required bool openToNewPlayers,
    required bool hostingCapability,
    String? displayName,
    String? avatarUrl,
    String? bio,
    String? pronouns,
    String? location,
    int? preferredPlayerCount,
    String? houseRulesPreference,

    /// Owner-only: null for anyone but the owner.
    String? dietaryRestrictions,

    /// Owner-only: null for anyone but the owner.
    String? accessibilityNeeds,

    /// Owner-only: null for anyone but the owner.
    Reach? reach,

    /// Owner-only: null for anyone but the owner.
    bool? isSearchable,
  }) = _UserProfile;
}
