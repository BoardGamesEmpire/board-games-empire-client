import 'dart:async';
import 'dart:typed_data';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/session.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_export/data_export.dart';
import 'package:di/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';
import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _FakeRegistry implements UserDataExportRegistry {
  _FakeRegistry(this.exporters);

  @override
  final List<UserDataExporter> exporters;

  @override
  void register(UserDataExporter exporter) => exporters.add(exporter);
}

/// Answers with whichever server the test made active last.
class _SwitchableScope implements ActiveServerScope {
  _SwitchableScope(this._read);

  final ActiveServer Function() _read;

  @override
  ActiveServer? get active => _read();

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_read());
}

class _FakeSink implements UserDataExportSink {
  @override
  Future<UserDataExportSaveResult> save({
    required String fileName,
    required Uint8List bytes,
  }) => throw UnimplementedError('the wiring tests never save');
}

/// The #93 wiring that lives inside [BgeApp]: that it offers the Settings
/// row, hands the route builder to the router, and applies the condition.
/// The router and entry tests use stand-ins and cannot see those lines.
void main() {
  late _MockAppBootstrapCubit cubit;
  late StreamController<AppBootstrapState> states;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    states = StreamController<AppBootstrapState>();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() => states.close());

  late UserDataExportBundler bundler;

  /// The session lease the active server's container answers with, read
  /// whenever the shell asks for it.
  late SessionLease lease;

  /// The active server, read whenever the shell asks for it.
  late ActiveServer active;

  ActiveServer serverWithLease() {
    final server = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    server.container.registerFactory<SessionLease>(() => lease);
    return server;
  }

  Future<GoRouter> pumpSettings(
    WidgetTester tester, {
    bool withSink = true,
    bool activeServer = true,
  }) async {
    final root = DependencyContainerImpl();
    addTearDown(root.dispose);
    final registry = _FakeRegistry([const GameCollectionExporter()]);
    // The real bundler; the wiring tests never run an export.
    bundler = UserDataExportBundler(
      registry: registry,
      buildInfo: const BuildInfo(
        version: '0.1.0',
        buildNumber: '1',
        appName: 'Board Games Empire',
        packageName: 'com.example.bge',
      ),
    );
    root
      ..registerSingleton<UserDataExportRegistry>(registry)
      ..registerSingleton<UserDataExportBundler>(bundler);
    if (withSink) root.registerSingleton<UserDataExportSink>(_FakeSink());

    lease = FakeSessionLease();
    active = serverWithLease();
    when(
      () => cubit.activeServerScope,
    ).thenReturn(activeServer ? _SwitchableScope(() => active) : null);
    whenListen(
      cubit,
      states.stream,
      initialState: const AppBootstrapInitializing(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit, rootContainer: root));
    await tester.pump();
    states.add(const AppBootstrapReady());
    await tester.pumpAndSettle();
    final router =
        tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter
          ..go(AppRoutes.settings);
    await tester.pumpAndSettle();
    return router;
  }

  group('data export (#93)', () {
    testWidgets('Settings offers "Export your data" for the active server '
        'when the export services are registered', (tester) async {
      await pumpSettings(tester);

      expect(find.text('Export your data'), findsOneWidget);
      // The identity's name, not the display name ("My Server").
      expect(
        find.text('A copy of your data on Test BGE Server'),
        findsOneWidget,
      );
    });

    testWidgets('activating the row opens the export screen', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.text('Export your data'));
      await tester.pumpAndSettle();

      expect(find.byType(DataExportScreen), findsOneWidget);
      expect(find.text('Game collection'), findsOneWidget);
      // The root's bundler is what the screen assembles with.
      expect(
        tester.widget<DataExportScreen>(find.byType(DataExportScreen)).assemble,
        bundler.assemble,
      );
    });

    testWidgets('a new session gets a fresh export screen', (tester) async {
      final router = await pumpSettings(tester);
      router.go(AppRoutes.settingsExport);
      await tester.pumpAndSettle();
      DataExportCubit screenCubit() => tester
          .element(
            find.descendant(
              of: find.byType(DataExportScreen),
              matching: find.byType(Scaffold),
            ),
          )
          .read<DataExportCubit>();
      // go_router builds a page again only when the match list changes, so
      // a page pushed over the export screen and popped rebuilds it in place.
      Future<void> rebuildTheExportPage() async {
        unawaited(router.push(AppRoutes.settings));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
      }

      final first = screenCubit();
      expect(
        tester.widget(find.byType(DataExportScreen)).key,
        ValueKey((active, lease)),
      );

      // The same session: the page is built again, the screen stays.
      await rebuildTheExportPage();
      expect(screenCubit(), same(first));

      // Another session on the same server container: a fresh screen, and
      // nothing the last one held.
      lease = FakeSessionLease();
      await rebuildTheExportPage();
      expect(
        tester.widget(find.byType(DataExportScreen)).key,
        ValueKey((active, lease)),
      );
      expect(screenCubit(), isNot(same(first)));
      expect(first.isClosed, isTrue);
    });

    testWidgets('another server under the same lease gets a fresh export '
        'screen', (tester) async {
      final router = await pumpSettings(tester);
      router.go(AppRoutes.settingsExport);
      await tester.pumpAndSettle();
      DataExportCubit screenCubit() => tester
          .element(
            find.descendant(
              of: find.byType(DataExportScreen),
              matching: find.byType(Scaffold),
            ),
          )
          .read<DataExportCubit>();
      final first = screenCubit();

      // Two signed-out servers share the one `const` lease, so the server
      // is what tells their screens apart.
      active = serverWithLease();
      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(
        tester.widget<DataExportScreen>(find.byType(DataExportScreen)).server,
        same(active),
      );
      expect(screenCubit(), isNot(same(first)));
      expect(first.isClosed, isTrue);
    });

    testWidgets('Back from the export screen returns to Settings', (
      tester,
    ) async {
      final router = await pumpSettings(tester);
      await tester.tap(find.text('Export your data'));
      await tester.pumpAndSettle();
      expect(find.byType(DataExportScreen), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.byType(DataExportScreen), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('no row, and /settings/export falls back, when the sink is '
        'not registered', (tester) async {
      final router = await pumpSettings(tester, withSink: false);

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Export your data'), findsNothing);

      router.go(AppRoutes.settingsExport);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(DataExportScreen), findsNothing);
    });

    testWidgets('no row when no server is active', (tester) async {
      await pumpSettings(tester, activeServer: false);

      expect(find.text('Export your data'), findsNothing);
    });
  });
}
