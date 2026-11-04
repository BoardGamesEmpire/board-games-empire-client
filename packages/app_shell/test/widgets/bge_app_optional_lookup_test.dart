import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';

import '../support/active_server_fakes.dart';

/// An optional service whose factory throws reads as absent, so the shell
/// takes its degraded path instead of building an `ErrorWidget` (#218).
///
/// `/auth` is where both scopes meet: the auth scope above it resolves the
/// root [ConnectivityService], and the route resolves the per-server
/// [UnsentChangesNoticeRepository] for the sign-in screen's count.
class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapNeedsAuth(),
    );
    when(() => cubit.orchestrator).thenReturn(null);
  });

  Future<void> pumpAuth(
    WidgetTester tester, {
    required ActiveServer active,
    DependencyContainer? rootContainer,
  }) async {
    when(() => cubit.activeServerScope)
        .thenReturn(FakeActiveServerScope(active));
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, rootContainer: rootContainer),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a throwing root ConnectivityService leaves the auth shell '
      'standing', (tester) async {
    final root = DependencyContainerImpl();
    addTearDown(root.dispose);
    root.registerLazySingleton<ConnectivityService>(
      () => throw StateError('boom'),
    );

    await pumpAuth(
      tester,
      active: buildActiveServer(FakeAuthRepository()),
      rootContainer: root,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(AuthGate), findsOneWidget);
  });

  testWidgets('a throwing per-server UnsentChangesNoticeRepository leaves '
      'the auth gate standing', (tester) async {
    final active = buildActiveServer(FakeAuthRepository());
    active.container.registerLazySingleton<UnsentChangesNoticeRepository>(
      () => throw StateError('boom'),
    );

    await pumpAuth(tester, active: active);

    expect(tester.takeException(), isNull);
    expect(find.byType(AuthGate), findsOneWidget);
  });
}
