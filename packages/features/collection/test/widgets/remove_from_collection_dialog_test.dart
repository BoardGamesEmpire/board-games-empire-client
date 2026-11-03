import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _openKey = Key('test.open_dialog');

void main() {
  bool? result;

  Future<void> open(
    WidgetTester tester, {
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _openKey,
              onPressed: () async =>
                  result = await showRemoveFromCollectionDialog(
                    context,
                    title: 'Wingspan',
                  ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_openKey));
    // The dialog fades in from nothing, which drops its semantics.
    await tester.pumpAndSettle();
  }

  testWidgets('names the game and says what stays', (tester) async {
    await open(tester);

    expect(find.text('Remove Wingspan?'), findsOneWidget);
    expect(
      find.text(
        'This says you no longer own it. Your plays, rating and comment are '
        'kept, and come back if you add it again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Keep it'), findsOneWidget);
  });

  testWidgets('confirm returns true', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(RemoveFromCollectionDialog.confirmKey));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancel returns false', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(RemoveFromCollectionDialog.cancelKey));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('dismissing by the barrier returns false', (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('lays out at 320dp and 2x text with both buttons on screen', (
    tester,
  ) async {
    useViewSize(tester, const Size(320, 640));
    await open(tester, textScaler: const TextScaler.linear(2));

    expect(tester.takeException(), isNull);
    const screen = Rect.fromLTWH(0, 0, 320, 640);
    for (final key in [
      RemoveFromCollectionDialog.confirmKey,
      RemoveFromCollectionDialog.cancelKey,
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(screen.contains(rect.topLeft), isTrue, reason: '$key');
      expect(screen.contains(rect.bottomRight), isTrue, reason: '$key');
    }
  });
}
