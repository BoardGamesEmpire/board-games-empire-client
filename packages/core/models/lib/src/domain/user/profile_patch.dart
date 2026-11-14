import 'package:equatable/equatable.dart';

import 'package:models/src/domain/common/reach.dart';
import 'package:models/src/domain/system_settings/system_settings_patch.dart';

/// The changes to the caller's own profile (#547). A null field is left as it
/// is.
///
/// The display name can't be cleared, so it is a plain string. The text fields
/// and [preferredPlayerCount] can be cleared, so they take a [SettingValue]:
/// `SettingValue.set` stores a value and `SettingValue.clear` sends `null`.
final class ProfilePatch extends Equatable {
  const ProfilePatch({
    this.displayName,
    this.bio,
    this.pronouns,
    this.location,
    this.houseRulesPreference,
    this.dietaryRestrictions,
    this.accessibilityNeeds,
    this.preferredPlayerCount,
    this.willingToTeach,
    this.openToNewPlayers,
    this.hostingCapability,
    this.isSearchable,
    this.reach,
  });

  final String? displayName;
  final SettingValue<String>? bio;
  final SettingValue<String>? pronouns;
  final SettingValue<String>? location;
  final SettingValue<String>? houseRulesPreference;
  final SettingValue<String>? dietaryRestrictions;
  final SettingValue<String>? accessibilityNeeds;
  final SettingValue<int>? preferredPlayerCount;
  final bool? willingToTeach;
  final bool? openToNewPlayers;
  final bool? hostingCapability;
  final bool? isSearchable;
  final Reach? reach;

  /// Whether nothing is being changed.
  bool get isEmpty => props.every((field) => field == null);

  @override
  List<Object?> get props => [
    displayName,
    bio,
    pronouns,
    location,
    houseRulesPreference,
    dietaryRestrictions,
    accessibilityNeeds,
    preferredPlayerCount,
    willingToTeach,
    openToNewPlayers,
    hostingCapability,
    isSearchable,
    reach,
  ];
}
