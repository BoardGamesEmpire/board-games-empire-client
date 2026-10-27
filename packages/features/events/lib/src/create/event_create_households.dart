import 'package:models/domain.dart';

/// The households an event can be created in (#499): known to the server,
/// and where the user's role may create one.
///
/// It filters each list [households] emits afresh, reading every role
/// again, so a role that changed is seen the next time [households] emits.
/// A role change alone needn't make it emit.
///
/// - A household this device created that the server hasn't confirmed
///   (`isLocalOnly`) is dropped first. Its id is this device's own, which the
///   server has never heard of, so its role isn't looked up.
/// - [roleOf] answers the user's role in each of the rest. One that isn't
///   [HouseholdRole.mayCreateEvents], or that no membership is cached for,
///   is dropped: the server would refuse the create with 403.
///
/// The lists come out in the order they went in, one for each, however long
/// their roles take to read, and each keeps its households' order. A lookup
/// that throws is an error on the stream, for its listener to report, and
/// the next list is filtered as any other.
Stream<List<Household>> eventCreateHouseholds(
  Stream<List<Household>> households,
  Future<HouseholdRole?> Function(String householdId) roleOf,
) => households.asyncMap((list) async {
  final known = [
    for (final household in list)
      if (!household.isLocalOnly) household,
  ];
  final roles = await Future.wait([
    for (final household in known) roleOf(household.id),
  ]);
  return [
    for (final (index, household) in known.indexed)
      if (roles[index]?.mayCreateEvents ?? false) household,
  ];
});
