import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:observability/observability.dart';

import '../support/active_server_fakes.dart';

/// Pins the `/auth` fallback's diagnostic (#217).
///
/// [AppBootstrapNeedsAuth] pins every location to `/auth`, so reaching the
/// placeholder there means the user is stuck on it. Native bootstrap now
/// fails instead of reporting a server it couldn't restore; the error
/// record is what's left if the fallback is ever reached again.
class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A scope whose active server is gone, as after a failed promotion.
class _EmptyActiveServerScope implements ActiveServerScope {
  @override
  ActiveServer? get active => null;

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(null);
}

void main() {
  late _MockAppBootstrapCubit cubit;
  late List<LogRecord> records;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapNeedsAuth(),
    );
    when(() => cubit.orchestrator).thenReturn(null);

    records = [];
    // SEVERE already clears logging's default INFO threshold, so the root
    // level is left alone rather than leaked into later tests.
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
  });

  /// Scoped to the router's logger, so a SEVERE from another collaborator
  /// can't stand in for this one.
  List<LogRecord> errors() => records
      .where(
        (r) => r.level >= Level.SEVERE && r.loggerName == 'bge.shell.router',
      )
      .toList();

  Future<void> pumpAuth(WidgetTester tester, ActiveServerScope? scope) async {
    when(() => cubit.activeServerScope).thenReturn(scope);
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
  }

  group('/auth fallback diagnostics (#217)', () {
    testWidgets('logs noScope when bootstrap published no active-server '
        'scope', (tester) async {
      await pumpAuth(tester, null);

      expect(errors(), hasLength(1));
      expect((errors().single.object! as ContextLogMessage).context, {
        'cause': 'noScope',
      });
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is ShellPlaceholderScreen &&
              w.kind == ShellPlaceholderKind.auth,
        ),
        findsOneWidget,
      );
    });

    testWidgets('logs noActiveServer when the scope has no active server', (
      tester,
    ) async {
      await pumpAuth(tester, _EmptyActiveServerScope());

      expect(errors(), hasLength(1));
      expect((errors().single.object! as ContextLogMessage).context, {
        'cause': 'noActiveServer',
      });
    });

    testWidgets('logs nothing when an active server backs the route', (
      tester,
    ) async {
      await pumpAuth(
        tester,
        FakeActiveServerScope(buildActiveServer(FakeAuthRepository())),
      );

      expect(errors(), isEmpty);
    });
  });
}
