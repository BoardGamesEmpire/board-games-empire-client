import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [UserProfileRemoteDataSource] whose answers a test completes by hand.
class FakeUserProfileRemote implements UserProfileRemoteDataSource {
  final List<Completer<UserProfile>> fetches = [];
  final List<Completer<UserProfile>> updates = [];
  final List<ProfilePatch> updateCalls = [];

  @override
  Future<UserProfile> fetchOwn() {
    final completer = Completer<UserProfile>();
    fetches.add(completer);
    return completer.future;
  }

  @override
  Future<UserProfile> updateOwn(ProfilePatch patch) {
    updateCalls.add(patch);
    final completer = Completer<UserProfile>();
    updates.add(completer);
    return completer.future;
  }
}

/// The caller's own profile, as the server would send it to its owner.
UserProfile profileFixture({
  String? displayName = 'Ada',
  String? bio,
  String? pronouns,
  String? location,
  int? preferredPlayerCount,
  String? houseRulesPreference,
  String? dietaryRestrictions,
  String? accessibilityNeeds,
  bool willingToTeach = false,
  bool openToNewPlayers = false,
  bool hostingCapability = false,
  Reach? reach = Reach.friends,
  bool? isSearchable = true,
}) => UserProfile(
  userId: 'user-1',
  username: 'ada',
  displayName: displayName,
  bio: bio,
  pronouns: pronouns,
  location: location,
  preferredPlayerCount: preferredPlayerCount,
  houseRulesPreference: houseRulesPreference,
  dietaryRestrictions: dietaryRestrictions,
  accessibilityNeeds: accessibilityNeeds,
  willingToTeach: willingToTeach,
  openToNewPlayers: openToNewPlayers,
  hostingCapability: hostingCapability,
  reach: reach,
  isSearchable: isSearchable,
);
