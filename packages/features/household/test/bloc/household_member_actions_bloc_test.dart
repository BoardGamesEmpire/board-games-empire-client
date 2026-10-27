import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'package:household/household.dart';

class MockMemberRemote extends Mock
    implements HouseholdMemberRemoteDataSource {}

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

class MockBgeLogger extends Mock implements BgeLogger {}

HouseholdMember _member({
  String id = 'm1',
  String userId = 'u1',
  HouseholdRole role = HouseholdRole.householdMember,
}) => HouseholdMember(
  id: id,
  userId: userId,
  householdId: 'h1',
  role: role,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

const _gone = HouseholdMemberRefusedException('gone', statusCode: 404);
const _forbidden = HouseholdMemberRefusedException('no', statusCode: 403);
const _offline = HouseholdMemberTransientException('down');
const _unreadable = HouseholdMemberPermanentException('?', statusCode: 200);

void main() {
  late MockMemberRemote remote;
  late MockHouseholdRepository repository;
  late MockBgeLogger logger;

  /// What the bloc called, in order: the cache writes and the refresh.
  late List<String> calls;

  final m1 = _member();
  final m2 = _member(
    id: 'm2',
    userId: 'u2',
    role: HouseholdRole.householdGuest,
  );
  final promoted = _member(role: HouseholdRole.householdAdmin);

  setUpAll(() {
    registerFallbackValue(m1);
    registerFallbackValue(HouseholdRole.householdMember);
  });

  setUp(() {
    remote = MockMemberRemote();
    repository = MockHouseholdRepository();
    logger = MockBgeLogger();
    calls = [];
    when(() => repository.cacheMember(any())).thenAnswer((_) async {
      calls.add('cacheMember');
    });
    when(() => repository.removeCachedMember(any(), any()))
        .thenAnswer((invocation) async {
          final [householdId, userId] = invocation.positionalArguments;
          calls.add('removeCachedMember($householdId, $userId)');
        });
  });

  HouseholdMemberActionsBloc build({Future<void> Function()? onChanged}) =>
      HouseholdMemberActionsBloc(
        remote: remote,
        repository: repository,
        onChanged: onChanged ?? () async => calls.add('onChanged'),
        logger: logger,
      );

  int refreshes() => calls.where((call) => call == 'onChanged').length;

  HouseholdMemberActionsState settled(
    HouseholdMemberAction action,
    HouseholdMemberActionResult result, {
    Object? error,
  }) => HouseholdMemberActionsState(
    outcome: HouseholdMemberOutcome(
      action: action,
      result: result,
      error: error,
    ),
  );

  void failRoleChange(Object error) =>
      when(() => remote.changeRole(any(), any(), any())).thenThrow(error);

  void failRemoval(Object error) =>
      when(() => remote.remove(any(), any())).thenThrow(error);

  group('a 200', () {
    late Completer<HouseholdMember> reply;

    setUp(() => reply = Completer<HouseholdMember>());

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'a role change caches the answer, then refreshes',
      setUp: () => when(
        () => remote.changeRole('h1', 'm1', HouseholdRole.householdAdmin),
      ).thenAnswer((_) => reply.future),
      build: build,
      act: (bloc) async {
        bloc.add(
          HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdAdmin),
        );
        await pumpEventQueue();
        expect(bloc.state.busy, {'m1'});
        expect(calls, isEmpty);
        reply.complete(promoted);
      },
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.done,
        ),
      ],
      verify: (_) {
        verify(() => repository.cacheMember(promoted)).called(1);
        expect(calls, ['cacheMember', 'onChanged']);
      },
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'a removal caches, then refreshes',
      setUp: () =>
          when(() => remote.remove('h1', 'm1')).thenAnswer((_) async => m1),
      build: build,
      act: (bloc) => bloc.add(HouseholdMemberRemovalRequested(m1)),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(HouseholdMemberAction.remove, HouseholdMemberActionResult.done),
      ],
      verify: (_) {
        expect(calls, ['removeCachedMember(h1, u1)', 'onChanged']);
        verifyNever(() => repository.cacheMember(any()));
      },
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'a cache write that throws still reports done and refreshes',
      // The server made the change, and the refresh brings it.
      setUp: () {
        when(() => remote.changeRole(any(), any(), any()))
            .thenAnswer((_) async => promoted);
        when(() => repository.cacheMember(any()))
            .thenThrow(StateError('scope disposed'));
      },
      build: build,
      act: (bloc) => bloc.add(
        HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdAdmin),
      ),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.done,
        ),
      ],
      verify: (_) {
        expect(refreshes(), 1);
        verify(
          () => logger.warn(
            any(),
            error: any(named: 'error', that: isA<StateError>()),
            stackTrace: any(named: 'stackTrace'),
          ),
        ).called(1);
      },
    );
  });

  group('a refusal', () {
    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'an enveloped 404 on remove reads as gone, deletes nothing, refreshes',
      // The refresh, not this answer, takes the row out of the cache.
      setUp: () => failRemoval(_gone),
      build: build,
      act: (bloc) => bloc.add(HouseholdMemberRemovalRequested(m1)),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.remove,
          HouseholdMemberActionResult.gone,
          error: _gone,
        ),
      ],
      verify: (_) {
        verifyNever(() => repository.removeCachedMember(any(), any()));
        verifyNever(() => repository.cacheMember(any()));
        expect(refreshes(), 1);
      },
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'an enveloped 404 on a role change reads as gone and refreshes',
      setUp: () => failRoleChange(_gone),
      build: build,
      act: (bloc) => bloc.add(
        HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdGuest),
      ),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.gone,
          error: _gone,
        ),
      ],
      verify: (_) {
        verifyNever(() => repository.cacheMember(any()));
        expect(refreshes(), 1);
      },
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'a 403 says the role changed and refreshes',
      // The viewer's role may have changed on another device.
      setUp: () => failRoleChange(_forbidden),
      build: build,
      act: (bloc) => bloc.add(
        HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdGuest),
      ),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.refused,
          error: _forbidden,
        ),
      ],
      verify: (bloc) {
        final error = bloc.state.outcome?.error;
        expect(
          error,
          isA<HouseholdMemberRefusedException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        );
        verifyNever(() => repository.cacheMember(any()));
        expect(refreshes(), 1);
      },
    );

    for (final status in [400, 409]) {
      final refusal = HouseholdMemberRefusedException('no', statusCode: status);
      blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
        'a $status is refused and refreshes',
        setUp: () => failRemoval(refusal),
        build: build,
        act: (bloc) => bloc.add(HouseholdMemberRemovalRequested(m1)),
        expect: () => [
          const HouseholdMemberActionsState(busy: {'m1'}),
          settled(
            HouseholdMemberAction.remove,
            HouseholdMemberActionResult.refused,
            error: refusal,
          ),
        ],
        verify: (_) {
          verifyNever(() => repository.removeCachedMember(any(), any()));
          expect(refreshes(), 1);
        },
      );
    }
  });

  group('a failure', () {
    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'offline changes nothing and does not refresh',
      setUp: () => failRemoval(_offline),
      build: build,
      act: (bloc) => bloc.add(HouseholdMemberRemovalRequested(m1)),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.remove,
          HouseholdMemberActionResult.failed,
          error: _offline,
        ),
      ],
      verify: (_) {
        verifyNever(() => repository.removeCachedMember(any(), any()));
        expect(refreshes(), 0);
      },
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'an unreadable answer fails and refreshes',
      // The answer may have been a success this device could not read.
      setUp: () => failRoleChange(_unreadable),
      build: build,
      act: (bloc) => bloc.add(
        HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdAdmin),
      ),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.failed,
          error: _unreadable,
        ),
      ],
      verify: (_) {
        verifyNever(() => repository.cacheMember(any()));
        expect(refreshes(), 1);
      },
    );

    final boom = StateError('boom');
    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'any other error fails and refreshes',
      setUp: () => failRemoval(boom),
      build: build,
      act: (bloc) => bloc.add(HouseholdMemberRemovalRequested(m1)),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.remove,
          HouseholdMemberActionResult.failed,
          error: boom,
        ),
      ],
      verify: (_) => expect(refreshes(), 1),
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'a refresh that fails is logged, never surfaced',
      setUp: () =>
          when(() => remote.remove(any(), any())).thenAnswer((_) async => m1),
      build: () => build(onChanged: () async => throw StateError('offline')),
      act: (bloc) => bloc.add(HouseholdMemberRemovalRequested(m1)),
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(HouseholdMemberAction.remove, HouseholdMemberActionResult.done),
      ],
      verify: (_) => verify(
        () => logger.warn(
          any(),
          error: any(named: 'error', that: isA<StateError>()),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1),
    );
  });

  group('busy', () {
    test('a second request for a busy member is dropped', () async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.changeRole(any(), any(), any()))
          .thenAnswer((_) => reply.future);
      final bloc = build();
      addTearDown(bloc.close);

      bloc
        ..add(
          HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdAdmin),
        )
        ..add(
          HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdGuest),
        )
        ..add(HouseholdMemberRemovalRequested(m1));
      await pumpEventQueue();
      reply.complete(promoted);
      await pumpEventQueue();

      verify(() => remote.changeRole(any(), any(), any())).called(1);
      verifyNever(() => remote.remove(any(), any()));
      expect(
        bloc.state,
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.done,
        ),
      );
    });

    const roleChanged = HouseholdMemberOutcome(
      action: HouseholdMemberAction.changeRole,
      result: HouseholdMemberActionResult.done,
    );
    const removed = HouseholdMemberOutcome(
      action: HouseholdMemberAction.remove,
      result: HouseholdMemberActionResult.done,
    );

    /// Starts a role change for m1 and then a removal of m2, each waiting on
    /// the completer returned for it, and checks both are busy.
    Future<
      (
        HouseholdMemberActionsBloc,
        Completer<HouseholdMember>,
        Completer<HouseholdMember>,
      )
    >
    startBoth() async {
      final forM1 = Completer<HouseholdMember>();
      final forM2 = Completer<HouseholdMember>();
      when(() => remote.changeRole('h1', 'm1', HouseholdRole.householdAdmin))
          .thenAnswer((_) => forM1.future);
      when(() => remote.remove('h1', 'm2')).thenAnswer((_) => forM2.future);
      final bloc = build();
      addTearDown(bloc.close);

      bloc
        ..add(
          HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdAdmin),
        )
        ..add(HouseholdMemberRemovalRequested(m2));
      await pumpEventQueue();
      expect(bloc.state.busy, {'m1', 'm2'});
      return (bloc, forM1, forM2);
    }

    test('two members can be acted on at once', () async {
      // The first to start answers first, so a busy set taken as it stood
      // when a request started would drop m2 here.
      final (bloc, forM1, forM2) = await startBoth();

      forM1.complete(promoted);
      await pumpEventQueue();
      expect(
        bloc.state,
        const HouseholdMemberActionsState(busy: {'m2'}, outcome: roleChanged),
      );

      forM2.complete(m2);
      await pumpEventQueue();
      expect(bloc.state, const HouseholdMemberActionsState(outcome: removed));
      expect(calls, [
        'cacheMember',
        'onChanged',
        'removeCachedMember(h1, u2)',
        'onChanged',
      ]);
    });

    test(
      'two members can be acted on at once, the later answering first',
      () async {
        final (bloc, forM1, forM2) = await startBoth();

        forM2.complete(m2);
        await pumpEventQueue();
        expect(
          bloc.state,
          const HouseholdMemberActionsState(busy: {'m1'}, outcome: removed),
        );

        forM1.complete(promoted);
        await pumpEventQueue();
        expect(
          bloc.state,
          const HouseholdMemberActionsState(outcome: roleChanged),
        );
        expect(calls, [
          'removeCachedMember(h1, u2)',
          'onChanged',
          'cacheMember',
          'onChanged',
        ]);
      },
    );

    test(
      'an answer after the screen closed is still cached and refreshed',
      () async {
        // The server made the change whether or not anyone is still looking.
        final reply = Completer<HouseholdMember>();
        when(() => remote.changeRole(any(), any(), any()))
            .thenAnswer((_) => reply.future);
        final bloc = build()
          ..add(
            HouseholdMemberRoleChangeRequested(
              m1,
              HouseholdRole.householdAdmin,
            ),
          );
        await pumpEventQueue();
        await bloc.close();

        reply.complete(promoted);
        await pumpEventQueue();

        verify(() => repository.cacheMember(promoted)).called(1);
        expect(calls, ['cacheMember', 'onChanged']);
      },
    );
  });

  group('the outcome', () {
    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'dismiss clears the outcome',
      setUp: () => failRemoval(_offline),
      build: build,
      act: (bloc) async {
        bloc.add(HouseholdMemberRemovalRequested(m1));
        await pumpEventQueue();
        bloc.add(const HouseholdMemberOutcomeDismissed());
      },
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.remove,
          HouseholdMemberActionResult.failed,
          error: _offline,
        ),
        const HouseholdMemberActionsState(),
      ],
    );

    blocTest<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      'a new request clears the last outcome',
      // The banner described the earlier action.
      setUp: () {
        failRemoval(_offline);
        when(() => remote.changeRole(any(), any(), any()))
            .thenAnswer((_) async => promoted);
      },
      build: build,
      act: (bloc) async {
        bloc.add(HouseholdMemberRemovalRequested(m2));
        await pumpEventQueue();
        bloc.add(
          HouseholdMemberRoleChangeRequested(m1, HouseholdRole.householdAdmin),
        );
      },
      skip: 2,
      expect: () => [
        const HouseholdMemberActionsState(busy: {'m1'}),
        settled(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.done,
        ),
      ],
    );
  });
}
