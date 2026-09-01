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
  /// Every step is length-clamped, so a one-character name yields one
  /// character rather than throwing. Steps 2 and 3 deliberately mirror
  /// [displayName]'s precedence — a profile showing "Doe" must not show
  /// initials taken from the username.
  String get initials {
    final first = _firstName;
    final last = _lastName;

    if (first.isNotEmpty && last.isNotEmpty) {
      return '${first[0]}${last[0]}'.toUpperCase();
    }

    final source = [
      first,
      last,
      user.username.trim(),
    ].where((candidate) => candidate.isNotEmpty).firstOrNull;

    if (source == null) return initialsPlaceholder;

    return source
        .substring(0, source.length < 2 ? source.length : 2)
        .toUpperCase();
  }

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
