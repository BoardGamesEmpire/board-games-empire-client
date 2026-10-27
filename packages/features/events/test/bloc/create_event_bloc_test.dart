import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

class _MockBgeLogger extends Mock implements BgeLogger {}

/// What the repository hands back for a create: the local-only event, the
/// entry it queued, and the op as queued.
typedef _Created = ({
  Event event,
  String syncQueueId,
  CreateEventOperation operation,
});

/// The local-only event a create writes under [id].
Event _localEvent(String id) => Event(
  id: id,
  title: 'Game night',
  createdById: 'user-me',
  type: EventType.casualGathering,
  reach: Reach.friends,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  isDirty: true,
  isLocalOnly: true,
  createdAt: DateTime.utc(2026, 10, 26),
  updatedAt: DateTime.utc(2026, 10, 26),
);

/// The form's draft, inviting two users.
const _draft = EventDraft(title: 'Game night', inviteUserIds: ['u1', 'u2']);

/// The same draft with `u2` taken off, as the form sends it after a refusal
/// names them.
const _edited = EventDraft(title: 'Game night', inviteUserIds: ['u1']);

/// The same draft with every invitee taken off.
const _noInvitees = EventDraft(title: 'Game night');

/// The server refusing the create for an invitee it has no account for, as
/// the sender parks it: this client's own message, and the server's text
/// naming [userId].
SyncParked _unknownInvitee(String userId) => SyncParked(
  EventCreateRefusedException(
    'Event create failed with status 404',
    statusCode: 404,
    apiMessage: 'User with ID $userId not found',
  ),
);

/// The create form's bloc (#499): the local create, one send of it straight
/// away, and a refusal kept on the form until the next submit discards it.
void main() {
  late _MockEventRepository repo;
  late _MockSyncOperationSender sender;
  late _MockBgeLogger logger;

  /// Every create the repository answered, in order.
  late List<_Created> created;

  /// Answers a create as the repository does: a local event of its own,
  /// queued under an entry of its own, numbered by the creates that wrote
  /// one: `ev_local_1` under `q1`, then `ev_local_2` under `q2`.
  _Created answerCreate(Invocation invocation) {
    final n = created.length + 1;
    final result = (
      event: _localEvent('ev_local_$n'),
      syncQueueId: 'q$n',
      operation: CreateEventOperation(
        localId: 'ev_local_$n',
        draft: invocation.positionalArguments.single as EventDraft,
      ),
    );
    created.add(result);
    return result;
  }

  setUpAll(() {
    registerFallbackValue(_draft);
    registerFallbackValue(
      const CreateEventOperation(localId: 'x', draft: _draft),
    );
  });

  setUp(() {
    repo = _MockEventRepository();
    sender = _MockSyncOperationSender();
    logger = _MockBgeLogger();
    created = [];

    when(() => repo.create(any()))
        .thenAnswer((invocation) async => answerCreate(invocation));
    when(() => repo.discardQueuedOp(any())).thenAnswer((_) async => true);

    // The common case: the sender delivers it, and the cache holds the
    // event under the server's id.
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered(eventId: 'ev_server'));
  });

  CreateEventBloc build() =>
      CreateEventBloc(repository: repo, sender: sender, logger: logger);

  /// Answers each send with the next of [deliveries], in order.
  void stubDeliveries(List<SyncDelivery> deliveries) {
    final answers = [...deliveries];
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => answers.removeAt(0));
  }

  /// Submits [draft] and waits for the refusal it draws, so that the next
  /// submit is provably not a re-entrant one.
  Future<void> refuse(CreateEventBloc bloc, EventDraft draft) async {
    bloc.add(CreateEventSubmitted(draft));
    await bloc.stream.firstWhere((s) => s is CreateEventRefused);
  }

  group('CreateEventBloc', () {
    group('CreateEventFailureCleared', () {
      for (final (name, seed) in <(String, CreateEventState)>[
        ('a refusal', const CreateEventRefused(inviteeId: 'u2')),
        ('a failure', const CreateEventFailure()),
      ]) {
        blocTest<CreateEventBloc, CreateEventState>(
          'takes $name back to Initial, so its message stops rendering',
          build: build,
          seed: () => seed,
          act: (bloc) => bloc.add(const CreateEventFailureCleared()),
          expect: () => const [CreateEventInitial()],
        );
      }

      // An edit must not wipe a submit in flight, or a success the screen
      // is about to act on.
      for (final (name, seed) in <(String, CreateEventState)>[
        ('Initial', const CreateEventInitial()),
        ('Submitting', const CreateEventSubmitting()),
        (
          'Success',
          const CreateEventSuccess(
            eventId: 'ev_server',
            sync: CreateEventSync.synced,
          ),
        ),
      ]) {
        blocTest<CreateEventBloc, CreateEventState>(
          'is inert in $name',
          build: build,
          seed: () => seed,
          act: (bloc) => bloc.add(const CreateEventFailureCleared()),
          expect: () => const <CreateEventState>[],
        );
      }

      // The screen clears the refusal on every edit, taking the invitee off
      // among them, so the op it names must outlast the clear.
      blocTest<CreateEventBloc, CreateEventState>(
        'clearing a refusal keeps the parked op for the next submit',
        setUp: () => stubDeliveries([
          _unknownInvitee('u2'),
          const SyncDelivered(eventId: 'ev_server'),
        ]),
        build: build,
        act: (bloc) async {
          await refuse(bloc, _draft);
          bloc.add(const CreateEventFailureCleared());
          await bloc.stream.firstWhere((s) => s is CreateEventInitial);
          bloc.add(const CreateEventSubmitted(_edited));
        },
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventRefused(inviteeId: 'u2'),
          CreateEventInitial(),
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_server',
            sync: CreateEventSync.synced,
          ),
        ],
        verify: (_) => verifyInOrder([
          () => repo.discardQueuedOp('q1'),
          () => repo.create(_edited),
        ]),
      );
    });

    blocTest<CreateEventBloc, CreateEventState>(
      'a delivered create -> Submitting then Success(synced) under the '
      'server id',
      build: build,
      act: (bloc) => bloc.add(const CreateEventSubmitted(_draft)),
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventSuccess(eventId: 'ev_server', sync: CreateEventSync.synced),
      ],
      verify: (_) {
        // The repository takes the draft as submitted...
        verify(() => repo.create(_draft)).called(1);
        // ...and what goes out is its op, under the entry it names, so the
        // send carries what a drain's retry would.
        expect(
          verify(() => sender.deliver('q1', captureAny())).captured.single,
          same(created.single.operation),
        );
        verifyNever(() => repo.discardQueuedOp(any()));
      },
    );

    // Every outcome short of a delivery or a refusal leaves the event
    // written and queued, so the create succeeded locally, and a drain
    // sends it.
    for (final (name, delivery) in <(String, SyncDelivery)>[
      ('held by another sender', const SyncNotClaimed()),
      (
        'handed back',
        SyncFailed(SyncFailure.unreachable, Exception('offline')),
      ),
      ('counted', SyncFailed(SyncFailure.serverError, Exception('503'))),
      (
        'a client fault',
        SyncFailed(SyncFailure.invalidOp, ArgumentError('clientRequestId')),
      ),
    ]) {
      blocTest<CreateEventBloc, CreateEventState>(
        '$name -> Success(queued) under the local id',
        setUp: () => stubDeliveries([delivery]),
        build: build,
        act: (bloc) => bloc.add(const CreateEventSubmitted(_draft)),
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_local_1',
            sync: CreateEventSync.queued,
          ),
        ],
      );
    }

    // The claim is the one thing the sender lets throw (a queue disposed
    // with its session). The event is written and queued all the same, so
    // it must not strand the bloc in Submitting, where the guard drops every
    // resubmit.
    blocTest<CreateEventBloc, CreateEventState>(
      'a delivery that throws -> Success(queued)',
      setUp: () {
        when(() => sender.deliver(any(), any()))
            .thenThrow(StateError('disposed'));
      },
      build: build,
      act: (bloc) => bloc.add(const CreateEventSubmitted(_draft)),
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventSuccess(eventId: 'ev_local_1', sync: CreateEventSync.queued),
      ],
    );

    blocTest<CreateEventBloc, CreateEventState>(
      'a refused invitee -> Refused naming them',
      setUp: () => stubDeliveries([
        const SyncParked(
          EventCreateRefusedException(
            'Event create failed with status 404',
            statusCode: 404,
            apiMessage: 'User with ID u2 not found',
          ),
        ),
      ]),
      build: build,
      act: (bloc) => bloc.add(const CreateEventSubmitted(_draft)),
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventRefused(inviteeId: 'u2'),
      ],
    );

    for (final (name, error) in <(String, Object)>[
      // The server's 403 names no one: its gate won't say which invitee it
      // refused, or why. This one's text carries an invitee's id only to
      // show that the bloc reads a name from a 404 alone.
      (
        'a 403 refusal',
        const EventCreateRefusedException(
          'Event create failed with status 403',
          statusCode: 403,
          apiMessage: 'You cannot place u2 on an event',
        ),
      ),
      // Nest's answer for a route it doesn't have, which the remote reads as
      // a refusal too.
      (
        'a 404 whose server text names no invitee',
        const EventCreateRefusedException(
          'Event create failed with status 404',
          statusCode: 404,
          apiMessage: 'Cannot POST /api/events',
        ),
      ),
      // The sender parks every refusal, not only the API's 403 and 404.
      (
        'a 400 the server rejects',
        const EventRemotePermanentException(
          'Event create failed with status 400',
          statusCode: 400,
        ),
      ),
    ]) {
      blocTest<CreateEventBloc, CreateEventState>(
        '$name -> Refused naming no one',
        setUp: () => stubDeliveries([SyncParked(error)]),
        build: build,
        act: (bloc) => bloc.add(const CreateEventSubmitted(_draft)),
        expect: () => const [CreateEventSubmitting(), CreateEventRefused()],
      );
    }

    group('a household refresh', () {
      const inHousehold = EventDraft(title: 'Game night', householdId: 'h1');
      const forbidden = SyncParked(
        EventCreateRefusedException(
          'Event create failed with status 403',
          statusCode: 403,
        ),
      );

      late int refreshes;
      setUp(() => refreshes = 0);

      CreateEventBloc buildRefreshing() => CreateEventBloc(
        repository: repo,
        sender: sender,
        onRefresh: () async => refreshes++,
        logger: logger,
      );

      // The user's role there may have changed on another device, and the
      // form offers only households the cache says they may create in.
      blocTest<CreateEventBloc, CreateEventState>(
        'starts after a 403 for a create in a household',
        setUp: () => stubDeliveries([forbidden]),
        build: buildRefreshing,
        act: (bloc) => bloc.add(const CreateEventSubmitted(inHousehold)),
        expect: () => const [CreateEventSubmitting(), CreateEventRefused()],
        verify: (_) => expect(refreshes, 1),
      );

      for (final (name, draft, delivery) in <(String, EventDraft, SyncParked)>[
        ('a 403 for a create in no household', _draft, forbidden),
        (
          'a 404 for a create in a household',
          inHousehold,
          _unknownInvitee('u2'),
        ),
      ]) {
        blocTest<CreateEventBloc, CreateEventState>(
          "doesn't start after $name",
          setUp: () => stubDeliveries([delivery]),
          build: buildRefreshing,
          act: (bloc) => bloc.add(CreateEventSubmitted(draft)),
          skip: 2,
          verify: (_) => expect(refreshes, 0),
        );
      }

      blocTest<CreateEventBloc, CreateEventState>(
        'that throws is logged, and the refusal stands',
        setUp: () => stubDeliveries([forbidden]),
        build: () => CreateEventBloc(
          repository: repo,
          sender: sender,
          onRefresh: () async => throw StateError('offline'),
          logger: logger,
        ),
        act: (bloc) => bloc.add(const CreateEventSubmitted(inHousehold)),
        expect: () => const [CreateEventSubmitting(), CreateEventRefused()],
        verify: (_) => verify(
          () => logger.warn(
            any(),
            error: any(named: 'error'),
            stackTrace: any(named: 'stackTrace'),
          ),
        ).called(1),
      );
    });

    blocTest<CreateEventBloc, CreateEventState>(
      'a create after a refusal discards the parked op first',
      setUp: () => stubDeliveries([
        _unknownInvitee('u2'),
        const SyncDelivered(eventId: 'ev_server'),
      ]),
      build: build,
      act: (bloc) async {
        await refuse(bloc, _draft);
        bloc.add(const CreateEventSubmitted(_edited));
      },
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventRefused(inviteeId: 'u2'),
        CreateEventSubmitting(),
        CreateEventSuccess(eventId: 'ev_server', sync: CreateEventSync.synced),
      ],
      verify: (_) {
        // The parked op goes, with its local event, before the new draft is
        // created afresh, under its own local id and entry.
        verifyInOrder([
          () => repo.create(_draft),
          () => repo.discardQueuedOp('q1'),
          () => repo.create(_edited),
        ]);
        verifyNoMoreInteractions(repo);
        expect(
          verify(() => sender.deliver('q2', captureAny())).captured.single,
          same(created.last.operation),
        );
      },
    );

    blocTest<CreateEventBloc, CreateEventState>(
      'a second refusal replaces the parked op the next submit discards',
      setUp: () => stubDeliveries([
        _unknownInvitee('u2'),
        _unknownInvitee('u1'),
        const SyncDelivered(eventId: 'ev_server'),
      ]),
      build: build,
      act: (bloc) async {
        await refuse(bloc, _draft);
        await refuse(bloc, _edited);
        bloc.add(const CreateEventSubmitted(_noInvitees));
      },
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventRefused(inviteeId: 'u2'),
        CreateEventSubmitting(),
        CreateEventRefused(inviteeId: 'u1'),
        CreateEventSubmitting(),
        CreateEventSuccess(eventId: 'ev_server', sync: CreateEventSync.synced),
      ],
      verify: (_) {
        verifyInOrder([
          () => repo.discardQueuedOp('q1'),
          () => repo.create(_edited),
          () => repo.discardQueuedOp('q2'),
          () => repo.create(_noInvitees),
        ]);
        // Each parked op is discarded once, and the first never again.
        verifyNever(() => repo.discardQueuedOp(any()));
      },
    );

    // The discard declines: another tab retried the parked create since, or
    // discarded it. The bloc reads what became of it before it answers: a
    // retry stands as the event, and only a discard lets this submit create.
    group('a discard another tab got to first', () {
      setUp(() {
        when(() => repo.discardQueuedOp(any())).thenAnswer((_) async => false);
        when(() => repo.reconciledEventId(any())).thenReturn(null);
      });

      /// Has the watch of the parked event's local id emit [detail] first.
      void watchShows(EventDetail? detail) =>
          when(() => repo.watchEvent(any()))
              .thenAnswer((_) => Stream.value(detail));

      EventDetail detailOf(Event event) => EventDetail(
        snapshot: EventSnapshot(event: event, occurrences: const []),
      );

      blocTest<CreateEventBloc, CreateEventState>(
        'a retry still on its way -> queued under the local id, nothing '
        'created',
        setUp: () {
          stubDeliveries([_unknownInvitee('u2')]);
          watchShows(detailOf(_localEvent('ev_local_1')));
        },
        build: build,
        act: (bloc) async {
          await refuse(bloc, _draft);
          bloc.add(const CreateEventSubmitted(_edited));
        },
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventRefused(inviteeId: 'u2'),
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_local_1',
            sync: CreateEventSync.queued,
          ),
        ],
        verify: (_) {
          verify(() => repo.discardQueuedOp('q1')).called(1);
          verify(() => repo.watchEvent('ev_local_1')).called(1);
          verify(() => repo.create(any())).called(1);
          verify(() => sender.deliver(any(), any())).called(1);
        },
      );

      blocTest<CreateEventBloc, CreateEventState>(
        'a retry that landed under the local id -> synced, nothing created',
        setUp: () {
          stubDeliveries([_unknownInvitee('u2')]);
          watchShows(
            detailOf(
              _localEvent('ev_local_1')
                  .copyWith(isLocalOnly: false, isDirty: false),
            ),
          );
        },
        build: build,
        act: (bloc) async {
          await refuse(bloc, _draft);
          bloc.add(const CreateEventSubmitted(_edited));
        },
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventRefused(inviteeId: 'u2'),
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_local_1',
            sync: CreateEventSync.synced,
          ),
        ],
        verify: (_) => verify(() => repo.create(any())).called(1),
      );

      blocTest<CreateEventBloc, CreateEventState>(
        "a retry that landed under the server's id -> synced under it, "
        'nothing created',
        setUp: () {
          stubDeliveries([_unknownInvitee('u2')]);
          watchShows(null);
          when(() => repo.reconciledEventId('ev_local_1'))
              .thenReturn('ev_server');
        },
        build: build,
        act: (bloc) async {
          await refuse(bloc, _draft);
          bloc.add(const CreateEventSubmitted(_edited));
        },
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventRefused(inviteeId: 'u2'),
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_server',
            sync: CreateEventSync.synced,
          ),
        ],
        verify: (_) {
          // The move is asked after the watch has emitted, which is when the
          // repository has read another tab's.
          verifyInOrder([
            () => repo.watchEvent('ev_local_1'),
            () => repo.reconciledEventId('ev_local_1'),
          ]);
          verify(() => repo.create(any())).called(1);
        },
      );

      blocTest<CreateEventBloc, CreateEventState>(
        'a discard elsewhere -> this submit creates the draft',
        setUp: () {
          stubDeliveries([
            _unknownInvitee('u2'),
            const SyncDelivered(eventId: 'ev_server'),
          ]);
          watchShows(null);
        },
        build: build,
        act: (bloc) async {
          await refuse(bloc, _draft);
          bloc.add(const CreateEventSubmitted(_edited));
        },
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventRefused(inviteeId: 'u2'),
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_server',
            sync: CreateEventSync.synced,
          ),
        ],
        verify: (_) {
          verifyInOrder([
            () => repo.create(_draft),
            () => repo.discardQueuedOp('q1'),
            () => repo.watchEvent('ev_local_1'),
            () => repo.reconciledEventId('ev_local_1'),
            () => repo.create(_edited),
          ]);
          verify(() => sender.deliver(any(), any())).called(2);
        },
      );

      // Without the read, the bloc can't tell a retry from a discard, so it
      // creates nothing and keeps the parked create for the next submit.
      final watchError = StateError('session ended');
      blocTest<CreateEventBloc, CreateEventState>(
        'a watch that fails -> Failure, nothing created, the next submit '
        'reads again',
        setUp: () {
          stubDeliveries([
            _unknownInvitee('u2'),
            const SyncDelivered(eventId: 'ev_server'),
          ]);
          var watches = 0;
          when(() => repo.watchEvent(any())).thenAnswer(
            (_) =>
                ++watches == 1 ? Stream.error(watchError) : Stream.value(null),
          );
        },
        build: build,
        act: (bloc) async {
          await refuse(bloc, _draft);
          bloc.add(const CreateEventSubmitted(_edited));
          await bloc.stream.firstWhere((s) => s is CreateEventFailure);
          bloc.add(const CreateEventSubmitted(_edited));
        },
        expect: () => const [
          CreateEventSubmitting(),
          CreateEventRefused(inviteeId: 'u2'),
          CreateEventSubmitting(),
          CreateEventFailure(),
          CreateEventSubmitting(),
          CreateEventSuccess(
            eventId: 'ev_server',
            sync: CreateEventSync.synced,
          ),
        ],
        verify: (_) {
          verify(() => repo.discardQueuedOp('q1')).called(2);
          verify(() => repo.watchEvent('ev_local_1')).called(2);
          verify(() => repo.create(_edited)).called(1);
          verify(
            () => logger.error(
              any(),
              error: watchError,
              stackTrace: any(named: 'stackTrace'),
            ),
          ).called(1);
        },
      );
    });

    // The op may still be parked, so the bloc keeps it, and creates nothing
    // beside it.
    final discardError = StateError('database is locked');
    blocTest<CreateEventBloc, CreateEventState>(
      'a discard that throws -> Failure, nothing created, the next submit '
      'discards again',
      setUp: () {
        stubDeliveries([
          _unknownInvitee('u2'),
          const SyncDelivered(eventId: 'ev_server'),
        ]);
        var discards = 0;
        when(() => repo.discardQueuedOp(any())).thenAnswer((_) async {
          if (++discards == 1) throw discardError;
          return true;
        });
      },
      build: build,
      act: (bloc) async {
        await refuse(bloc, _draft);
        bloc.add(const CreateEventSubmitted(_edited));
        await bloc.stream.firstWhere((s) => s is CreateEventFailure);
        bloc.add(const CreateEventSubmitted(_edited));
      },
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventRefused(inviteeId: 'u2'),
        CreateEventSubmitting(),
        CreateEventFailure(),
        CreateEventSubmitting(),
        CreateEventSuccess(eventId: 'ev_server', sync: CreateEventSync.synced),
      ],
      verify: (_) {
        verifyInOrder([
          () => repo.create(_draft),
          () => repo.discardQueuedOp('q1'),
          () => repo.discardQueuedOp('q1'),
          () => repo.create(_edited),
        ]);
        // Nothing was created after the discard that threw.
        verifyNoMoreInteractions(repo);
        verify(
          () => logger.error(
            any(),
            error: discardError,
            stackTrace: any(named: 'stackTrace'),
          ),
        ).called(1);
      },
    );

    // A discard that went through took the parked create with it, so a
    // create that throws next leaves nothing parked. The submit after must
    // not discard again: the repository declines an entry it no longer
    // holds, and the bloc would answer for the discarded event instead of
    // creating the new draft.
    blocTest<CreateEventBloc, CreateEventState>(
      'a create that throws after a discard -> Failure, and the next submit '
      'creates without discarding again',
      setUp: () {
        stubDeliveries([_unknownInvitee('u2'), const SyncNotClaimed()]);
        // As the repository answers: the entry goes once, and is unknown
        // after.
        var discards = 0;
        when(() => repo.discardQueuedOp(any()))
            .thenAnswer((_) async => ++discards == 1);
        var creates = 0;
        when(() => repo.create(any())).thenAnswer((invocation) async {
          if (++creates == 2) throw StateError('database is locked');
          return answerCreate(invocation);
        });
      },
      build: build,
      act: (bloc) async {
        await refuse(bloc, _draft);
        bloc.add(const CreateEventSubmitted(_edited));
        await bloc.stream.firstWhere((s) => s is CreateEventFailure);
        bloc.add(const CreateEventSubmitted(_edited));
      },
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventRefused(inviteeId: 'u2'),
        CreateEventSubmitting(),
        CreateEventFailure(),
        CreateEventSubmitting(),
        // The new create's local id: the create that threw wrote nothing.
        CreateEventSuccess(eventId: 'ev_local_2', sync: CreateEventSync.queued),
      ],
      verify: (_) {
        // One discard in all, and three creates: the refused draft, the
        // edited one that threw, and the edited one again.
        verify(() => repo.discardQueuedOp('q1')).called(1);
        verify(() => repo.create(_draft)).called(1);
        verify(() => repo.create(_edited)).called(2);
        verifyNoMoreInteractions(repo);
      },
    );

    blocTest<CreateEventBloc, CreateEventState>(
      'local create failure -> Submitting then Failure, nothing delivered',
      setUp: () {
        when(() => repo.create(any())).thenThrow(
          ArgumentError.value('', 'draft.title', 'must not be blank'),
        );
      },
      build: build,
      act: (bloc) => bloc.add(const CreateEventSubmitted(_draft)),
      expect: () => const [CreateEventSubmitting(), CreateEventFailure()],
      verify: (_) => verifyNever(() => sender.deliver(any(), any())),
    );

    // The disabled submit button is the form's own defence. This is the
    // bloc's, which covers the keyboard's "done" and any other caller that
    // dispatches the event directly.
    blocTest<CreateEventBloc, CreateEventState>(
      'a submit while submitting is ignored',
      build: build,
      act: (bloc) {
        // The first handler runs up to its first await, past the guard and
        // the Submitting emit, so the second event finds Submitting.
        bloc
          ..add(const CreateEventSubmitted(_draft))
          ..add(const CreateEventSubmitted(_draft));
      },
      expect: () => const [
        CreateEventSubmitting(),
        CreateEventSuccess(eventId: 'ev_server', sync: CreateEventSync.synced),
      ],
      verify: (_) {
        verify(() => repo.create(any())).called(1);
        verify(() => sender.deliver(any(), any())).called(1);
      },
    );
  });
}
