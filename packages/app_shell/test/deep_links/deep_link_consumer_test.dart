import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';

/// `DeepLinkConsumer` (#82): decides where a held link goes — straight to
/// its location, to the unknown-server screen, or through a server switch
/// first — and coalesces concurrent drains so a newer link wins.
class _FakeLookup implements KnownServerLookup {
  _FakeLookup(this.ids, {this.error, this.gate});

  final Map<String, String> ids;
  final Error? error;
  final Completer<void>? gate;

  int calls = 0;

  @override
  Future<String?> localServerIdFor(String bgeServerId) async {
    calls++;
    final gate = this.gate;
    if (gate != null) await gate.future;
    final error = this.error;
    if (error != null) throw error;
    return ids[bgeServerId];
  }
}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockServerContext extends Mock implements ServerContext {}

void main() {
  const link = NormalizedDeepLink(
    serverId: 'bge-1',
    location: '/server/bge-1/event/e1',
  );

  // Carries a token and a query value, the material the link's redacted
  // `toString` must keep out of a log line.
  const secretLink = NormalizedDeepLink(
    serverId: 'bge-1',
    location: '/server/bge-1/event/e1/rsvp/secret-token?code=secret-code',
  );

  late PendingDeepLinkHolder holder;
  late List<String> gone;
  late bool ready;
  late KnownServerLookup? lookup;
  late _MockServerOrchestrator orchestrator;
  late ServerOrchestrator? boundOrchestrator;

  setUp(() {
    holder = PendingDeepLinkHolder();
    gone = <String>[];
    ready = true;
    lookup = _FakeLookup(const {'bge-1': 'local-1'});
    orchestrator = _MockServerOrchestrator();
    boundOrchestrator = orchestrator;
    when(() => orchestrator.activeServerId).thenReturn('local-1');
    when(() => orchestrator.getContext(any())).thenReturn(null);
    when(() => orchestrator.switchActiveServer(any())).thenAnswer((_) async {});
    when(
      () => orchestrator.connectServer(
        any(),
        makeActive: any(named: 'makeActive'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() => holder.dispose());

  DeepLinkConsumer buildConsumer({
    void Function(DeepLinkFailure failure)? onFailure,
    bool Function(String localId)? isSignedInOn,
  }) {
    final consumer = DeepLinkConsumer(
      holder: holder,
      isReady: () => ready,
      lookup: () => lookup,
      orchestrator: () => boundOrchestrator,
      go: gone.add,
      onFailure: onFailure,
      isSignedInOn: isSignedInOn,
    );
    addTearDown(consumer.dispose);
    return consumer;
  }

  /// Captures every log record for the rest of the test.
  List<LogRecord> captureLogs() {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });
    return records;
  }

  /// A server registered as `local-1` that is connected but not active.
  void connectedInactiveServer() {
    when(() => orchestrator.activeServerId).thenReturn('local-0');
    when(
      () => orchestrator.getContext('local-1'),
    ).thenReturn(_MockServerContext());
  }

  /// As [connectedInactiveServer], and the switch commits `local-1` as
  /// active before its Future completes, as the orchestrator's does.
  void connectedInactiveServerSwitchCommits() {
    connectedInactiveServer();
    var active = 'local-0';
    when(() => orchestrator.activeServerId).thenAnswer((_) => active);
    when(() => orchestrator.switchActiveServer(any())).thenAnswer((
      invocation,
    ) async {
      active = invocation.positionalArguments.single as String;
    });
  }

  group('DeepLinkConsumer', () {
    test('does nothing while not ready', () async {
      ready = false;
      final consumer = buildConsumer();
      holder.set(link);

      await consumer.drain();

      expect(gone, isEmpty);
      expect(holder.peek, link);
      expect((lookup! as _FakeLookup).calls, 0);
    });

    test(
      'with no lookup or orchestrator (web) goes straight to the location',
      () async {
        lookup = null;
        boundOrchestrator = null;
        final consumer = buildConsumer();
        holder.set(
          const NormalizedDeepLink(
            serverId: 'x',
            location: '/server/x/event/e1',
          ),
        );

        await consumer.drain();

        expect(gone, ['/server/x/event/e1']);
        expect(holder.peek, isNull);
      },
    );

    test('a link for the active server goes to its location', () async {
      final consumer = buildConsumer();
      holder.set(link);

      await consumer.drain();

      expect(gone, ['/server/bge-1/event/e1']);
      expect(holder.peek, isNull);
      verifyNever(() => orchestrator.switchActiveServer(any()));
      verifyNever(
        () => orchestrator.connectServer(
          any(),
          makeActive: any(named: 'makeActive'),
        ),
      );
    });

    test(
      'a link for an unknown server goes to the unknown-server screen',
      () async {
        lookup = _FakeLookup(const {});
        final consumer = buildConsumer();
        holder.set(link);

        await consumer.drain();

        expect(gone, [AppRoutes.deepLinkUnknownServer]);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
      },
    );

    test(
      'a connected inactive server is switched to, and the link held until '
      'authenticated',
      () async {
        connectedInactiveServer();
        final consumer = buildConsumer();
        holder.set(link);

        await consumer.drain();

        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        verifyNever(
          () => orchestrator.connectServer(
            any(),
            makeActive: any(named: 'makeActive'),
          ),
        );
        expect(gone, isEmpty);
        expect(holder.peek, link);

        when(() => orchestrator.activeServerId).thenReturn('local-1');
        await consumer.drain();

        expect(gone, [link.location]);
        expect(holder.peek, isNull);
      },
    );

    test(
      'a disconnected registered server is connected and made active',
      () async {
        when(() => orchestrator.activeServerId).thenReturn('local-0');
        final consumer = buildConsumer();
        holder.set(link);

        await consumer.drain();

        verify(
          () => orchestrator.connectServer('local-1', makeActive: true),
        ).called(1);
        verifyNever(() => orchestrator.switchActiveServer(any()));
        expect(gone, isEmpty);
        expect(holder.peek, link);
      },
    );

    test(
      'a second drain before the switch lands does not switch twice',
      () async {
        connectedInactiveServerSwitchCommits();
        final consumer = buildConsumer();
        holder.set(link);

        // Concurrent: the second coalesces into one more pass after the
        // switch, which finds the link's server active but its sign-in
        // outcome not yet known, and leaves the link held.
        await Future.wait([consumer.drain(), consumer.drain()]);

        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        expect(gone, isEmpty);
        expect(holder.peek, link);

        // Sequential, with the app moved off the link's server: the switch
        // happened, so the link is dropped rather than switched to again.
        when(() => orchestrator.activeServerId).thenReturn('local-0');
        await consumer.drain();

        verifyNever(() => orchestrator.switchActiveServer(any()));
        expect(gone, isEmpty);
        expect(holder.peek, isNull);
      },
    );

    test(
      'a link whose server is no longer active after its switch is dropped',
      () async {
        connectedInactiveServer();
        final consumer = buildConsumer();
        holder.set(link);

        await consumer.drain();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        // The switch committed, then the user moved off `local-1`: the mock
        // still answers `local-0`.
        await consumer.drain();

        expect(gone, isEmpty);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));

        // Back on `local-1` later: no surprise landing.
        when(() => orchestrator.activeServerId).thenReturn('local-1');
        await consumer.drain();

        expect(gone, isEmpty);
      },
    );

    test(
      'a switched link replaced by another is switched to again when it '
      'comes back',
      () async {
        connectedInactiveServer();
        final consumer = buildConsumer();
        holder.set(link);

        await consumer.drain();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        // A link for a server this device hasn't added replaces it, and
        // lands on the unknown-server screen.
        holder.set(
          const NormalizedDeepLink(
            serverId: 'bge-9',
            location: '/server/bge-9/event/e9',
          ),
        );
        await consumer.drain();

        expect(gone, [AppRoutes.deepLinkUnknownServer]);
        expect(holder.peek, isNull);

        // The first link sent again, with another server still active: its
        // earlier switch belonged to a link that has since left the slot, so
        // this one is switched to, not dropped.
        holder.set(link);
        await consumer.drain();

        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        expect(holder.peek, link);
      },
    );

    test(
      'a drain requested during a switch does not land the link before the '
      'next signal',
      () async {
        connectedInactiveServer();
        final switching = Completer<void>();
        when(
          () => orchestrator.switchActiveServer(any()),
        ).thenAnswer((_) => switching.future);
        final consumer = buildConsumer();
        holder.set(link);

        final first = consumer.drain();
        await pumpEventQueue();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        // The orchestrator commits the target as active before its Future
        // completes, and a drain arrives in that window.
        when(() => orchestrator.activeServerId).thenReturn('local-1');
        final second = consumer.drain();
        switching.complete();
        await Future.wait([first, second]);

        expect(gone, isEmpty);
        expect(holder.peek, link);

        // The switch's outcome (signed in on the new server) drains again.
        await consumer.drain();

        expect(gone, [link.location]);
        expect(holder.peek, isNull);
      },
    );

    test(
      'a link delivered again after its switch waits for the sign-in outcome',
      () async {
        connectedInactiveServerSwitchCommits();
        final consumer = buildConsumer()..start();
        await pumpEventQueue();

        holder.set(link);
        await pumpEventQueue();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        // Delivered again while the app is still Ready from the old server,
        // before the new one's session is known: it must not land yet, or a
        // server that needs sign-in would bounce it to `/auth` with the link
        // already gone.
        holder.set(link);
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(holder.peek, link);

        // So must another link for the same server.
        const other = NormalizedDeepLink(
          serverId: 'bge-1',
          location: '/server/bge-1/event/e2',
        );
        holder.set(other);
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(holder.peek, other);

        // The sign-in outcome lands the newest.
        await consumer.drain();

        expect(gone, [other.location]);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
      },
    );

    test(
      'a link sent again after the app moved off its switched-to server is '
      'switched to again',
      () async {
        // The switch completes, but the app is on `local-0` again by the
        // next pass: the mock never answers `local-1`.
        connectedInactiveServer();
        buildConsumer().start();
        await pumpEventQueue();

        holder.set(link);
        await pumpEventQueue();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        // The user taps the same link again: a new request, not the one the
        // app moved off.
        holder.set(link);
        await pumpEventQueue();

        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        expect(holder.peek, link);
      },
    );

    // #985: a server switched back to before the auth scope rebuilt keeps
    // its signed-in bloc, so no sign-in outcome will come to drain.
    test(
      'after a switch to a server already signed in, the link lands at once',
      () async {
        connectedInactiveServerSwitchCommits();
        buildConsumer(isSignedInOn: (localId) => localId == 'local-1').start();
        await pumpEventQueue();

        holder.set(link);
        await pumpEventQueue();

        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        expect(gone, [link.location]);
        expect(holder.peek, isNull);
      },
    );

    test(
      'after a switch to a server not signed in, it waits as before',
      () async {
        connectedInactiveServerSwitchCommits();
        // Signed in on the server being left, not the target.
        final consumer = buildConsumer(
          isSignedInOn: (localId) => localId == 'local-0',
        )..start();
        await pumpEventQueue();

        holder.set(link);
        await pumpEventQueue();

        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        expect(gone, isEmpty);
        expect(holder.peek, link);

        await consumer.drain();

        expect(gone, [link.location]);
        expect(holder.peek, isNull);
      },
    );

    test(
      'a newer link arriving during a switch back to a signed-in server '
      'still lands',
      () async {
        const newer = NormalizedDeepLink(
          serverId: 'bge-1',
          location: '/server/bge-1/event/e2',
        );
        connectedInactiveServer();
        var active = 'local-0';
        when(() => orchestrator.activeServerId).thenAnswer((_) => active);
        final switching = Completer<void>();
        when(() => orchestrator.switchActiveServer(any())).thenAnswer((
          invocation,
        ) async {
          active = invocation.positionalArguments.single as String;
          await switching.future;
        });
        buildConsumer(isSignedInOn: (localId) => localId == 'local-1').start();
        await pumpEventQueue();

        holder.set(link);
        await pumpEventQueue();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        holder.set(newer);
        await pumpEventQueue();
        switching.complete();
        await pumpEventQueue();

        // The older link's pass finds itself replaced, and the newer link's
        // pass finds its server active: no wait is left behind for it.
        expect(gone, [newer.location]);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
      },
    );

    test('keeps the link through a switch that ends on the auth leg', () async {
      connectedInactiveServer();
      final consumer = buildConsumer();
      holder.set(link);

      await consumer.drain();
      verify(() => orchestrator.switchActiveServer('local-1')).called(1);

      // The target has no session: the app drops to `/auth`.
      ready = false;
      await consumer.drain();

      expect(gone, isEmpty);
      expect(holder.peek, link);

      // Signed in on the target: the next Ready lands the link.
      ready = true;
      when(() => orchestrator.activeServerId).thenReturn('local-1');
      await consumer.drain();

      expect(gone, [link.location]);
      expect(holder.peek, isNull);
      verifyNever(() => orchestrator.switchActiveServer(any()));
    });

    test('drops the link when the switch throws', () async {
      final records = captureLogs();
      connectedInactiveServer();
      when(
        () => orchestrator.switchActiveServer(any()),
      ).thenAnswer((_) async => throw StateError('local-1 is not connected'));
      final consumer = buildConsumer();
      holder.set(secretLink);

      await consumer.drain();

      expect(gone, isEmpty);
      expect(holder.peek, isNull);
      final warning = records.singleWhere(
        (record) => record.level == Level.WARNING,
      );
      expect(warning.loggerName, 'bge.shell.deep_links');
      expect(warning.error, isA<StateError>());
      expect(warning.stackTrace, isNotNull);
      expect(warning.message, isNot(contains('secret-token')));
      expect(warning.message, isNot(contains('secret-code')));
      expect(warning.message, contains(deepLinkRedactionPlaceholder));
      expect(warning.message, isNot(contains(secretLink.location)));

      // The failed switch is no longer pending: the same link sent again is
      // tried again rather than waiting on a switch that never happened.
      holder.set(secretLink);
      await consumer.drain();

      verify(() => orchestrator.switchActiveServer('local-1')).called(2);
    });

    test('drops the link when the lookup throws', () async {
      final records = captureLogs();
      lookup = _FakeLookup(
        const {'bge-1': 'local-1'},
        error: StateError('registry unreadable'),
      );
      final consumer = buildConsumer();
      holder.set(secretLink);

      await consumer.drain();

      expect(gone, isEmpty);
      expect(holder.peek, isNull);
      final warning = records.singleWhere(
        (record) => record.level == Level.WARNING,
      );
      expect(warning.loggerName, 'bge.shell.deep_links');
      expect(warning.error, isA<StateError>());
      expect(warning.stackTrace, isNotNull);
      expect(warning.message, isNot(contains('secret-token')));
      expect(warning.message, isNot(contains('secret-code')));
      expect(warning.message, contains(deepLinkRedactionPlaceholder));
      expect(warning.message, isNot(contains(secretLink.location)));
      verifyNever(() => orchestrator.switchActiveServer(any()));
    });

    test('reports a failed lookup', () async {
      lookup = _FakeLookup(
        const {'bge-1': 'local-1'},
        error: StateError('registry unreadable'),
      );
      final failures = <DeepLinkFailure>[];
      final consumer = buildConsumer(onFailure: failures.add);
      holder.set(link);

      await consumer.drain();

      expect(failures, [isA<DeepLinkLookupFailed>()]);
      expect(holder.peek, isNull);
    });

    test('reports a failed switch with its error', () async {
      connectedInactiveServer();
      final thrown = StateError('local-1 is not connected');
      when(
        () => orchestrator.switchActiveServer(any()),
      ).thenAnswer((_) async => throw thrown);
      final failures = <DeepLinkFailure>[];
      final consumer = buildConsumer(onFailure: failures.add);
      holder.set(link);

      await consumer.drain();

      expect(failures, hasLength(1));
      final failure = failures.single as DeepLinkActivationFailed;
      expect(failure.error, same(thrown));
    });

    test('a failure report that throws does not stop the consumer', () async {
      captureLogs();
      lookup = _FakeLookup(
        const {'bge-1': 'local-1'},
        error: StateError('registry unreadable'),
      );
      final consumer = buildConsumer(
        onFailure: (_) => throw StateError('no messenger'),
      );
      holder.set(link);

      await consumer.drain();
      expect(holder.peek, isNull);

      lookup = _FakeLookup(const {'bge-1': 'local-1'});
      holder.set(link);
      await consumer.drain();

      expect(gone, [link.location]);
    });

    test('a link dropped because its server is no longer active reports '
        'nothing', () async {
      connectedInactiveServer();
      final failures = <DeepLinkFailure>[];
      final consumer = buildConsumer(onFailure: failures.add);
      holder.set(link);

      await consumer.drain();
      await consumer.drain();

      expect(holder.peek, isNull);
      expect(failures, isEmpty);
    });

    test('a link for an unknown server reports nothing', () async {
      lookup = _FakeLookup(const {});
      final failures = <DeepLinkFailure>[];
      final consumer = buildConsumer(onFailure: failures.add);
      holder.set(link);

      await consumer.drain();

      expect(failures, isEmpty);
    });

    group('a newer link set during a switch', () {
      const older = link;
      const newer = NormalizedDeepLink(
        serverId: 'bge-1',
        location: '/server/bge-1/event/e2',
      );

      /// Starts a consumer and holds [older] until its switch is in flight
      /// on [switching], then holds [newerLink] ([newer] unless given).
      /// Later switch calls succeed at once.
      Future<DeepLinkConsumer> setNewerDuringOlderSwitch(
        Completer<void> switching, {
        NormalizedDeepLink newerLink = newer,
        void Function(DeepLinkFailure failure)? onFailure,
      }) async {
        connectedInactiveServer();
        var switches = 0;
        when(() => orchestrator.switchActiveServer(any())).thenAnswer((_) {
          switches++;
          return switches == 1 ? switching.future : Future<void>.value();
        });
        final consumer = buildConsumer(onFailure: onFailure)..start();
        // Let start's own drain of the empty slot finish, so the older
        // link's arrival starts a pass of its own.
        await pumpEventQueue();

        holder.set(older);
        await pumpEventQueue();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        holder.set(newerLink);
        await pumpEventQueue();
        return consumer;
      }

      test('that succeeds lands the newer link at the next signal', () async {
        final switching = Completer<void>();
        final consumer = await setNewerDuringOlderSwitch(switching);

        // The orchestrator commits the target before its Future completes.
        when(() => orchestrator.activeServerId).thenReturn('local-1');
        switching.complete();
        await pumpEventQueue();

        // The pass the newer link queued runs after the switch, and finds
        // its server active but the sign-in outcome not yet known: the newer
        // link waits for it.
        expect(gone, isEmpty);
        expect(holder.peek, newer);

        await consumer.drain();

        expect(gone, [newer.location]);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
      });

      test(
        'for a server not added is acted on once the switch completes',
        () async {
          const unknown = NormalizedDeepLink(
            serverId: 'bge-9',
            location: '/server/bge-9/event/e9',
          );
          final switching = Completer<void>();
          await setNewerDuringOlderSwitch(switching, newerLink: unknown);

          when(() => orchestrator.activeServerId).thenReturn('local-1');
          switching.complete();
          await pumpEventQueue();

          // The newest link wins without waiting on the older one's sign-in.
          expect(gone, [AppRoutes.deepLinkUnknownServer]);
          expect(holder.peek, isNull);
        },
      );

      test(
        'for another registered server makes that server active once the '
        'switch completes, then waits for its sign-in outcome',
        () async {
          const other = NormalizedDeepLink(
            serverId: 'bge-2',
            location: '/server/bge-2/event/e3',
          );
          lookup = _FakeLookup(const {'bge-1': 'local-1', 'bge-2': 'local-2'});
          var active = 'local-0';
          when(
            () => orchestrator.connectServer(
              any(),
              makeActive: any(named: 'makeActive'),
            ),
          ).thenAnswer((invocation) async {
            active = invocation.positionalArguments.single as String;
          });
          final switching = Completer<void>();
          final consumer = await setNewerDuringOlderSwitch(
            switching,
            newerLink: other,
          );
          when(() => orchestrator.activeServerId).thenAnswer((_) => active);

          // The orchestrator commits the target before its Future completes.
          active = 'local-1';
          switching.complete();
          await pumpEventQueue();

          // `local-2` has no context, so it is connected and made active.
          verify(
            () => orchestrator.connectServer('local-2', makeActive: true),
          ).called(1);
          expect(gone, isEmpty);
          expect(holder.peek, other);

          await consumer.drain();

          expect(gone, [other.location]);
          expect(holder.peek, isNull);
        },
      );

      test('that fails drops the older link, not the newer one', () async {
        final switching = Completer<void>();
        final consumer = await setNewerDuringOlderSwitch(switching);

        switching.completeError(StateError('local-1 is not connected'));
        await pumpEventQueue();

        // The failed switch drops only the older link. The drain the newer
        // link queued still runs, and makes its server active itself.
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);
        expect(gone, isEmpty);
        expect(holder.peek, newer);

        when(() => orchestrator.activeServerId).thenReturn('local-1');
        await consumer.drain();

        expect(gone, [newer.location]);
        expect(holder.peek, isNull);
      });

      test('that fails reports nothing for the older link', () async {
        final records = captureLogs();
        final failures = <DeepLinkFailure>[];
        final switching = Completer<void>();
        final consumer = await setNewerDuringOlderSwitch(
          switching,
          onFailure: failures.add,
        );

        switching.completeError(StateError('local-1 is not connected'));
        await pumpEventQueue();

        // The newer link is the one the user is waiting on: an error for
        // the older one would show over it as it lands. It is still logged.
        expect(failures, isEmpty);
        expect(
          records.where((record) => record.level == Level.WARNING),
          hasLength(1),
        );

        when(() => orchestrator.activeServerId).thenReturn('local-1');
        await consumer.drain();

        expect(gone, [newer.location]);
        expect(failures, isEmpty);
      });
    });

    test('a lookup that fails after a newer link replaced its link reports '
        'nothing, and the newer link lands', () async {
      final records = captureLogs();
      const older = link;
      const newer = NormalizedDeepLink(
        serverId: 'bge-1',
        location: '/server/bge-1/event/e2',
      );
      final gate = Completer<void>();
      lookup = _FakeLookup(
        const {'bge-1': 'local-1'},
        error: StateError('registry unreadable'),
        gate: gate,
      );
      final failures = <DeepLinkFailure>[];
      buildConsumer(onFailure: failures.add).start();
      // Let start's own drain of the empty slot finish, so the older link's
      // arrival starts a pass of its own.
      await pumpEventQueue();

      holder.set(older);
      await pumpEventQueue();
      holder.set(newer);
      // Only the older link's lookup fails.
      lookup = _FakeLookup(const {'bge-1': 'local-1'});
      gate.complete();
      await pumpEventQueue();

      expect(failures, isEmpty);
      expect(gone, [newer.location]);
      expect(holder.peek, isNull);
      expect(
        records.where((record) => record.level == Level.WARNING),
        hasLength(1),
        reason: 'the failed lookup is still logged',
      );
    });

    test('a lookup that fails after dispose reports nothing', () async {
      captureLogs();
      final gate = Completer<void>();
      lookup = _FakeLookup(
        const {'bge-1': 'local-1'},
        error: StateError('registry unreadable'),
        gate: gate,
      );
      final failures = <DeepLinkFailure>[];
      final consumer = buildConsumer(onFailure: failures.add);
      holder.set(link);

      final draining = consumer.drain();
      await pumpEventQueue();
      consumer.dispose();
      gate.complete();
      await draining;

      expect(failures, isEmpty);
    });

    test('a newer link set during the lookup wins', () async {
      const older = link;
      const newer = NormalizedDeepLink(
        serverId: 'bge-1',
        location: '/server/bge-1/event/e2',
      );
      final gate = Completer<void>();
      final fake = _FakeLookup(const {'bge-1': 'local-1'}, gate: gate);
      lookup = fake;
      buildConsumer().start();
      // Let start's own drain of the empty slot finish, so the older link's
      // arrival starts a pass of its own.
      await pumpEventQueue();

      holder.set(older);
      await pumpEventQueue();
      expect(fake.calls, 1, reason: "the older link's pass is in flight");
      holder.set(newer);
      await pumpEventQueue();
      gate.complete();
      await pumpEventQueue();

      expect(gone, [newer.location]);
      expect(holder.peek, isNull);
      expect(fake.calls, 2, reason: 'the newer link ran one more pass');
    });

    test('stops when Ready is lost during the lookup', () async {
      final gate = Completer<void>();
      lookup = _FakeLookup(const {'bge-1': 'local-1'}, gate: gate);
      final consumer = buildConsumer();
      holder.set(link);

      final draining = consumer.drain();
      await pumpEventQueue();
      ready = false;
      gate.complete();
      await draining;

      expect(gone, isEmpty);
      expect(holder.peek, link);

      ready = true;
      await consumer.drain();

      expect(gone, [link.location]);
    });

    test('an equal link set again lands again', () async {
      buildConsumer().start();

      holder.set(link);
      await pumpEventQueue();
      holder.set(
        NormalizedDeepLink(
          serverId: 'bge-1',
          location: ['/server', 'bge-1', 'event', 'e1'].join('/'),
        ),
      );
      await pumpEventQueue();

      expect(gone, hasLength(2));
      expect(gone, everyElement(link.location));
    });

    test('start drains a link held before it', () async {
      holder.set(link);

      buildConsumer().start();
      await pumpEventQueue();

      expect(gone, [link.location]);
      expect(holder.peek, isNull);
    });

    test(
      'dispose stops listening, and a drain in flight goes nowhere',
      () async {
        final gate = Completer<void>();
        final fake = _FakeLookup(const {'bge-1': 'local-1'}, gate: gate);
        lookup = fake;
        final consumer = buildConsumer()..start();

        holder.set(link);
        await pumpEventQueue();
        consumer.dispose();
        gate.complete();
        await pumpEventQueue();

        expect(gone, isEmpty);

        holder.set(
          const NormalizedDeepLink(
            serverId: 'bge-1',
            location: '/server/bge-1/event/e2',
          ),
        );
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(fake.calls, 1);
      },
    );
  });
}
