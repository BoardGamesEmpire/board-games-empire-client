import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_household_invite_remote.dart';

void main() {
  late FakeHouseholdInviteRemote remote;

  setUp(() => remote = FakeHouseholdInviteRemote());

  AwaitingApprovalCountCubit build() =>
      AwaitingApprovalCountCubit(householdId: 'hh_1', remote: remote);

  test('knows nothing until a read succeeds', () {
    final cubit = build();
    addTearDown(cubit.close);

    expect(cubit.state, isNull);
  });

  blocTest<AwaitingApprovalCountCubit, int?>(
    'counts what awaits approval from the page total, reading one row',
    setUp: () =>
        remote.onFetchHouseholdInvites = (_, _, _, limit) async =>
            pageOf([invite('i_1')], limit: limit, total: 3, hasMore: true),
    build: build,
    act: (cubit) => cubit.load(),
    expect: () => [3],
    verify: (_) => expect(remote.calls, [
      'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 1)',
    ]),
  );

  blocTest<AwaitingApprovalCountCubit, int?>(
    'forgets the count when a read fails',
    setUp: () {
      var calls = 0;
      remote.onFetchHouseholdInvites = (_, _, _, limit) async {
        if (calls++ == 0) return pageOf(const [], limit: limit, total: 2);
        throw offline();
      };
    },
    build: build,
    act: (cubit) async {
      await cubit.load();
      await cubit.load();
    },
    expect: () => [2, null],
  );

  test('of two overlapping reads, the later wins even when it answers '
      'first', () async {
    final first = Completer<PaginatedResult<HouseholdInvite>>();
    final second = Completer<PaginatedResult<HouseholdInvite>>();
    final answers = [first, second];
    remote.onFetchHouseholdInvites = (_, _, _, _) => answers.removeAt(0).future;
    final cubit = build();
    addTearDown(cubit.close);

    final older = cubit.load();
    final newer = cubit.load();
    second.complete(pageOf(const [], limit: 1));
    await newer;
    first.complete(pageOf([invite('i_1')], limit: 1));
    await older;

    expect(cubit.state, 0);
  });
}
