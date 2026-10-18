import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// [home] inside an app carrying this feature's localizations and theme.
Widget catalogApp(Widget home) => MaterialApp(
  theme: BgeTheme.light(),
  localizationsDelegates: GameCatalogLocalizations.localizationsDelegates,
  supportedLocales: GameCatalogLocalizations.supportedLocales,
  home: home,
);

/// A games cache holding [games], for the screens' offline paths.
///
/// A widget test runs under fake time, which the drift cache's own
/// scheduling does not settle under, so the screens get this instead. The
/// blocs' tests hold the real cache to its contract.
class FakeGamesCache extends Fake implements GameRepository {
  FakeGamesCache([List<Game> games = const []]) : _games = [...games];

  final List<Game> _games;

  @override
  Future<void> cacheGames(List<Game> games) async {}

  @override
  Future<void> cacheGame(Game game) async {}

  @override
  Future<Game?> getGame(String id) async =>
      _games.where((g) => g.id == id).firstOrNull;

  @override
  Future<List<Game>> getGamesPage({int offset = 0, required int limit}) async =>
      _games.skip(offset).take(limit).toList();

  @override
  Future<List<Game>> searchGames(String query, {int limit = 20}) async => _games
      .where((g) => g.title.toLowerCase().contains(query.toLowerCase()))
      .take(limit)
      .toList();
}
