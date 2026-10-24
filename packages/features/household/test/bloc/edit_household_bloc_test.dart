import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:household/household.dart';

class MockHouseholdRemote extends Mock implements HouseholdRemoteDataSource {}

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

Household _household({
  String name = 'Den',
  String? description,
  MemberInvitePolicy? policy = MemberInvitePolicy.needsApproval,
}) => Household(
  id: 'hh_1',
  name: name,
  description: description,
  settings: policy == null
      ? null
      : HouseholdSettings(memberInvitePolicy: policy),
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

void main() {
  late MockHouseholdRemote remote;
  late MockHouseholdRepository repository;
  late int refreshes;

  setUpAll(() {
    registerFallbackValue(HouseholdUpdate(name: 'x'));
    registerFallbackValue(_household());
  });

  setUp(() {
    remote = MockHouseholdRemote();
    repository = MockHouseholdRepository();
    refreshes = 0;
    when(() => repository.cacheHousehold(any())).thenAnswer((_) async {});
  });

  EditHouseholdBloc build({Household? original}) => EditHouseholdBloc(
    original: original ?? _household(),
    remote: remote,
    repository: repository,
    onRefresh: () async => refreshes++,
  );

  void answer(Household household) =>
      when(() => remote.updateHousehold(any(), any()))
          .thenAnswer((_) async => household);

  void fail(Object error) =>
      when(() => remote.updateHousehold(any(), any())).thenThrow(error);

  HouseholdUpdate sent() =>
      verify(() => remote.updateHousehold('hh_1', captureAny())).captured.single
          as HouseholdUpdate;

  group('what is sent', () {
    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'a save with nothing changed sends nothing',
      // The server answers an empty patch with a 400.
      build: build,
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(
          name: 'Den',
          memberInvitePolicy: MemberInvitePolicy.needsApproval,
        ),
      ),
      expect: () => [EditHouseholdSaved(_household(), changed: false)],
      verify: (_) {
        verifyNever(() => remote.updateHousehold(any(), any()));
        verifyNever(() => repository.cacheHousehold(any()));
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'only the fields that changed are sent',
      // Another admin may have renamed the household since this form
      // opened. Sending the unchanged name back would revert theirs.
      setUp: () => answer(_household(policy: MemberInvitePolicy.off)),
      build: build,
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(
          name: 'Den',
          memberInvitePolicy: MemberInvitePolicy.off,
        ),
      ),
      verify: (_) {
        final update = sent();
        expect(update.name, isNull);
        expect(update.description, isNull);
        expect(update.clearDescription, isFalse);
        expect(update.memberInvitePolicy, MemberInvitePolicy.off);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'a changed name is sent',
      setUp: () => answer(_household(name: 'Annex')),
      build: build,
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(
          name: 'Annex',
          memberInvitePolicy: MemberInvitePolicy.needsApproval,
        ),
      ),
      verify: (_) {
        final update = sent();
        expect(update.name, 'Annex');
        expect(update.memberInvitePolicy, isNull);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'emptying the description clears it',
      setUp: () => answer(_household()),
      build: () => build(original: _household(description: 'Board games')),
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Den')),
      verify: (_) {
        final update = sent();
        expect(update.clearDescription, isTrue);
        expect(update.description, isNull);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'a changed description is sent',
      setUp: () => answer(_household(description: 'Card games')),
      build: () => build(original: _household(description: 'Board games')),
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(name: 'Den', description: 'Card games'),
      ),
      verify: (_) {
        final update = sent();
        expect(update.description, 'Card games');
        expect(update.clearDescription, isFalse);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'an untouched empty description stays unchanged',
      setUp: () => answer(_household(name: 'Annex')),
      build: build,
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
      verify: (_) {
        final update = sent();
        expect(update.description, isNull);
        expect(update.clearDescription, isFalse);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'an untouched name another client stored untrimmed is not sent',
      // The form trims what it hands over and the server does not, so
      // " Den " comes back as "Den". Sending it would overwrite a rename
      // made since the form opened.
      setUp: () => answer(_household(policy: MemberInvitePolicy.off)),
      build: () => build(original: _household(name: ' Den ')),
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(
          name: 'Den',
          memberInvitePolicy: MemberInvitePolicy.off,
        ),
      ),
      verify: (_) {
        final update = sent();
        expect(update.name, isNull);
        expect(update.memberInvitePolicy, MemberInvitePolicy.off);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'an untouched description stored untrimmed is not sent',
      setUp: () => answer(_household(name: 'Annex')),
      build: () => build(original: _household(description: 'Board games\n')),
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(name: 'Annex', description: 'Board games'),
      ),
      verify: (_) {
        final update = sent();
        expect(update.description, isNull);
        expect(update.clearDescription, isFalse);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'an untouched whitespace-only description is not cleared',
      setUp: () => answer(_household(name: 'Annex')),
      build: () => build(original: _household(description: '  ')),
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
      verify: (_) {
        final update = sent();
        expect(update.description, isNull);
        expect(update.clearDescription, isFalse);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'no policy chosen leaves the policy alone',
      // The cache had no policy, or one this client doesn't know, so the
      // form preselected nothing.
      setUp: () => answer(_household(name: 'Annex')),
      build: () => build(original: _household(policy: null)),
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
      verify: (_) => expect(sent().memberInvitePolicy, isNull),
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'a policy chosen where the cache had none is sent',
      setUp: () => answer(_household()),
      build: () => build(original: _household(policy: null)),
      act: (bloc) => bloc.add(
        const EditHouseholdSubmitted(
          name: 'Den',
          memberInvitePolicy: MemberInvitePolicy.direct,
        ),
      ),
      verify: (_) =>
          expect(sent().memberInvitePolicy, MemberInvitePolicy.direct),
    );
  });

  group('the answer', () {
    final answered = _household(name: 'Annex');

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'the answer is cached and reported',
      setUp: () => answer(answered),
      build: build,
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
      expect: () => [const EditHouseholdSaving(), EditHouseholdSaved(answered)],
      verify: (_) {
        verify(() => repository.cacheHousehold(answered)).called(1);
        expect(refreshes, 0);
      },
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'a failed cache write still reports saved',
      // The server accepted the edit, and the next hydrate brings it.
      setUp: () {
        answer(answered);
        when(() => repository.cacheHousehold(any()))
            .thenThrow(StateError('scope disposed'));
      },
      build: build,
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
      expect: () => [const EditHouseholdSaving(), EditHouseholdSaved(answered)],
    );

    test('a second submit while saving sends nothing', () async {
      final reply = Completer<Household>();
      when(() => remote.updateHousehold(any(), any()))
          .thenAnswer((_) => reply.future);
      final bloc = build();
      addTearDown(bloc.close);

      bloc
        ..add(const EditHouseholdSubmitted(name: 'Annex'))
        ..add(const EditHouseholdSubmitted(name: 'Annex'));
      await Future<void>.delayed(Duration.zero);
      reply.complete(answered);
      await Future<void>.delayed(Duration.zero);

      verify(() => remote.updateHousehold(any(), any())).called(1);
      expect(bloc.state, EditHouseholdSaved(answered));
    });

    test('a submit once saved is ignored', () async {
      answer(answered);
      final bloc = build();
      addTearDown(bloc.close);

      bloc.add(const EditHouseholdSubmitted(name: 'Annex'));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const EditHouseholdSubmitted(name: 'Elsewhere'));
      await Future<void>.delayed(Duration.zero);

      verify(() => remote.updateHousehold(any(), any())).called(1);
      expect(bloc.state, EditHouseholdSaved(answered));
    });
  });

  group('failures', () {
    void expectFailure(
      String description, {
      required Object error,
      required EditHouseholdFailure reason,
      required bool refreshed,
    }) {
      blocTest<EditHouseholdBloc, EditHouseholdState>(
        description,
        setUp: () => fail(error),
        build: build,
        act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
        expect: () => [
          const EditHouseholdSaving(),
          EditHouseholdFailed(reason),
        ],
        verify: (_) {
          verifyNever(() => repository.cacheHousehold(any()));
          expect(refreshes, refreshed ? 1 : 0);
        },
      );
    }

    expectFailure(
      'an unreachable server is offline',
      error: const HouseholdRemoteTransientException('down'),
      reason: EditHouseholdFailure.offline,
      refreshed: false,
    );

    expectFailure(
      'a household that is gone says so, and refreshes',
      // The refresh, not this answer, removes it from the cache.
      error: const HouseholdNotFoundException('gone', statusCode: 404),
      reason: EditHouseholdFailure.gone,
      refreshed: true,
    );

    expectFailure(
      'a 403 is refused, and refreshes',
      // The viewer's role may have changed on another device.
      error: const HouseholdRemotePermanentException('no', statusCode: 403),
      reason: EditHouseholdFailure.refused,
      refreshed: true,
    );

    expectFailure(
      'a 400 is invalid',
      error: const HouseholdRemotePermanentException('bad', statusCode: 400),
      reason: EditHouseholdFailure.invalid,
      refreshed: false,
    );

    expectFailure(
      'any other permanent failure is unexpected',
      error: const HouseholdRemotePermanentException('?', statusCode: 409),
      reason: EditHouseholdFailure.unexpected,
      refreshed: false,
    );

    expectFailure(
      'anything else is unexpected',
      error: StateError('boom'),
      reason: EditHouseholdFailure.unexpected,
      refreshed: false,
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'a refresh that fails never surfaces',
      setUp: () => fail(const HouseholdNotFoundException('gone')),
      build: () => EditHouseholdBloc(
        original: _household(),
        remote: remote,
        repository: repository,
        onRefresh: () async => throw StateError('offline'),
      ),
      act: (bloc) => bloc.add(const EditHouseholdSubmitted(name: 'Annex')),
      expect: () => [
        const EditHouseholdSaving(),
        const EditHouseholdFailed(EditHouseholdFailure.gone),
      ],
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'an edit after a failure returns to editing',
      setUp: () => fail(const HouseholdRemoteTransientException('down')),
      build: build,
      act: (bloc) async {
        bloc.add(const EditHouseholdSubmitted(name: 'Annex'));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const EditHouseholdEdited());
      },
      expect: () => [
        const EditHouseholdSaving(),
        const EditHouseholdFailed(EditHouseholdFailure.offline),
        const EditHouseholdEditing(),
      ],
    );

    blocTest<EditHouseholdBloc, EditHouseholdState>(
      'an edit with no failure on show changes nothing',
      build: build,
      act: (bloc) => bloc.add(const EditHouseholdEdited()),
      expect: () => const <EditHouseholdState>[],
    );
  });
}
