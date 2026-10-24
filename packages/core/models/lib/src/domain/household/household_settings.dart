import 'package:freezed_annotation/freezed_annotation.dart';

import 'member_invite_policy.dart';

part 'household_settings.freezed.dart';
part 'household_settings.g.dart';

/// A household's settings, as the server holds them beside the household.
///
/// Only the member invite policy is read today (#476). The server plans more
/// settings for the same object, such as visibility and join policy.
@freezed
abstract class HouseholdSettings with _$HouseholdSettings {
  const factory HouseholdSettings({
    /// Whether members may invite. A policy name this client does not know
    /// deserializes to [MemberInvitePolicy.unknown].
    @JsonKey(unknownEnumValue: MemberInvitePolicy.unknown)
    required MemberInvitePolicy memberInvitePolicy,
  }) = _HouseholdSettings;

  factory HouseholdSettings.fromJson(Map<String, dynamic> json) =>
      _$HouseholdSettingsFromJson(json);
}
