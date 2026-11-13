import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

Future<ScaffoldMessengerState> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
  return tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
}

/// Walks the clock past one bar's lifetime in one-second steps.
///
/// Stepped, never one long `pump` and never `pumpAndSettle`, for the reasons
/// on `repeated taps do not stack confirmations` in
/// `feedback_review_screen_test.dart`: a single jump fires the dismiss timer
/// without frames for the exit animation, and `pumpAndSettle` drains a queue
/// of stale bars and reports a clear screen exactly when the bug is present.
Future<void> _pastOneLifetime(WidgetTester tester) async {
  for (var second = 0; second < 8; second++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  group('replaceSnackBar', () {
    testWidgets('shows the message', (tester) async {
      final messenger = await _pumpHost(tester);

      messenger.replaceSnackBar('Saved');
      await tester.pump();

      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('calls in a row leave one bar, gone after one lifetime', (
      tester,
    ) async {
      final messenger = await _pumpHost(tester);

      messenger
        ..replaceSnackBar('a')
        ..replaceSnackBar('b')
        ..replaceSnackBar('c');
      await tester.pump();

      expect(find.text('c'), findsOneWidget);
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsNothing);

      // `findsOneWidget` above holds whether one bar or three are queued,
      // because only the front of the queue is built. Only walking the clock
      // tells them apart.
      await _pastOneLifetime(tester);

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('replaces a bar already showing', (tester) async {
      final messenger = await _pumpHost(tester);

      messenger.replaceSnackBar('first');
      await tester.pump(const Duration(seconds: 1));
      messenger.replaceSnackBar('second');

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);

      await _pastOneLifetime(tester);

      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
