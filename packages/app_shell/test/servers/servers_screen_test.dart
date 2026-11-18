import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/servers/server_list_cubit.dart';
import 'package:app_shell/src/servers/servers_screen.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:models/domain.dart';

import '../support/server_list_fakes.dart';

/// 40 characters: the longest name the audit draws at 320dp and 200% text.
const _longName = 'Riverside Library Tuesday Boardgame Club';

/// The servers on the device, the orchestrator they are connected through,
/// and the app the screen is shown in.
class _Harness {
  _Harness({String alphaName = 'Alpha', this._listing})
    : registered = FakeRegisteredServers([
        testRegisteredServer('alpha', alphaName),
        testRegisteredServer('beta', 'Beta'),
        testRegisteredServer('gamma', 'Gamma'),
      ]),
      orchestrator = FakeServerOrchestrator()
        ..activate('alpha')
        ..connect('beta') {
    addTearDown(registered.close);
    addTearDown(orchestrator.close);
  }

  final FakeRegisteredServers registered;
  final FakeServerOrchestrator orchestrator;
  late final GoRouter router;

  /// What the screen lists from, when it isn't [registered].
  final RegisteredServers? _listing;

  Widget app({ThemeData? theme, String initialLocation = AppRoutes.servers}) {
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (_, _) => const Scaffold(body: Text('Home route')),
        ),
        GoRoute(
          path: AppRoutes.servers,
          builder: (_, _) => ServersScreen(
            create: () => ServerListCubit(
              registered: _listing ?? registered,
              orchestrator: orchestrator,
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.serversAdd,
          builder: (_, _) => const Scaffold(body: Text('Add route')),
        ),
      ],
    );
    addTearDown(router.dispose);
    return MaterialApp.router(
      theme: theme,
      routerConfig: router,
      localizationsDelegates: ShellLocalizations.localizationsDelegates,
      supportedLocales: ShellLocalizations.supportedLocales,
    );
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  /// Holds every switch and connect until the returned completer completes.
  Completer<void> hold() {
    final gate = Completer<void>();
    orchestrator.onActivate = (_) => gate.future;
    return gate;
  }
}

/// A registry that never answers, so the list stays loading.
class _SilentRegisteredServers implements RegisteredServers {
  @override
  Stream<List<ServerConfig>> watch() => Stream.multi((_) {});
}

Finder _row(String id) => find.byKey(ServersScreen.rowKey(id));

Finder _tileOf(String id) =>
    find.descendant(of: _row(id), matching: find.byType(ListTile));

void main() {
  testWidgets('shows each server with its state', (tester) async {
    final semantics = tester.ensureSemantics();
    await _Harness().pump(tester);

    for (final (id, name, state) in [
      ('alpha', 'Alpha', 'In use'),
      ('beta', 'Beta', 'Dormant'),
      ('gamma', 'Gamma', 'Not connected'),
    ]) {
      expect(
        find.descendant(of: _row(id), matching: find.text(name)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row(id), matching: find.text(state)),
        findsOneWidget,
      );
    }
    // The server in use carries the mark, and only it.
    expect(
      find.descendant(of: _row('alpha'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(tester.widget<ListTile>(_tileOf('alpha')).selected, isTrue);
    expect(tester.widget<ListTile>(_tileOf('beta')).selected, isFalse);

    // Each row is one node: its name and its state, and whether it is the
    // one in use. The one in use is the list's selected item, not an
    // unavailable one.
    expect(
      tester.getSemantics(_tileOf('alpha')),
      isSemantics(
        label: 'Alpha\nIn use',
        isButton: true,
        isSelected: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(_tileOf('beta')),
      isSemantics(
        label: 'Beta\nDormant',
        isButton: true,
        isSelected: false,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
      ),
    );

    // The count a screen reader gives ("1 of 3") is what the list holds.
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      3,
    );
    semantics.dispose();
  });

  testWidgets('a pick that succeeds goes home', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);

    await tester.tap(_row('beta'));
    await tester.pumpAndSettle();

    expect(harness.orchestrator.calls, ['switch beta']);
    expect(find.text('Home route'), findsOneWidget);
    expect(find.byType(ServersScreen), findsNothing);
  });

  testWidgets('a pick of the server in use stays and says nothing', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester);

    await tester.tap(_row('alpha'));
    await tester.pumpAndSettle();

    expect(harness.orchestrator.calls, isEmpty);
    expect(find.byType(ServersScreen), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed pick shows the reason and stays', (tester) async {
    final harness = _Harness();
    harness.orchestrator.onActivate = (_) async =>
        throw const ServerCapacityExceededException(
          currentConnected: 3,
          maxCapacity: 5,
        );
    await harness.pump(tester);

    await tester.tap(_row('gamma'));
    await tester.pumpAndSettle();

    // The count differs from the limit, so naming the count fails here.
    expect(
      find.widgetWithText(
        SnackBar,
        'This device connects up to 5 servers at once.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('up to 3 servers'), findsNothing);
    expect(find.byType(ServersScreen), findsOneWidget);
    expect(find.text('Home route'), findsNothing);
    // The server in use is still the one marked so, and the one picked is
    // still not connected.
    expect(
      find.descendant(of: _row('alpha'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(tester.widget<ListTile>(_tileOf('alpha')).selected, isTrue);
    expect(
      find.descendant(of: _row('gamma'), matching: find.text('Not connected')),
      findsOneWidget,
    );
  });

  testWidgets('a pick that fails for another reason says the switch failed', (
    tester,
  ) async {
    final harness = _Harness();
    harness.orchestrator.onActivate = (_) async => throw StateError('boom');
    await harness.pump(tester);

    await tester.tap(_row('beta'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(SnackBar, "Couldn't switch servers. Try again."),
      findsOneWidget,
    );
    expect(find.byType(ServersScreen), findsOneWidget);
  });

  testWidgets('Add server opens the add route', (tester) async {
    await _Harness().pump(tester);

    expect(find.text('Add server'), findsOneWidget);
    await tester.tap(find.byKey(ServersScreen.addKey));
    await tester.pumpAndSettle();

    expect(find.text('Add route'), findsOneWidget);
  });

  testWidgets(
    'while a switch runs, every row ignores a tap and keeps its focus',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = _Harness();
      await harness.pump(tester);
      final gate = harness.hold();

      await tester.tap(_row('beta'));
      await tester.pump();

      // The row being switched to says so, to the eye and to a screen
      // reader; the spinner itself says nothing.
      expect(
        find.descendant(
          of: _row('beta'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(_tileOf('beta')),
        isSemantics(
          label: 'Beta\nDormant\nSwitching…',
          isButton: true,
          isEnabled: false,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      expect(
        tester.getSemantics(_tileOf('gamma')),
        isSemantics(
          label: 'Gamma\nNot connected',
          isEnabled: false,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      // The one in use too, and it stays the selected item.
      expect(
        tester.getSemantics(_tileOf('alpha')),
        isSemantics(
          label: 'Alpha\nIn use',
          isSelected: true,
          isEnabled: false,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      // Never disabled, so a keyboard or screen-reader user's place stays.
      for (final id in ['alpha', 'beta', 'gamma']) {
        final tile = tester.widget<ListTile>(_tileOf(id));
        expect(tile.enabled, isTrue, reason: id);
        expect(tile.focusNode!.canRequestFocus, isTrue, reason: id);
      }

      await tester.tap(_row('gamma'));
      await tester.pump();
      expect(harness.orchestrator.calls, ['switch beta']);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Home route'), findsOneWidget);
      semantics.dispose();
    },
  );

  // A pick that lands goes home, so an add form opened mid-switch would be
  // thrown away with whatever was typed in it.
  testWidgets('while a switch runs, Add server is disabled, and comes back '
      'if the switch fails', (tester) async {
    final semantics = tester.ensureSemantics();
    final harness = _Harness();
    await harness.pump(tester);
    final gate = harness.hold();
    final add = find.byKey(ServersScreen.addKey);

    await tester.tap(_row('gamma'));
    await tester.pump();

    expect(tester.widget<FloatingActionButton>(add).onPressed, isNull);
    expect(
      tester.getSemantics(add),
      isSemantics(
        label: 'Add server',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    await tester.tap(add, warnIfMissed: false);
    await tester.pump();
    expect(find.text('Add route'), findsNothing);
    expect(find.byType(ServersScreen), findsOneWidget);

    gate.completeError(StateError('boom'));
    await tester.pumpAndSettle();

    expect(tester.widget<FloatingActionButton>(add).onPressed, isNotNull);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Add route'), findsOneWidget);
    semantics.dispose();
  });

  group('a pick that fails after Back', () {
    /// The manager pushed over home, with a pick of Gamma held mid-switch.
    Future<(_Harness, Completer<void>)> pickThenLeave(
      WidgetTester tester,
    ) async {
      final harness = _Harness();
      await tester.pumpWidget(harness.app(initialLocation: AppRoutes.home));
      await tester.pumpAndSettle();
      unawaited(harness.router.push<void>(AppRoutes.servers));
      await tester.pumpAndSettle();
      final gate = harness.hold();
      await tester.tap(_row('gamma'));
      await tester.pump();
      Navigator.of(tester.element(find.byType(ServersScreen))).pop();
      return (harness, gate);
    }

    /// The failure is said over the page the user went back to, which
    /// stays where it is.
    void expectReasonOverHome() {
      expect(
        find.widgetWithText(SnackBar, "Couldn't switch servers. Try again."),
        findsOneWidget,
      );
      expect(find.byType(ServersScreen), findsNothing);
      expect(find.text('Home route'), findsOneWidget);
    }

    testWidgets('while the screen is leaving still says why', (tester) async {
      final (_, gate) = await pickThenLeave(tester);

      // The pick fails while the popped route is still mounted.
      gate.completeError(StateError('boom'));
      await tester.idle();
      expect(find.byType(ServersScreen), findsOneWidget);
      await tester.pumpAndSettle();

      expectReasonOverHome();
    });

    testWidgets('still says why', (tester) async {
      final (harness, gate) = await pickThenLeave(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ServersScreen), findsNothing);

      gate.completeError(StateError('boom'));
      await tester.pumpAndSettle();

      expect(harness.orchestrator.calls, ['connect gamma']);
      expectReasonOverHome();
    });
  });

  testWidgets('a list that cannot be read says so and offers a retry', (
    tester,
  ) async {
    final harness = _Harness();
    harness.registered.failNextWatch = StateError('meta database closed');
    await harness.pump(tester);

    expect(find.text("Couldn't list your servers"), findsOneWidget);
    expect(_row('alpha'), findsNothing);

    await tester.tap(find.byKey(ServersScreen.retryKey));
    await tester.pumpAndSettle();

    expect(_row('alpha'), findsOneWidget);
  });

  group('accessibility audit', () {
    // The spinner never settles.
    auditScreen(
      'loading',
      settle: false,
      pump: (tester, theme) async {
        await tester.pumpWidget(
          _Harness(listing: _SilentRegisteredServers()).app(theme: theme),
        );
      },
    );

    auditScreen(
      'failed',
      pump: (tester, theme) async {
        final harness = _Harness();
        harness.registered.failNextWatch = StateError('meta database closed');
        await tester.pumpWidget(harness.app(theme: theme));
      },
    );

    auditScreen(
      'ready',
      pump: (tester, theme) async {
        await tester.pumpWidget(
          _Harness(alphaName: _longName).app(theme: theme),
        );
      },
    );

    // The row's spinner never settles.
    auditScreen(
      'switching',
      settle: false,
      pump: (tester, theme) async {
        final harness = _Harness(alphaName: _longName)..hold();
        await tester.pumpWidget(harness.app(theme: theme));
        await tester.pumpAndSettle();
      },
      arrange: (tester) => tester.tap(_row('beta')),
    );
  });
}
