import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// The names of the profile form's controls (#547), in its one [FormGroup].
abstract final class ProfileControls {
  static const displayName = 'displayName';
  static const pronouns = 'pronouns';
  static const location = 'location';
  static const bio = 'bio';
  static const willingToTeach = 'willingToTeach';
  static const openToNewPlayers = 'openToNewPlayers';
  static const hostingCapability = 'hostingCapability';
  static const preferredPlayerCount = 'preferredPlayerCount';
  static const houseRules = 'houseRules';
  static const dietaryRestrictions = 'dietaryRestrictions';
  static const accessibilityNeeds = 'accessibilityNeeds';
  static const reach = 'reach';
  static const isSearchable = 'isSearchable';
}

/// The errors the profile form's checks set (#547).
abstract final class ProfileErrors {
  /// On a display name emptied when one was set: the server doesn't clear
  /// it.
  static const blank = 'blank';

  /// On a changed text longer than the server takes. Its value is the cap.
  static const tooLong = 'tooLong';

  /// On a changed preferred player count that isn't a whole number in the
  /// server's range.
  static const playerCount = 'playerCount';
}

/// The form's values for [profile], as its controls hold them.
///
/// Text shows as stored, and an unset one as empty; the player count is
/// text, as its field edits it. A reach this app doesn't know shows as no
/// choice ([Reach.unknown] is never offered), so it is never sent back.
Map<String, Object?> profileValuesOf(UserProfile profile) => {
  ProfileControls.displayName: profile.displayName ?? '',
  ProfileControls.pronouns: profile.pronouns ?? '',
  ProfileControls.location: profile.location ?? '',
  ProfileControls.bio: profile.bio ?? '',
  ProfileControls.willingToTeach: profile.willingToTeach,
  ProfileControls.openToNewPlayers: profile.openToNewPlayers,
  ProfileControls.hostingCapability: profile.hostingCapability,
  ProfileControls.preferredPlayerCount: profile.preferredPlayerCount == null
      ? ''
      : '${profile.preferredPlayerCount}',
  ProfileControls.houseRules: profile.houseRulesPreference ?? '',
  ProfileControls.dietaryRestrictions: profile.dietaryRestrictions ?? '',
  ProfileControls.accessibilityNeeds: profile.accessibilityNeeds ?? '',
  ProfileControls.reach: profile.reach == Reach.unknown ? null : profile.reach,
  ProfileControls.isSearchable: profile.isSearchable ?? false,
};

/// The changes [values] make to [initial], the profile as the server last
/// sent it. A value the same as the stored one is left out, so an empty
/// patch means nothing changed.
///
/// - **Text** is compared and sent trimmed, as the server trims it, so a
///   field put back as it was, padding aside, is no change. Empty clears a
///   stored value, and is no change where there was none. The display name
///   can't be cleared: an emptied one is in the patch as empty, which the
///   form's check refuses before anything is sent.
/// - **The bio** is Markdown, which the server keeps as sent: leading spaces
///   can be structure, such as an indented code block. It is compared and
///   sent as typed. Only one that is all spaces is empty.
/// - **The player count** is a whole number, or empty to clear it. Text that
///   isn't one is left out, and the form's check refuses it.
/// - **Reach** is sent only as a rung this app knows: no choice, or
///   [Reach.unknown], is left out.
ProfilePatch profilePatchOf(
  UserProfile initial,
  Map<String, Object?> values,
) {
  String typed(String name) => values[name] as String? ?? '';
  final reach = values[ProfileControls.reach] as Reach?;
  return ProfilePatch(
    displayName: _displayName(
      initial.displayName,
      typed(ProfileControls.displayName),
    ),
    bio: _bio(initial.bio, typed(ProfileControls.bio)),
    pronouns: _text(initial.pronouns, typed(ProfileControls.pronouns)),
    location: _text(initial.location, typed(ProfileControls.location)),
    houseRulesPreference: _text(
      initial.houseRulesPreference,
      typed(ProfileControls.houseRules),
    ),
    dietaryRestrictions: _text(
      initial.dietaryRestrictions,
      typed(ProfileControls.dietaryRestrictions),
    ),
    accessibilityNeeds: _text(
      initial.accessibilityNeeds,
      typed(ProfileControls.accessibilityNeeds),
    ),
    preferredPlayerCount: _playerCount(
      initial.preferredPlayerCount,
      typed(ProfileControls.preferredPlayerCount),
    ),
    willingToTeach: _switch(
      initial.willingToTeach,
      values[ProfileControls.willingToTeach],
    ),
    openToNewPlayers: _switch(
      initial.openToNewPlayers,
      values[ProfileControls.openToNewPlayers],
    ),
    hostingCapability: _switch(
      initial.hostingCapability,
      values[ProfileControls.hostingCapability],
    ),
    isSearchable: _switch(
      initial.isSearchable ?? false,
      values[ProfileControls.isSearchable],
    ),
    reach: reach == null || reach == Reach.unknown || reach == initial.reach
        ? null
        : reach,
  );
}

/// Whether [values] hold anything [initial] doesn't: whatever
/// [profilePatchOf] would send, and a player count that isn't a number,
/// which a patch can't carry.
bool profileHasChanges(UserProfile initial, Map<String, Object?> values) {
  if (!profilePatchOf(initial, values).isEmpty) return true;
  final count = values[ProfileControls.preferredPlayerCount] as String? ?? '';
  return count.trim().isNotEmpty && _wholeNumber(count) == null;
}

/// The profile form's controls, seeded from [initial] and carrying every
/// check (#547).
///
/// [initial] is asked on every check, so the checks follow the profile the
/// form was last given, not the first. A check refuses only what a save
/// would send. A field left as it is stored isn't sent, so it never blocks
/// a save: the server can hold a value past its cap, such as a sanitized
/// bio, whose escapes can make it longer than what was typed. A field
/// cleared isn't measured either: clearing sends no text.
FormGroup profileFormGroup(UserProfile Function() initial) {
  final seed = profileValuesOf(initial());
  FormControl<T> control<T>(
    String name, [
    List<ValidatorFunction> checks = const [],
  ]) => FormControl<T>(
    value: seed[name] as T?,
    validators: [for (final check in checks) Validators.delegate(check)],
  );

  /// At most [max], counted as the server counts it, on the text [sent]
  /// puts in the patch: trimmed, or the bio as typed, as [profilePatchOf]
  /// compares and sends it.
  ValidatorFunction capped(
    int max,
    Object? Function(UserProfile initial, String typed) sent,
  ) =>
      (control) => _withinLength(sent(initial(), _typedOf(control)), max);

  return FormGroup({
    ProfileControls.displayName: control<String>(ProfileControls.displayName, [
      (control) => _displayNameNotBlank(control, initial().displayName),
      capped(
        UserProfileRemoteDataSource.maxDisplayNameLength,
        (profile, typed) => _displayName(profile.displayName, typed),
      ),
    ]),
    ProfileControls.pronouns: control<String>(ProfileControls.pronouns, [
      capped(
        UserProfileRemoteDataSource.maxPronounsLength,
        (profile, typed) => _text(profile.pronouns, typed),
      ),
    ]),
    ProfileControls.location: control<String>(ProfileControls.location, [
      capped(
        UserProfileRemoteDataSource.maxLocationLength,
        (profile, typed) => _text(profile.location, typed),
      ),
    ]),
    // Measured as sent: the server doesn't trim the bio.
    ProfileControls.bio: control<String>(ProfileControls.bio, [
      capped(
        UserProfileRemoteDataSource.maxBioLength,
        (profile, typed) => _bio(profile.bio, typed),
      ),
    ]),
    ProfileControls.willingToTeach: control<bool>(
      ProfileControls.willingToTeach,
    ),
    ProfileControls.openToNewPlayers: control<bool>(
      ProfileControls.openToNewPlayers,
    ),
    ProfileControls.hostingCapability: control<bool>(
      ProfileControls.hostingCapability,
    ),
    ProfileControls.preferredPlayerCount: control<String>(
      ProfileControls.preferredPlayerCount,
      [
        (control) => _validPlayerCount(control, initial().preferredPlayerCount),
      ],
    ),
    ProfileControls.houseRules: control<String>(ProfileControls.houseRules, [
      capped(
        UserProfileRemoteDataSource.maxHouseRulesLength,
        (profile, typed) => _text(profile.houseRulesPreference, typed),
      ),
    ]),
    ProfileControls.dietaryRestrictions: control<String>(
      ProfileControls.dietaryRestrictions,
      [
        capped(
          UserProfileRemoteDataSource.maxPracticalInfoLength,
          (profile, typed) => _text(profile.dietaryRestrictions, typed),
        ),
      ],
    ),
    ProfileControls.accessibilityNeeds: control<String>(
      ProfileControls.accessibilityNeeds,
      [
        capped(
          UserProfileRemoteDataSource.maxPracticalInfoLength,
          (profile, typed) => _text(profile.accessibilityNeeds, typed),
        ),
      ],
    ),
    ProfileControls.reach: control<Reach>(ProfileControls.reach),
    ProfileControls.isSearchable: control<bool>(ProfileControls.isSearchable),
  });
}

String _typedOf(AbstractControl<dynamic> control) {
  final value = control.value;
  return value is String ? value : '';
}

/// Digits only. `int.tryParse` alone also takes a sign and a `0x` prefix.
final RegExp _digits = RegExp(r'^[0-9]+$');

/// [value] as a whole number once trimmed, or null.
int? _wholeNumber(Object? value) {
  final text = value is String ? value.trim() : '';
  return _digits.hasMatch(text) ? int.tryParse(text) : null;
}

String? _displayName(String? stored, String typed) {
  final value = typed.trim();
  return value == (stored ?? '').trim() ? null : value;
}

SettingValue<String>? _text(String? stored, String typed) {
  final value = typed.trim();
  if (value == (stored ?? '').trim()) return null;
  return value.isEmpty ? const SettingValue.clear() : SettingValue.set(value);
}

SettingValue<String>? _bio(String? stored, String typed) {
  final wasEmpty = stored == null || stored.trim().isEmpty;
  if (typed.trim().isEmpty) {
    return wasEmpty ? null : const SettingValue.clear();
  }
  return typed == stored ? null : SettingValue.set(typed);
}

SettingValue<int>? _playerCount(int? stored, String typed) {
  if (typed.trim().isEmpty) {
    return stored == null ? null : const SettingValue.clear();
  }
  final count = _wholeNumber(typed);
  return count == null || count == stored ? null : SettingValue.set(count);
}

bool? _switch(bool stored, Object? value) =>
    value is bool && value != stored ? value : null;

/// A display name emptied when [stored] had one. Empty to empty is no
/// change, and an untouched profile with no name still saves (#547).
Map<String, dynamic>? _displayNameNotBlank(
  AbstractControl<dynamic> control,
  String? stored,
) {
  final value = control.value;
  final typed = value is String ? value.trim() : '';
  return typed.isEmpty && (stored ?? '').trim().isNotEmpty
      ? <String, dynamic>{ProfileErrors.blank: true}
      : null;
}

/// At most [max], counted as the server counts it, for the text a field
/// would send ([sent]: a display name, or a [SettingValue]). A field that
/// sends nothing, or clears its value, sends no text to measure.
Map<String, dynamic>? _withinLength(Object? sent, int max) {
  final text = switch (sent) {
    SettingSet<String>(:final value) => value,
    final String value => value,
    _ => null,
  };
  return text != null && serverStringLength(text) > max
      ? <String, dynamic>{ProfileErrors.tooLong: max}
      : null;
}

/// Blank clears the count, and the [stored] count left as it is isn't sent:
/// neither is checked.
Map<String, dynamic>? _validPlayerCount(
  AbstractControl<dynamic> control,
  int? stored,
) {
  final value = control.value;
  if (value is! String || value.trim().isEmpty) return null;
  final count = _wholeNumber(value);
  if (count != null && count == stored) return null;
  return count == null ||
          count < UserProfileRemoteDataSource.minPlayerCount ||
          count > UserProfileRemoteDataSource.maxPlayerCount
      ? <String, dynamic>{ProfileErrors.playerCount: true}
      : null;
}
