import 'package:bge_test_support/widgets.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/cancel_reason_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _reasonKey = Key('test.reason');
const _keepKey = Key('test.keep');
const _confirmKey = Key('test.confirm');
const _tooLong = 'Keep the reason to 1,000 characters or fewer.';

/// The shared cancel-reason dialog (#502): what it hands back, and the
/// reason's length check, counted in code points.
void main() {
  /// What the dialog popped with, once it has.
  var done = false;
  String? value;

  Future<void> open(WidgetTester tester) async {
    done = false;
    value = null;
    useViewSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        locale: const Locale('en', 'US'),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCancelReasonDialog(
                    context,
                    title: 'Cancel it?',
                    body: 'Everyone is told.',
                    keepLabel: 'Keep it',
                    confirmLabel: 'Cancel it',
                    reasonKey: _reasonKey,
                    keepKey: _keepKey,
                    confirmKey: _confirmKey,
                  ).then((result) {
                    done = true;
                    value = result;
                  }),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(_reasonKey), text);
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(_confirmKey));
    await tester.pumpAndSettle();
  }

  testWidgets('returns the trimmed reason', (tester) async {
    await open(tester);
    expect(find.text('Cancel it?'), findsOneWidget);
    expect(find.text('Everyone is told.'), findsOneWidget);
    expect(find.text('Reason (optional)'), findsOneWidget);

    await enter(tester, '  Venue closed  ');
    await confirm(tester);

    expect(done, isTrue);
    expect(value, 'Venue closed');
  });

  testWidgets('returns empty for a blank reason', (tester) async {
    await open(tester);
    await enter(tester, '   ');
    await confirm(tester);

    expect(done, isTrue);
    expect(value, '');
  });

  testWidgets('returns null when kept', (tester) async {
    await open(tester);
    await enter(tester, 'Venue closed');
    await tester.tap(find.byKey(_keepKey));
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(value, isNull);
  });

  testWidgets('refuses 1001 emoji in the field and stays open; takes 1000', (
    tester,
  ) async {
    await open(tester);

    // One emoji is two UTF-16 units; the limit counts code points.
    await enter(tester, '\u{1F600}' * 1001);
    await confirm(tester);
    expect(find.text(_tooLong), findsOneWidget);
    expect(done, isFalse);

    await enter(tester, '\u{1F600}' * 1000);
    await confirm(tester);
    expect(done, isTrue);
    expect(value, '\u{1F600}' * 1000);
  });
}
