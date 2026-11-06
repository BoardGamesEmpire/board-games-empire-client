import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The reason the shell gives a control that waits for a connection.
const onlineOnlyCopy = "Available when you're online";

/// [home] inside an app carrying this feature's localizations and theme.
///
/// With [offline], the app is under a [BgeConnectivityScope] that follows it,
/// above the navigator as the shell hosts it, so dialogs read it too.
///
/// [theme] defaults to the light theme. With [textScaler], the app's text is
/// scaled by it, as a user's setting would (#50's accessibility audit).
Widget catalogApp(
  Widget home, {
  ValueListenable<bool>? offline,
  ThemeData? theme,
  TextScaler? textScaler,
}) => MaterialApp(
  theme: theme ?? BgeTheme.light(),
  localizationsDelegates: GameCatalogLocalizations.localizationsDelegates,
  supportedLocales: GameCatalogLocalizations.supportedLocales,
  builder: offline == null && textScaler == null
      ? null
      : (context, child) {
          var app = child!;
          if (textScaler != null) {
            app = MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: app,
            );
          }
          if (offline == null) return app;
          return ValueListenableBuilder<bool>(
            valueListenable: offline,
            child: app,
            builder: (context, isOffline, child) => BgeConnectivityScope(
              offline: isOffline,
              noticeShowing: isOffline,
              onlineOnlyReason: onlineOnlyCopy,
              child: child!,
            ),
          );
        },
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
  Future<void> forgetCatalog() async {}

  @override
  Future<Game?> getGame(String id) async =>
      _games.where((g) => g.id == id).firstOrNull;

  /// Pages [_games] in the order given for [GameSort.title], which the
  /// screens' tests list in title order already, and newest first for
  /// [GameSort.newest], as the real cache does.
  @override
  Future<List<Game>> getGamesPage({
    int offset = 0,
    required int limit,
    GameSort sort = GameSort.title,
  }) async {
    final ordered = switch (sort) {
      GameSort.title => _games,
      GameSort.newest =>
        [..._games]..sort((a, b) {
          final byCreated = b.createdAt.compareTo(a.createdAt);
          return byCreated != 0 ? byCreated : b.id.compareTo(a.id);
        }),
    };
    return ordered.skip(offset).take(limit).toList();
  }

  /// Narrows by content type and finds nothing for a platform type, as the
  /// real cache does. The ranges are ignored: the screens' tests don't search
  /// by them offline, and the drift cache's own tests hold those rules.
  @override
  Future<List<Game>> searchGames(
    String query, {
    int limit = 20,
    GameSearchFilter filter = const GameSearchFilter(),
  }) async {
    final GameSearchFilter(:contentTypes, :platformTypes) = filter;
    if (platformTypes.isNotEmpty) return const [];
    return _games
        .where((g) => g.title.toLowerCase().contains(query.toLowerCase()))
        .where(
          (g) => contentTypes.isEmpty || contentTypes.contains(g.contentType),
        )
        .take(limit)
        .toList();
  }
}
