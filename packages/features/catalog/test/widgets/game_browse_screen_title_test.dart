import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// The Games title on the smallest phone, beside everything else its app bar
/// carries (#710).
///
/// A file of its own because it loads the display typeface, which then draws
/// every title in the file: measured in the test font, whose letters are each
/// an em wide, a title that fits a phone reads as cut.
void main() {
  setUpAll(loadDisplayFont);

  for (final scale in [1.0, 2.0]) {
    testWidgets('pushed on a 320dp screen at text scale $scale, the title is '
        'whole', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final remote = FakeGamesRemote()
        ..onFetchPage = (_, _) async => pageOf([game('g_azul')]);

      // Pushed, as the app reaches it, so the app bar has a back button.
      await tester.pumpWidget(catalogApp(const Scaffold(body: Text('home'))));
      Navigator.of(tester.element(find.text('home'))).push(
        MaterialPageRoute<void>(
          builder: (_) => GameBrowseScreen(
            remote: remote,
            onSearch: (_) {},
            layouts: _Thumbnails(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);

      final title = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(AppBar), matching: find.text('Games')),
      );
      expect(
        title.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(title.size.width + 0.5),
        reason: 'the title has ${title.size.width}dp',
      );
    });
  }
}

/// A user who keeps the thumbnails.
class _Thumbnails implements ListLayoutRepository {
  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async =>
      ListLayout.thumbnails;

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {}
}
