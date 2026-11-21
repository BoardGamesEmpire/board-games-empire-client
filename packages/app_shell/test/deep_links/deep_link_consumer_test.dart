import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter/foundation.dart';
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

/// Answers in the same turn it is asked, as a cached lookup could, so a
/// pass reaches its checks after the lookup without yielding.
class _SynchronousLookup implements KnownServerLookup {
  _SynchronousLookup(this.ids);

  final Map<String, String> ids;

  @override
  Future<String?> localServerIdFor(String bgeServerId) =>
      SynchronousFuture<String?>(ids[bgeServerId]);
}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockServerContext extends Mock implements ServerContext {}

void main() {
  const link = ServerDeepLink(
    serverId: 'bge-1',
    location: '/server/bge-1/event/e1',
  );

  // Carries a token and a query value, the material the link's redacted
  // `toString` must keep out of a log line.
  const secretLink = ServerDeepLink(
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
    const appLink = AppDeepLink(location: '/settings');

    test(
      'an app link goes to its location without a lookup or a switch',
      () async {
        connectedInactiveServer(); // active is local-0: a server link switches
        buildConsumer().start();

        holder.set(appLink);
        await pumpEventQueue();

        expect(gone, ['/settings']);
        expect(holder.peek, isNull);
        expect((lookup! as _FakeLookup).calls, 0);
        verifyNever(() => orchestrator.switchActiveServer(any()));
        verifyNever(
          () => orchestrator.connectServer(
            any(),
            makeActive: any(named: 'makeActive'),
          ),
        );
      },
    );

    test('an app link waits while not ready', () async {
      ready = false;
      final consumer = buildConsumer()..start();

      holder.set(appLink);
      await pumpEventQueue();

      expect(gone, isEmpty);
      expect(holder.peek, appLink);

      ready = true;
      await consumer.drain();

      expect(gone, ['/settings']);
    });

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
          const ServerDeepLink(
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

        expect(gone, [AppRoutes.deepLinkUnknownServerOf(link.location)]);
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
        const unknown = ServerDeepLink(
          serverId: 'bge-9',
          location: '/server/bge-9/event/e9',
        );
        holder.set(unknown);
        await consumer.drain();

        expect(gone, [AppRoutes.deepLinkUnknownServerOf(unknown.location)]);
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
        const other = ServerDeepLink(
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
        const newer = ServerDeepLink(
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

    // #126: settings shows the active server's section, so an app link that
    // landed before the switched-to server's sign-in outcome would open on
    // the old server's.
    group('an app link after a switch', () {
      late String active;
      late Completer<void> switching;

      /// As [connectedInactiveServerSwitchCommits], with the active server
      /// in [active], and a switch that commits its target and then waits
      /// on [switching], as the orchestrator's can.
      void switchCommitsThenWaits() {
        connectedInactiveServer();
        active = 'local-0';
        switching = Completer<void>();
        when(() => orchestrator.activeServerId).thenAnswer((_) => active);
        when(() => orchestrator.switchActiveServer(any())).thenAnswer((
          invocation,
        ) async {
          active = invocation.positionalArguments.single as String;
          await switching.future;
        });
      }

      test('waits for the sign-in outcome of the server switched to', () async {
        switchCommitsThenWaits();
        switching.complete();
        // Signed in on the server being left, not the target.
        final consumer = buildConsumer(
          isSignedInOn: (localId) => localId == 'local-0',
        )..start();
        await pumpEventQueue();

        holder.set(link);
        await pumpEventQueue();
        verify(() => orchestrator.switchActiveServer('local-1')).called(1);

        holder.set(appLink);
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(holder.peek, appLink);

        await consumer.drain();

        expect(gone, ['/settings']);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
      });

      test(
        'set during the switch replaces the server link and waits',
        () async {
          switchCommitsThenWaits();
          final consumer = buildConsumer(
            isSignedInOn: (localId) => localId == 'local-0',
          )..start();
          await pumpEventQueue();

          holder.set(link);
          await pumpEventQueue();
          verify(() => orchestrator.switchActiveServer('local-1')).called(1);

          // `local-1` is already committed as active, and the switch is
          // still in flight.
          holder.set(appLink);
          await pumpEventQueue();
          switching.complete();
          await pumpEventQueue();

          // The server link's pass finds itself replaced; the app link's
          // pass finds the switched-to server's outcome still to come.
          expect(gone, isEmpty);
          expect(holder.peek, appLink);

          await consumer.drain();

          expect(gone, ['/settings']);
          expect(holder.peek, isNull);
          verifyNever(() => orchestrator.switchActiveServer(any()));
        },
      );

      test(
        'set during a switch back to a signed-in server lands once it ends',
        () async {
          switchCommitsThenWaits();
          buildConsumer(
            isSignedInOn: (localId) => localId == 'local-1',
          ).start();
          await pumpEventQueue();

          holder.set(link);
          await pumpEventQueue();
          verify(() => orchestrator.switchActiveServer('local-1')).called(1);

          holder.set(appLink);
          await pumpEventQueue();
          switching.complete();
          await pumpEventQueue();

          // No sign-in outcome is coming for a server the auth scope never
          // left, so nothing is left waiting for one.
          expect(gone, ['/settings']);
          expect(holder.peek, isNull);
          verifyNever(() => orchestrator.switchActiveServer(any()));
        },
      );

      test(
        'lands at once after the app has left the server it waited for',
        () async {
          switchCommitsThenWaits();
          switching.complete();
          buildConsumer(
            isSignedInOn: (localId) => localId == 'local-0',
          ).start();
          await pumpEventQueue();

          holder.set(link);
          await pumpEventQueue();
          verify(() => orchestrator.switchActiveServer('local-1')).called(1);
          expect(holder.peek, link);

          // The user switches back before `local-1`'s outcome arrives; the
          // wait names a server that is no longer active.
          active = 'local-0';
          holder.set(appLink);
          await pumpEventQueue();

          expect(gone, ['/settings']);
          expect(holder.peek, isNull);
          verifyNever(() => orchestrator.switchActiveServer(any()));
        },
      );
    });

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
      const newer = ServerDeepLink(
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
          const unknown = ServerDeepLink(
            serverId: 'bge-9',
            location: '/server/bge-9/event/e9',
          );
          final switching = Completer<void>();
          await setNewerDuringOlderSwitch(switching, newerLink: unknown);

          when(() => orchestrator.activeServerId).thenReturn('local-1');
          switching.complete();
          await pumpEventQueue();

          // The newest link wins without waiting on the older one's sign-in.
          expect(gone, [AppRoutes.deepLinkUnknownServerOf(unknown.location)]);
          expect(holder.peek, isNull);
        },
      );

      test(
        'for another registered server makes that server active once the '
        'switch completes, then waits for its sign-in outcome',
        () async {
          const other = ServerDeepLink(
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
      const newer = ServerDeepLink(
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
      const newer = ServerDeepLink(
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
        ServerDeepLink(
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
          const ServerDeepLink(
            serverId: 'bge-1',
            location: '/server/bge-1/event/e2',
          ),
        );
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(fake.calls, 1);
      },
    );

    group('holdUntilSignedIn', () {
      /// The server just added (`local-2`) is active and signed out, while
      /// the app is still Ready from the server it left (#971).
      void addedServerActive() {
        lookup = _FakeLookup(const {'bge-1': 'local-2'});
        when(() => orchestrator.activeServerId).thenReturn('local-2');
      }

      test('holds the link until that server signs in', () async {
        addedServerActive();
        final consumer = buildConsumer()..start();
        await pumpEventQueue();

        consumer.holdUntilSignedIn(link, 'local-2');
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(holder.peek, link);

        await consumer.drain();
        await pumpEventQueue();

        expect(gone, [link.location]);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
      });

      test('holds the link when the lookup answers at once', () async {
        addedServerActive();
        lookup = _SynchronousLookup(const {'bge-1': 'local-2'});
        final consumer = buildConsumer()..start();
        await pumpEventQueue();

        // The link's arrival runs its pass inside the call, so the wait
        // has to be in place before the link is.
        consumer.holdUntilSignedIn(link, 'local-2');
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(holder.peek, link);
      });

      test('drops the link when the app leaves that server before its '
          'sign-in', () async {
        addedServerActive();
        var active = 'local-2';
        when(() => orchestrator.activeServerId).thenAnswer((_) => active);
        final consumer = buildConsumer()..start();
        await pumpEventQueue();

        consumer.holdUntilSignedIn(link, 'local-2');
        await pumpEventQueue();
        expect(holder.peek, link);

        // From the added server's sign-in, the user goes back to a server
        // they are signed in on, and its authenticated signal drains. The
        // add was this link's switch, so it is not switched to again.
        active = 'local-1';
        await consumer.drain();
        await pumpEventQueue();

        expect(gone, isEmpty);
        expect(holder.peek, isNull);
        verifyNever(() => orchestrator.switchActiveServer(any()));
        verifyNever(
          () => orchestrator.connectServer(
            any(),
            makeActive: any(named: 'makeActive'),
          ),
        );
      });

      // The user changed the link's address, and the server added there is
      // another one (#971). The link waits for that server's sign-in, and
      // then shows the unknown-server screen, rather than routing there at
      // once and skipping the sign-in.
      group("when the server added is not the link's", () {
        void otherServerAdded() {
          lookup = _FakeLookup(const {});
          when(() => orchestrator.activeServerId).thenReturn('local-2');
        }

        test('holds the link until that server signs in, then shows the '
            'unknown-server screen', () async {
          otherServerAdded();
          final consumer = buildConsumer()..start();
          await pumpEventQueue();

          consumer.holdUntilSignedIn(link, 'local-2');
          await pumpEventQueue();

          expect(gone, isEmpty);
          expect(holder.peek, link);

          await consumer.drain();
          await pumpEventQueue();

          expect(gone, [AppRoutes.deepLinkUnknownServerOf(link.location)]);
          expect(holder.peek, isNull);
        });

        test('shows the unknown-server screen even when the app leaves that '
            'server before its sign-in', () async {
          otherServerAdded();
          var active = 'local-2';
          when(() => orchestrator.activeServerId).thenAnswer((_) => active);
          final consumer = buildConsumer()..start();
          await pumpEventQueue();

          consumer.holdUntilSignedIn(link, 'local-2');
          await pumpEventQueue();
          expect(holder.peek, link);

          // The user goes back to a server they are signed in on. The link
          // names no server here, so there is nothing to drop it for
          // leaving, and the screen shows there.
          active = 'local-1';
          await consumer.drain();
          await pumpEventQueue();

          expect(gone, [AppRoutes.deepLinkUnknownServerOf(link.location)]);
          expect(holder.peek, isNull);
          verifyNever(() => orchestrator.switchActiveServer(any()));
        });

        test(
          'a newer link for a server not added still routes at once',
          () async {
            otherServerAdded();
            const newer = ServerDeepLink(
              serverId: 'bge-9',
              location: '/server/bge-9/event/e9',
            );
            final consumer = buildConsumer()..start();
            await pumpEventQueue();
            consumer.holdUntilSignedIn(link, 'local-2');
            await pumpEventQueue();
            expect(gone, isEmpty);

            holder.set(newer);
            await pumpEventQueue();

            expect(gone, [AppRoutes.deepLinkUnknownServerOf(newer.location)]);
            expect(holder.peek, isNull);
          },
        );

        test(
          'a newer link for a registered server still switches at once',
          () async {
            otherServerAdded();
            lookup = _FakeLookup(const {'bge-3': 'local-3'});
            when(
              () => orchestrator.getContext('local-3'),
            ).thenReturn(_MockServerContext());
            const newer = ServerDeepLink(
              serverId: 'bge-3',
              location: '/server/bge-3/event/e3',
            );
            final consumer = buildConsumer()..start();
            await pumpEventQueue();
            consumer.holdUntilSignedIn(link, 'local-2');
            await pumpEventQueue();
            expect(gone, isEmpty);
            expect(holder.peek, link);

            holder.set(newer);
            await pumpEventQueue();

            verify(() => orchestrator.switchActiveServer('local-3')).called(1);
            expect(holder.peek, newer);
          },
        );
      });

      group('when a newer link is held', () {
        const other = ServerDeepLink(
          serverId: 'bge-1',
          location: '/server/bge-1/event/e2',
        );

        test('leaves it in the slot, and holds it until the added server '
            'signs in', () async {
          addedServerActive();
          // The newer link arrived during the add, and its pass is still
          // looking up its server when the add hands the link back.
          final gate = Completer<void>();
          lookup = _FakeLookup(const {'bge-1': 'local-2'}, gate: gate);
          final consumer = buildConsumer()..start();
          holder.set(other);
          await pumpEventQueue();

          consumer.holdUntilSignedIn(link, 'local-2');
          gate.complete();
          await pumpEventQueue();

          // Landing now would take it from the added server's sign-in.
          expect(gone, isEmpty);
          expect(holder.peek, other);

          await consumer.drain();
          await pumpEventQueue();

          expect(gone, [other.location]);
          expect(holder.peek, isNull);
        });

        test('holds a newer app link until the added server signs in, as '
            'after a switch', () async {
          addedServerActive();
          const appLink = AppDeepLink(location: '/games');
          // The app link arrives while another link's pass is still looking
          // up its server, so its own pass is queued behind that one, and
          // runs only after the add hands the link back.
          final gate = Completer<void>();
          lookup = _FakeLookup(const {'bge-1': 'local-2'}, gate: gate);
          final consumer = buildConsumer()..start();
          holder.set(other);
          await pumpEventQueue();
          holder.set(appLink);

          consumer.holdUntilSignedIn(link, 'local-2');
          gate.complete();
          await pumpEventQueue();

          // The page it opens reads the active server, which has no
          // session yet.
          expect(gone, isEmpty);
          expect(holder.peek, appLink);

          await consumer.drain();
          await pumpEventQueue();

          expect(gone, [appLink.location]);
          expect(holder.peek, isNull);
        });

        test('still switches for one whose server is another registered '
            'one', () async {
          addedServerActive();
          const newer = ServerDeepLink(
            serverId: 'bge-3',
            location: '/server/bge-3/event/e3',
          );
          final gate = Completer<void>();
          lookup = _FakeLookup(const {'bge-3': 'local-3'}, gate: gate);
          when(
            () => orchestrator.getContext('local-3'),
          ).thenReturn(_MockServerContext());
          final consumer = buildConsumer()..start();
          holder.set(newer);
          await pumpEventQueue();

          consumer.holdUntilSignedIn(link, 'local-2');
          gate.complete();
          await pumpEventQueue();

          verify(() => orchestrator.switchActiveServer('local-3')).called(1);
          expect(holder.peek, newer);
        });

        test('still routes one for a server not added at once', () async {
          addedServerActive();
          const newer = ServerDeepLink(
            serverId: 'bge-9',
            location: '/server/bge-9/event/e9',
          );
          final gate = Completer<void>();
          lookup = _FakeLookup(const {'bge-1': 'local-2'}, gate: gate);
          final consumer = buildConsumer()..start();
          holder.set(newer);
          await pumpEventQueue();

          consumer.holdUntilSignedIn(link, 'local-2');
          gate.complete();
          await pumpEventQueue();

          // Only the handed-back link waits for the added server's sign-in.
          expect(gone, [AppRoutes.deepLinkUnknownServerOf(newer.location)]);
          expect(holder.peek, isNull);
        });

        test('logs the link it discards', () async {
          addedServerActive();
          final records = captureLogs();
          final gate = Completer<void>();
          lookup = _FakeLookup(const {'bge-1': 'local-2'}, gate: gate);
          final consumer = buildConsumer()..start();
          holder.set(other);
          await pumpEventQueue();

          consumer.holdUntilSignedIn(secretLink, 'local-2');
          gate.complete();
          await pumpEventQueue();

          expect(holder.peek, other);
          final messages = records.map((r) => r.message).toList();
          expect(
            messages,
            contains(
              'Deep link handed back after an add, discarded for a newer '
              'one: $secretLink',
            ),
          );
          // The link's redacted form, never its token or query.
          expect(messages.join(), isNot(contains('secret')));
        });

        // The newer link's server was switched to and needs sign-in, and the
        // user, still on the add form, added the handed-back link's server
        // instead. The newer link would be dropped for the server the add
        // left, so the handed-back one takes the slot, and opens.
        group('whose switch to another server the add left', () {
          const newer = ServerDeepLink(
            serverId: 'bge-3',
            location: '/server/bge-3/event/e3',
          );
          late String active;
          late Completer<void>? switchGate;

          setUp(() {
            active = 'local-1';
            switchGate = null;
            lookup = _FakeLookup(const {
              'bge-1': 'local-2',
              'bge-3': 'local-3',
            });
            when(() => orchestrator.activeServerId).thenAnswer((_) => active);
            when(
              () => orchestrator.getContext('local-3'),
            ).thenReturn(_MockServerContext());
            when(() => orchestrator.switchActiveServer(any())).thenAnswer((
              invocation,
            ) async {
              active = invocation.positionalArguments.single as String;
              await switchGate?.future;
            });
          });

          test('puts the handed-back link in its place', () async {
            final records = captureLogs();
            final consumer = buildConsumer()..start();
            holder.set(newer);
            await pumpEventQueue();
            verify(() => orchestrator.switchActiveServer('local-3')).called(1);
            expect(holder.peek, newer);

            // The add makes its server active, and hands the link back.
            active = 'local-2';
            consumer.holdUntilSignedIn(link, 'local-2');
            await pumpEventQueue();

            expect(holder.peek, link);
            expect(gone, isEmpty);
            expect(
              records.map((r) => r.message),
              contains(
                'Deep link dropped: the add left the server it was switched '
                'to, and the link handed back takes its place: $newer',
              ),
            );

            await consumer.drain();
            await pumpEventQueue();

            expect(gone, [link.location]);
            expect(holder.peek, isNull);
            verifyNever(() => orchestrator.switchActiveServer(any()));
          });

          test('leaves it while its switch is still running', () async {
            switchGate = Completer<void>();
            final consumer = buildConsumer()..start();
            holder.set(newer);
            await pumpEventQueue();

            consumer.holdUntilSignedIn(link, 'local-2');
            await pumpEventQueue();

            expect(holder.peek, newer);
            switchGate!.complete();
            await pumpEventQueue();
            expect(holder.peek, newer);
          });
        });
      });

      test('after dispose does nothing', () async {
        addedServerActive();
        final consumer = buildConsumer()..start();
        await pumpEventQueue();

        consumer
          ..dispose()
          ..holdUntilSignedIn(link, 'local-2');
        await pumpEventQueue();

        expect(holder.peek, isNull);
        expect(gone, isEmpty);
      });
    });
  });
}
