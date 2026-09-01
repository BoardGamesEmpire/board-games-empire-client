import 'package:equatable/equatable.dart';

import '../domain/user/user.dart';
import '../domain/user/user_preferences.dart';
import '../domain/achievement/user_achievement.dart';
import '../domain/social/friendship.dart';
import '../domain/social/friendship_status.dart';

class UserProfile extends Equatable {
  final User user;
  final UserPreferences? preferences;
  final List<UserAchievement> achievements;
  final List<Friendship> friendships;

  const UserProfile({
    required this.user,
    this.preferences,
    this.achievements = const [],
    this.friendships = const [],
  });

  /// Stands in for [initials] when no name field yields a single character
  /// (#183).
  ///
  /// Reachable only when first name, last name *and* username are all
  /// absent, empty or whitespace. The server requires a username, so this
  /// is a defensive floor rather than an expected state — but it is the
  /// floor that keeps [initials] total, and a total getter is the whole
  /// point of #183.
  static const String initialsPlaceholder = '?';

  /// The name to render for this user.
  ///
  /// Falls back to [User.username] when no name field carries anything
  /// renderable. Empty and whitespace-only strings count as absent (#183):
  /// the backend accepts them, and treating `''` as a present name is what
  /// made this return an empty string.
  // TODO: make configurable: allow user to choose which name to display (username, first+last, first only, last only, etc.)
  String get displayName {
    final parts = [_firstName, _lastName].where((part) => part.isNotEmpty);
    if (parts.isNotEmpty) return parts.join(' ');
    return user.username;
  }

  /// Up to two uppercase characters standing for this user.
  ///
  /// The fallback chain, in order (#183):
  ///
  /// 1. first initial of first + last name, when both are present,
  /// 2. the leading characters of whichever single name is present,
  /// 3. the leading characters of the username,
  /// 4. [initialsPlaceholder].
  ///
  /// Every step goes through [_leading], so a one-character name yields one
  /// character rather than throwing. Steps 2 and 3 deliberately mirror
  /// [displayName]'s precedence — a profile showing "Doe" must not show
  /// initials taken from the username.
  String get initials {
    final first = _firstName;
    final last = _lastName;

    if (first.isNotEmpty && last.isNotEmpty) {
      return '${_leading(first, 1)}${_leading(last, 1)}'.toUpperCase();
    }

    final source = [
      first,
      last,
      user.username.trim(),
    ].where((candidate) => candidate.isNotEmpty).firstOrNull;

    if (source == null) return initialsPlaceholder;

    return _leading(source, 2).toUpperCase();
  }

  /// The first [count] Unicode **code points** of [source], or all of them
  /// when it is shorter.
  ///
  /// Code points rather than `[]`/`substring`, which index UTF-16 code
  /// *units* (#347 review). A character outside the Basic Multilingual
  /// Plane — an emoji, or scripts like Deseret and Gothic — occupies two
  /// units, so slicing by units cut such a character in half and returned a
  /// string containing an unpaired surrogate. That is not a crash but
  /// invalid text: it renders as U+FFFD in an avatar chip, which is harder
  /// to notice than a throw and impossible to explain from a screenshot.
  ///
  /// `take` clamps, so no length guard is needed here or at the call sites.
  ///
  /// Code points are not the same as grapheme clusters: a combining mark
  /// (`e` + U+0301) counts as two, so "é" spelled that way contributes only
  /// its base letter, and a ZWJ emoji sequence can still be cut at a join.
  /// Both degrade to *valid* text rather than broken text, which is the
  /// property worth having. Full grapheme handling needs
  /// `package:characters`, a dependency this package does not carry and one
  /// worth adding deliberately rather than in passing.
  static String _leading(String source, int count) =>
      String.fromCharCodes(source.runes.take(count));

  /// [User.firstName] with whitespace trimmed, or `''` when absent.
  String get _firstName => user.firstName?.trim() ?? '';

  /// [User.lastName] with whitespace trimmed, or `''` when absent.
  String get _lastName => user.lastName?.trim() ?? '';

  bool get hasAvatar => user.image != null;

  String? get avatarUrl => user.image;

  int get friendCount =>
      friendships.where((f) => f.status == FriendshipStatus.accepted).length;

  @override
  List<Object?> get props => [user, preferences, achievements, friendships];
}
