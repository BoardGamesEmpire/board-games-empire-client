import 'dart:async';

import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

Household _household(String id, {bool localOnly = false}) => Household(
  id: id,
  name: 'Household $id',
  isLocalOnly: localOnly,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

/// Pins which households the create form offers (#499): only ones the
/// server knows, and where the user's role may create an event.
void main() {
  late Map<String, HouseholdRole?> roles;
  late List<String> asked;

  setUp(() {
    roles = {};
    asked = [];
  });

  Future<HouseholdRole?> roleOf(String householdId) async {
    asked.add(householdId);
    return roles[householdId];
  }

  List<String> ids(List<Household> households) => [
    for (final household in households) household.id,
  ];

  test('drops a local-only household', () async {
    roles = {
      'h_local': HouseholdRole.householdOwner,
      'h_1': HouseholdRole.householdOwner,
    };

    final offered = await eventCreateHouseholds(
      Stream.value([_household('h_local', localOnly: true), _household('h_1')]),
      roleOf,
    ).single;

    expect(ids(offered), ['h_1']);
    // Dropped before its role is looked up: the server has never heard of
    // it, whatever this device holds.
    expect(asked, ['h_1']);
  });

  test('drops one where the user is a guest', () async {
    roles = {
      'h_guest': HouseholdRole.householdGuest,
      'h_unknown': HouseholdRole.unknown,
      'h_none': null,
      'h_owner': HouseholdRole.householdOwner,
    };

    final offered = await eventCreateHouseholds(
      Stream.value([
        _household('h_guest'),
        _household('h_unknown'),
        _household('h_none'),
        _household('h_owner'),
      ]),
      roleOf,
    ).single;

    // A role this client can't read, or no membership cached, is dropped
    // too.
    expect(ids(offered), ['h_owner']);
  });

  test("keeps a member's", () async {
    roles = {
      'h_b': HouseholdRole.householdMember,
      'h_a': HouseholdRole.householdAdmin,
    };

    final offered = await eventCreateHouseholds(
      Stream.value([_household('h_b'), _household('h_a')]),
      roleOf,
    ).single;

    // In the order the households came.
    expect(ids(offered), ['h_b', 'h_a']);
  });

  test('re-filters on every emission', () async {
    final households = StreamController<List<Household>>();
    addTearDown(households.close);
    roles = {'h_1': HouseholdRole.householdMember};
    final emitted = <List<String>>[];
    final subscription = eventCreateHouseholds(
      households.stream,
      roleOf,
    ).listen((offered) => emitted.add(ids(offered)));
    addTearDown(subscription.cancel);

    households.add([_household('h_1'), _household('h_2')]);
    await pumpEventQueue();
    expect(emitted, [
      ['h_1'],
    ]);

    // The role changed elsewhere, and a household the user joined arrives.
    roles = {
      'h_1': HouseholdRole.householdGuest,
      'h_2': HouseholdRole.householdMember,
    };
    households.add([_household('h_1'), _household('h_2')]);
    await pumpEventQueue();

    expect(emitted, [
      ['h_1'],
      ['h_2'],
    ]);
  });

  test(
    'keeps every list, in order, however slowly the roles are read',
    () async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      // Each role read waits until the test answers it.
      final waiting = <Completer<HouseholdRole?>>[];
      Future<HouseholdRole?> slowRoleOf(String householdId) {
        final read = Completer<HouseholdRole?>();
        waiting.add(read);
        return read.future;
      }

      final emitted = <List<String>>[];
      final subscription = eventCreateHouseholds(
        households.stream,
        slowRoleOf,
      ).listen((offered) => emitted.add(ids(offered)));
      addTearDown(subscription.cancel);

      /// Answers every read waiting, the latest first, so a later list's
      /// reads land before an earlier one's wherever both are waiting. False
      /// once none is.
      Future<bool> answerWaiting() async {
        await pumpEventQueue();
        final answering = waiting.reversed.toList();
        waiting.clear();
        for (final read in answering) {
          read.complete(HouseholdRole.householdMember);
        }
        await pumpEventQueue();
        return answering.isNotEmpty;
      }

      households
        ..add([_household('h_1')])
        ..add([_household('h_1'), _household('h_2')]);
      while (await answerWaiting()) {}

      expect(emitted, [
        ['h_1'],
        ['h_1', 'h_2'],
      ]);
    },
  );
}
