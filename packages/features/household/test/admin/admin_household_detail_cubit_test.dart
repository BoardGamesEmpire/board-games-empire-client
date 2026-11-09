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

  // How the older of two overlapping reads ends. Only a 403 has an effect
  // past the read: it asks the access again.
  final olderEndings = <String, void Function(Completer<AdminHouseholdDetail>)>{
    'answers': (answer) => answer.complete(adminDetail(name: 'Older')),
    'fails': (answer) =>
        answer.completeError(const AdminHouseholdTransientException('down')),
    'is refused': (answer) =>
        answer.completeError(const AdminHouseholdForbiddenException('no')),
  };
  for (final MapEntry(key: ending, value: endOlder) in olderEndings.entries) {
    for (final newerFirst in [true, false]) {
      test('of two overlapping reads, the one asked for last wins, when the '
          'older $ending and the ${newerFirst ? 'newer' : 'older'} ends '
          'first', () async {
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

        final older = cubit.load();
        final newer = cubit.load();
        Future<void> answerOlder() async {
          endOlder(answers[0]);
          await older;
        }

        Future<void> answerNewer() async {
          answers[1].complete(adminDetail(name: 'Newer'));
          await newer;
        }

        if (newerFirst) {
          await answerNewer();
          await answerOlder();
        } else {
          await answerOlder();
          await pumpEventQueue();
          // The older answer, with the newer still out, shows nothing.
          expect(states, isEmpty);
          await answerNewer();
        }
        // The stream hands a state on a turn after the cubit emits it.
        await pumpEventQueue();

        expect(states, [AdminHouseholdDetailReady(adminDetail(name: 'Newer'))]);
        expect(
          cubit.state,
          AdminHouseholdDetailReady(adminDetail(name: 'Newer')),
        );
        // Asked even though the newer read answered: the refusal is about the
        // caller, not the household.
        expect(access.refreshCount, ending == 'is refused' ? 1 : 0);
      });
    }
  }

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
