import 'package:freezed_annotation/freezed_annotation.dart';
import '../common/visibility.dart';

part 'user_preferences.freezed.dart';
part 'user_preferences.g.dart';

@freezed
abstract class UserPreferences with _$UserPreferences {
  const factory UserPreferences({
    required String id,
    required String userId,
    @Default('system') String theme,
    String? accentColor,
    @Default(true) bool showOnlineStatus,
    @Default(true) bool showLastActive,
    @Default(true) bool allowFriendRequests,
    @Default(true) bool showCollectionToFriends,
    @Default(true) bool showGamePlayHistory,
    Map<String, dynamic>? emailNotifications,
    Map<String, dynamic>? pushNotifications,
    int? preferredPlayerCount,
    int? preferredGameLength,
    @Default([]) List<String> favoriteCategories,
    @Default([]) List<String> favoriteMechanics,
    @Default([]) List<String> dislikedCategories,
    @Default([]) List<String> dislikedMechanics,
    String? languageId,
    @Default(Visibility.private) Visibility defaultReviewVisibility,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _UserPreferences;

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      _$UserPreferencesFromJson(json);
}
