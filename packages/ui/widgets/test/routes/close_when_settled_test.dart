import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
  return tester.element(find.byType(SizedBox));
}

/// 0 is "under way", 1 settles with an outcome, 2 settles with none.
class _Harness {
  _Harness(BuildContext context, {this.current = 0}) {
    messenger.attach(context);
  }

  final int current;

  /// Whether the session is live. Read when the save settles, not when the
  /// helper is called, so a test can end it mid-operation.
  bool live = true;
  late final SessionMessenger messenger = SessionMessenger(
    sessionIsLive: () => live,
  );
  final StreamController<int> controller = StreamController<int>.broadcast();
  bool closed = false;

  Future<void> run() => closeWhenSettled<int>(
    current: current,
    states: controller.stream,
    underWay: (s) => s == 0,
    outcomeOf: (s) => s == 1 ? 'Saved' : null,
    say: messenger.say,
    close: () async => closed = true,
  );
}

void main() {
  testWidgets('nothing under way closes at once and says nothing', (
    tester,
  ) async {
    final h = _Harness(await _pumpHost(tester), current: 1);

    await h.run();
    await tester.pump();

    expect(h.closed, isTrue);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a save that settles later is said, then closed', (tester) async {
    final h = _Harness(await _pumpHost(tester));

    final done = h.run();
    await tester.pump();
    expect(h.closed, isFalse);
    h.controller.add(1);
    await done;
    await tester.pump();

    expect(find.text('Saved'), findsOneWidget);
    expect(h.closed, isTrue);
  });

  testWidgets('a state emitted right after the call is not lost', (
    tester,
  ) async {
    final h = _Harness(await _pumpHost(tester));

    // Not awaited: a helper that missed the state would never finish.
    unawaited(h.run());
    h.controller.add(1);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.text('Saved'), findsOneWidget);
    expect(h.closed, isTrue);
  });

  testWidgets('a settled state with no outcome says nothing', (tester) async {
    final h = _Harness(await _pumpHost(tester));

    final done = h.run();
    h.controller.add(2);
    await done;
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(h.closed, isTrue);
  });

  // #694: the user switches mid-operation. Live when the helper is called,
  // ended before the save settles, so a helper that read the lease only at
  // the call would say it.
  testWidgets('a session that ends while the save is under way says '
      'nothing, and still closes', (tester) async {
    final h = _Harness(await _pumpHost(tester));

    final done = h.run();
    await tester.pump();
    h.live = false;
    h.controller.add(1);
    await done;
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(h.closed, isTrue);
  });

  testWidgets('an unmounted messenger says nothing', (tester) async {
    final h = _Harness(await _pumpHost(tester));

    final done = h.run();
    await tester.pumpWidget(const SizedBox());
    h.controller.add(1);
    await done;

    expect(tester.takeException(), isNull);
    expect(h.closed, isTrue);
  });

  testWidgets('a stream that ends unsettled closes and says nothing', (
    tester,
  ) async {
    final h = _Harness(await _pumpHost(tester));

    final done = h.run();
    await h.controller.close();
    await done;
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(h.closed, isTrue);
  });

  testWidgets('a stream error closes, says nothing and is reported', (
    tester,
  ) async {
    final h = _Harness(await _pumpHost(tester));

    final done = h.run();
    h.controller.addError(StateError('boom'));
    await done;
    await tester.pump();

    expect(tester.takeException(), isA<StateError>());
    expect(find.byType(SnackBar), findsNothing);
    expect(h.closed, isTrue);
  });
}
