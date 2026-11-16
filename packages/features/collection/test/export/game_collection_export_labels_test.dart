import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';

void main() {
  const expected = (
    name: 'Game collection',
    description:
        'Every game in your collection, with its copies, ratings, comments '
        'and play history.',
  );

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GameCollectionLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    return captured;
  }

  testWidgets('both keys resolve to the same name and description', (
    tester,
  ) async {
    final context = await pumpContext(tester);

    expect(
      gameCollectionExportLabels(context, 'collectionExportName'),
      expected,
    );
    expect(
      gameCollectionExportLabels(context, 'collectionExportDescription'),
      expected,
    );
  });

  testWidgets('an unknown key resolves to null', (tester) async {
    final context = await pumpContext(tester);

    expect(gameCollectionExportLabels(context, 'unknown'), isNull);
  });
}
