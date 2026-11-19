import 'dart:async';

import 'package:app_shell/src/widgets/auth_route_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:logging/logging.dart';

/// A scope with no server active, whose watch a test can fail.
class _FailingScope implements ActiveServerScope {
  final changes = StreamController<ActiveServer?>.broadcast();

  @override
  ActiveServer? get active => null;

  @override
  Stream<ActiveServer?> watchActive() => changes.stream;
}

void main() {
  /// Every record logged for the rest of the test.
  List<LogRecord> captureLogs() {
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });
    return records;
  }

  // The page stays on the server it has, which is right, but with nothing
  // logged a report of a sign-in screen naming the wrong server could not
  // be explained.
  testWidgets('a failed active-server watch is logged, and the page stays', (
    tester,
  ) async {
    final scope = _FailingScope();
    addTearDown(scope.changes.close);
    final records = captureLogs();
    await tester.pumpWidget(
      MaterialApp(
        home: AuthRouteHost(
          scope: scope,
          splash: const Text('Splash'),
          unsentChangesCountOf: (_) => null,
        ),
      ),
    );
    expect(find.text('Splash'), findsOneWidget);

    final error = StateError('reset');
    scope.changes.addError(error, StackTrace.current);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Splash'), findsOneWidget);
    final logged = records.where(
      (record) => record.loggerName == 'bge.shell.auth_route_host',
    );
    expect(logged, hasLength(1));
    expect(logged.single.level, Level.WARNING);
    expect(logged.single.error, same(error));
    expect(logged.single.stackTrace, isNotNull);
  });
}
