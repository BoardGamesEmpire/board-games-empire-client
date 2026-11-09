import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_admin_household_remote.dart';

void main() {
  late FakeAdminHouseholdRemote remote;
  late FakeCallerAccessRepository access;

  setUp(() {
    remote = FakeAdminHouseholdRemote();
    access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.of({ResourceType.household: AccessExtent.all}),
    );
  });

  AdminHouseholdDetailCubit build() =>
      AdminHouseholdDetailCubit(remote: remote, access: access, id: 'h_1');

  blocTest<AdminHouseholdDetailCubit, AdminHouseholdDetailState>(
    'starts loading and reads the household by id',
    build: () {
      remote.onFetchDetail = (_) async => adminDetail();
      return build();
    },
    act: (cubit) => cubit.load(),
    expect: () => [AdminHouseholdDetailReady(adminDetail())],
    verify: (_) => expect(remote.calls, ['fetchDetail(h_1)']),
  );

  blocTest<AdminHouseholdDetailCubit, AdminHouseholdDetailState>(
    'a 404 is gone',
    build: () {
      remote.onFetchDetail = (_) async =>
          throw const AdminHouseholdNotFoundException('gone');
      return build();
    },
    act: (cubit) => cubit.load(),
    expect: () => [const AdminHouseholdDetailGone()],
    verify: (_) => expect(access.refreshCount, 0),
  );

  blocTest<AdminHouseholdDetailCubit, AdminHouseholdDetailState>(
    'a 403 is refused, and asks the access again once',
    build: () {
      remote.onFetchDetail = (_) async =>
          throw const AdminHouseholdForbiddenException('no');
      return build();
    },
    act: (cubit) => cubit.load(),
    expect: () => [const AdminHouseholdDetailRefused()],
    verify: (_) => expect(access.refreshCount, 1),
  );

  blocTest<AdminHouseholdDetailCubit, AdminHouseholdDetailState>(
    'a transient or permanent failure is failed',
    build: () {
      var n = 0;
      remote.onFetchDetail = (_) async => throw n++ == 0
          ? const AdminHouseholdTransientException('down')
          : const AdminHouseholdPermanentException('no');
      return build();
    },
    act: (cubit) async {
      await cubit.load();
      await cubit.load();
    },
    expect: () => [
      const AdminHouseholdDetailFailed(),
      const AdminHouseholdDetailLoading(),
      const AdminHouseholdDetailFailed(),
    ],
  );

  test('of two overlapping reads, the one asked for last wins, whichever '
      'answers first', () async {
    final answers = [
      Completer<AdminHouseholdDetail>(),
      Completer<AdminHouseholdDetail>(),
    ];
    var reads = 0;
    remote.onFetchDetail = (_) => answers[reads++].future;
    final cubit = build();
    addTearDown(cubit.close);
    final states = <AdminHouseholdDetailState>[];
    final listening = cubit.stream.listen(states.add);
    addTearDown(listening.cancel);

    final first = cubit.load();
    final second = cubit.load();
    answers[1].complete(adminDetail(name: 'Newer'));
    await second;
    answers[0].complete(adminDetail(name: 'Older'));
    await first;

    expect(states, [AdminHouseholdDetailReady(adminDetail(name: 'Newer'))]);
    expect(cubit.state, AdminHouseholdDetailReady(adminDetail(name: 'Newer')));
  });

  blocTest<AdminHouseholdDetailCubit, AdminHouseholdDetailState>(
    'a retry shows loading, then the household',
    build: () {
      var n = 0;
      remote.onFetchDetail = (_) async {
        if (n++ == 0) throw const AdminHouseholdTransientException('down');
        return adminDetail();
      };
      return build();
    },
    act: (cubit) async {
      await cubit.load();
      await cubit.load();
    },
    expect: () => [
      const AdminHouseholdDetailFailed(),
      const AdminHouseholdDetailLoading(),
      AdminHouseholdDetailReady(adminDetail()),
    ],
  );
}
