import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
  return tester.element(find.byType(SizedBox));
}

void main() {
  testWidgets('says a message while the session is live', (tester) async {
    SessionMessenger(sessionIsLive: () => true)
      ..attach(await _pumpHost(tester))
      ..say('Saved');
    await tester.pump();

    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a new message replaces the one showing', (tester) async {
    SessionMessenger(sessionIsLive: () => true)
      ..attach(await _pumpHost(tester))
      ..say('First')
      ..say('Second');
    await tester.pumpAndSettle();

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('says nothing once the session has ended (#694)', (
    tester,
  ) async {
    var live = true;
    final messenger = SessionMessenger(sessionIsLive: () => live)
      ..attach(await _pumpHost(tester));

    live = false;
    messenger.say('Saved');
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('says nothing for no message', (tester) async {
    SessionMessenger(sessionIsLive: () => true)
      ..attach(await _pumpHost(tester))
      ..say(null);
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('says nothing once the messenger has gone', (tester) async {
    final messenger = SessionMessenger(sessionIsLive: () => true)
      ..attach(await _pumpHost(tester));

    await tester.pumpWidget(const SizedBox());
    messenger.say('Saved');

    expect(tester.takeException(), isNull);
  });

  test('says nothing before a messenger is attached', () {
    final messenger = SessionMessenger(sessionIsLive: () => true);

    expect(() => messenger.say('Saved'), returnsNormally);
  });
}
