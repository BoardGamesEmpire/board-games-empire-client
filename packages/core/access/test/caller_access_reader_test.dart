import 'dart:async';

import 'package:access/access.dart';
import 'package:fake_async/fake_async.dart';
import 'package:interfaces/orchestration.dart';
import 'package:logging/logging.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const _loggerName = 'bge.access.test';

const _kept = CallerAccess.known(allAnswer);
const _keptNone = CallerAccess.known(noneAnswer);

void main() {
  late FakeUserRemote remote;
  late FakeGuard guard;

  setUp(() {
    remote = FakeUserRemote();
    guard = FakeGuard();
  });

  CallerAccessReader build({bool guarded = false}) => CallerAccessReader(
    remote: remote,
    resourceTypes: dataGatewayOnly,
    userId: 'user-1',
    guard: guarded ? guard : null,
    logger: BgeLogger(_loggerName),
  );

  /// Every answer [reader] emits from here on.
  List<CallerAccess> emissions(CallerAccessReader reader) {
    final emitted = <CallerAccess>[];
    reader.changes.listen(emitted.add);
    return emitted;
  }

  test('starts unknown', () {
    final reader = build();

    expect(reader.current, const CallerAccess.unknown());
    expect(reader.isAsking, isFalse);
    expect(remote.requests, 0);
  });

  test('changes is one broadcast stream', () {
    final reader = build();

    expect(reader.changes.isBroadcast, isTrue);
    expect(identical(reader.changes, reader.changes), isTrue);
  });

  test('keeps a first answer that allows something', () {
    fakeAsync((async) {
      remote.replies.add(allAnswer);
      final reader = build();
      final emitted = emissions(reader);

      unawaited(reader.refresh());
      async.flushMicrotasks();

      expect(remote.requests, 1);
      expect(reader.current, _kept);
      expect(emitted, [_kept]);
    });
  });

  group('an all-none answer (#456)', () {
    // The server writes a new user's roles after sign-up has answered, so
    // the first owner's first ask can find none of them yet.
    test('asks a first all-none answer once more after two seconds', () {
      fakeAsync((async) {
        remote.replies.addAll([noneAnswer, allAnswer]);
        final reader = build(guarded: true);
        final emitted = emissions(reader);

        unawaited(reader.refresh());
        async.elapse(const Duration(milliseconds: 1999));

        expect(remote.requests, 1);
        expect(reader.current.isKnown, isFalse);

        async.elapse(const Duration(milliseconds: 1));

        expect(remote.requests, 2);
        expect(
          reader.current.allows(ResourceType.dataGateway, AccessAction.read),
          isTrue,
        );
        expect(emitted, [_kept]);
        // Only the answer it keeps is checked against the session.
        expect(guard.askedFor, ['user-1']);
      });
    });

    test('keeps a second all-none answer', () {
      fakeAsync((async) {
        remote.replies.addAll([noneAnswer, noneAnswer]);
        final reader = build();
        final emitted = emissions(reader);

        unawaited(reader.refresh());
        async.elapse(const Duration(seconds: 2));

        expect(remote.requests, 2);
        expect(reader.current.isKnown, isTrue);
        expect(reader.current.deniesEverything, isTrue);
        expect(emitted, [_keptNone]);
      });
    });

    test('does not re-ask an all-none answer once one is known', () {
      fakeAsync((async) {
        remote.replies.addAll([noneAnswer, noneAnswer, noneAnswer]);
        final reader = build();
        final emitted = emissions(reader);
        unawaited(reader.refresh());
        async.elapse(const Duration(seconds: 2));
        expect(remote.requests, 2);

        unawaited(reader.refresh());
        async.elapse(const Duration(seconds: 2));

        expect(remote.requests, 3);
        expect(reader.current, _keptNone);
        // The same answer again is not a change.
        expect(emitted, [_keptNone]);
      });
    });

    test('a failed re-ask keeps the answer unknown', () {
      fakeAsync((async) {
        remote.replies.addAll([
          noneAnswer,
          const UserRemoteTransientException('offline'),
        ]);
        final reader = build();
        final emitted = emissions(reader);

        unawaited(reader.refresh());
        async.elapse(const Duration(seconds: 2));

        expect(remote.requests, 2);
        expect(reader.current, const CallerAccess.unknown());
        expect(emitted, isEmpty);
      });
    });
  });

  test('is asking from the request through the wait before a re-ask', () {
    fakeAsync((async) {
      final first = Completer<Map<ResourceType, ResourceAccess>>();
      remote.replies.addAll([first, allAnswer]);
      final reader = build();

      unawaited(reader.refresh());
      expect(reader.isAsking, isTrue, reason: 'the request is out');

      first.complete(noneAnswer);
      async.elapse(const Duration(seconds: 1));
      expect(reader.isAsking, isTrue, reason: 'waiting to ask again');

      async.elapse(const Duration(seconds: 1));
      expect(reader.isAsking, isFalse, reason: 'settled');
    });
  });

  group('a failed ask keeps the last answer', () {
    test('when the server could not be asked', () {
      fakeAsync((async) {
        final logs = captureLogs(_loggerName);
        const failure = UserRemoteTransientException('offline');
        remote.replies.addAll([allAnswer, failure]);
        final reader = build();
        final emitted = emissions(reader);
        unawaited(reader.refresh());
        async.flushMicrotasks();

        var completed = false;
        unawaited(reader.refresh().then((_) => completed = true));
        async.flushMicrotasks();

        expect(remote.requests, 2);
        expect(completed, isTrue, reason: 'refresh never throws');
        expect(reader.current, _kept);
        expect(emitted, [_kept]);
        expect(logs, hasLength(1));
        expect(logs.single.level, Level.INFO);
        expect(logs.single.error, same(failure));
      });
    });

    test('and when something unexpected failed', () {
      fakeAsync((async) {
        final logs = captureLogs(_loggerName);
        final failure = StateError('a bug');
        remote.replies.addAll([allAnswer, failure]);
        final reader = build();
        unawaited(reader.refresh());
        async.flushMicrotasks();

        var completed = false;
        unawaited(reader.refresh().then((_) => completed = true));
        async.flushMicrotasks();

        expect(completed, isTrue, reason: 'refresh never throws');
        expect(reader.current, _kept);
        expect(logs, hasLength(1));
        expect(logs.single.level, Level.WARNING);
        expect(logs.single.error, same(failure));
      });
    });
  });

  test('calls while one is in flight share one ask after it', () {
    fakeAsync((async) {
      final first = Completer<Map<ResourceType, ResourceAccess>>();
      final second = Completer<Map<ResourceType, ResourceAccess>>();
      remote.replies.addAll([first, second]);
      final reader = build();

      var firstDone = false;
      var laterDone = 0;
      unawaited(reader.refresh().then((_) => firstDone = true));
      unawaited(reader.refresh().then((_) => laterDone++));
      unawaited(reader.refresh().then((_) => laterDone++));
      async.flushMicrotasks();

      expect(remote.requests, 1, reason: 'one ask at a time');

      first.complete(allAnswer);
      async.flushMicrotasks();

      expect(firstDone, isTrue);
      expect(laterDone, 0, reason: 'answered by the ask after it');
      expect(remote.requests, 2, reason: 'the two later calls share one');
      expect(reader.isAsking, isTrue);

      second.complete(allAnswer);
      async.flushMicrotasks();

      expect(laterDone, 2);
      expect(remote.requests, 2);
      expect(reader.isAsking, isFalse);
    });
  });

  test('a call made during an ask keeps the answer of the ask after it', () {
    fakeAsync((async) {
      // A role lowered while the first ask is out: the refusal that follows
      // calls refresh, and the ask after it finds the lower role.
      const updateNone = {
        ResourceType.dataGateway: ResourceAccess(
          create: AccessExtent.all,
          read: AccessExtent.all,
          update: AccessExtent.none,
          delete: AccessExtent.all,
          manage: AccessExtent.all,
        ),
      };
      final first = Completer<Map<ResourceType, ResourceAccess>>();
      remote.replies.addAll([first, updateNone]);
      final reader = build();
      final emitted = emissions(reader);

      unawaited(reader.refresh());
      async.flushMicrotasks();
      unawaited(reader.refresh());
      first.complete(allAnswer);
      async.flushMicrotasks();

      expect(emitted, [_kept, const CallerAccess.known(updateNone)]);
      expect(reader.current, const CallerAccess.known(updateNone));
    });
  });

  test('the ask queued behind one in flight is not sent after dispose', () {
    fakeAsync((async) {
      final first = Completer<Map<ResourceType, ResourceAccess>>();
      remote.replies.add(first);
      final reader = build();

      unawaited(reader.refresh());
      var queuedDone = false;
      unawaited(reader.refresh().then((_) => queuedDone = true));
      async.flushMicrotasks();
      reader.dispose();
      first.complete(allAnswer);
      async.flushMicrotasks();

      expect(remote.requests, 1);
      expect(queuedDone, isTrue, reason: 'refresh never hangs');
    });
  });

  group('drops an answer the guard does not confirm (#432)', () {
    for (final answer in [
      SessionConfirmation.notThisUser,
      SessionConfirmation.unanswered,
    ]) {
      test(answer.name, () {
        fakeAsync((async) {
          final logs = captureLogs(_loggerName);
          remote.replies.add(allAnswer);
          guard.answer = answer;
          final reader = build(guarded: true);
          final emitted = emissions(reader);

          unawaited(reader.refresh());
          async.flushMicrotasks();

          expect(guard.askedFor, ['user-1']);
          expect(reader.current, const CallerAccess.unknown());
          expect(emitted, isEmpty);
          expect(logs, hasLength(1));
          expect(logs.single.level, Level.INFO);
        });
      });
    }
  });

  test('no guard keeps the answer', () {
    fakeAsync((async) {
      remote.replies.add(allAnswer);
      final reader = build();

      unawaited(reader.refresh());
      async.flushMicrotasks();

      expect(reader.current, _kept);
    });
  });

  group('once disposed', () {
    test('an answer landing after dispose is dropped', () {
      fakeAsync((async) {
        final pending = Completer<Map<ResourceType, ResourceAccess>>();
        remote.replies.add(pending);
        final reader = build(guarded: true);
        final emitted = <CallerAccess>[];
        var done = false;
        reader.changes.listen(emitted.add, onDone: () => done = true);

        unawaited(reader.refresh());
        async.flushMicrotasks();
        reader.dispose();
        pending.complete(allAnswer);
        async.flushMicrotasks();

        expect(reader.current, const CallerAccess.unknown());
        expect(emitted, isEmpty);
        expect(guard.askedFor, isEmpty, reason: 'nothing left to confirm');
        expect(done, isTrue, reason: 'dispose closes changes');
      });
    });

    test('an answer the guard confirms after dispose is dropped', () {
      fakeAsync((async) {
        final confirming = Completer<SessionConfirmation>();
        guard.held = confirming;
        remote.replies.add(allAnswer);
        final reader = build(guarded: true);
        final emitted = emissions(reader);

        unawaited(reader.refresh());
        async.flushMicrotasks();
        expect(guard.askedFor, ['user-1']);
        reader.dispose();
        confirming.complete(SessionConfirmation.confirmed);
        async.flushMicrotasks();

        expect(reader.current, const CallerAccess.unknown());
        expect(emitted, isEmpty);
      });
    });

    test('a re-ask still waiting is not sent', () {
      fakeAsync((async) {
        remote.replies.add(noneAnswer);
        final reader = build();

        unawaited(reader.refresh());
        async.flushMicrotasks();
        reader.dispose();
        async.elapse(const Duration(seconds: 2));

        expect(remote.requests, 1);
      });
    });

    test('refresh asks nothing', () {
      fakeAsync((async) {
        final reader = build()..dispose();

        unawaited(reader.refresh());
        async.flushMicrotasks();

        expect(remote.requests, 0);
      });
    });
  });

  test('asks for exactly the types it was given', () {
    fakeAsync((async) {
      remote.replies.add(allAnswer);
      final reader = build();

      unawaited(reader.refresh());
      async.flushMicrotasks();

      expect(remote.asked, [
        {ResourceType.dataGateway},
      ]);
    });
  });
}
