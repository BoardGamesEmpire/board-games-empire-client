import 'package:events/src/widgets/held_press.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A button held by [HeldPress] whose action sends something and rebuilds
/// nothing, and whose own action is never over: only the button being
/// available can let the press go.
class _Held extends StatefulWidget {
  const _Held({required this.onAction});

  /// Called as the action runs; it completes true, something sent.
  final VoidCallback onAction;

  @override
  State<_Held> createState() => _HeldState();
}

class _HeldState extends State<_Held> with HeldPress<_Held> {
  @override
  bool get heldActionOver => false;

  @override
  Widget build(BuildContext context) {
    final inert = heldInert(available: true);
    return TextButton(
      onPressed: () => holdPress(() async {
        widget.onAction();
        return true;
      }),
      child: Text(inert ? 'Sending' : 'Send'),
    );
  }
}

/// The press of a button that opens a page and sends what it answers
/// (#516, #607).
void main() {
  testWidgets('a press whose action sent something, and rebuilt nothing, '
      'is let go while the button is available', (tester) async {
    var actions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Held(onAction: () => actions++)),
      ),
    );

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(actions, 1);

    // Shown available, so a press is taken, not ignored.
    expect(find.text('Send'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(actions, 2);
  });
}
