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

  String get displayName {
    if (user.firstName != null || user.lastName != null) {
      return '${user.firstName ?? ''} ${user.lastName ?? ''}'.trim();
    }
    return user.username;
  }

  String get initials {
    if (user.firstName != null && user.lastName != null) {
      return '${user.firstName![0]}${user.lastName![0]}'.toUpperCase();
    } else if (user.firstName != null) {
      return user.firstName!.substring(0, 2).toUpperCase();
    }
    return user.username.substring(0, 2).toUpperCase();
  }

  bool get hasAvatar => user.avatar != null || user.profileImage != null;

  String? get avatarUrl => user.profileImage ?? user.avatar;

  int get friendCount =>
      friendships.where((f) => f.status == FriendshipStatus.accepted).length;

  @override
  List<Object?> get props => [user, preferences, achievements, friendships];
}
