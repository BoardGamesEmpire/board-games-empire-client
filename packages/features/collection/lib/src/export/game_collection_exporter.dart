import 'package:game_collection/src/sync/game_collection_hydrate_installer.dart';
import 'package:game_collection/src/sync/game_collection_hydration_status.dart';
import 'package:game_collection/src/sync/game_collection_refresher.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// Exports the signed-in user's game collection as a data-export category
/// (#48).
///
/// Reads the local cache, so it works offline. [UserDataExport.confirmed]
/// says whether a hydrate pass inside the collection's staleness window
/// ([GameCollectionHydrateInstaller.staleAfter]) reached the server: without
/// one the entries are this device's copy.
///
/// ## Before the read
///
/// A pass that is running is waited for. A last pass that has aged out of
/// the window is no answer for now, since another device may have changed
/// the collection since, so the export asks for a new one first, as
/// `refresh` does. Either wait ends after [passWait]: a pass still running
/// then leaves the export unconfirmed, and the screen offers to try again.
class GameCollectionExporter implements UserDataExporter {
  /// [passWait] is how long an export waits for a hydrate pass.
  const GameCollectionExporter({this.passWait = defaultPassWait});

  /// How long an export waits for a hydrate pass before it reads the cache
  /// as it is. A pass after a recent one usually reads only what changed
  /// since, in one request; one still running after this is on a network
  /// slow enough that the user is better offered this device's copy.
  static const Duration defaultPassWait = Duration(seconds: 20);

  /// The ARB key of the category's display name, [categoryNameKey].
  static const String nameLabelKey = 'collectionExportName';

  /// The ARB key of the category's description, [descriptionKey].
  static const String descriptionLabelKey = 'collectionExportDescription';

  /// See [defaultPassWait].
  final Duration passWait;

  @override
  String get key => 'gameCollection';

  @override
  String get categoryNameKey => nameLabelKey;

  @override
  String get descriptionKey => descriptionLabelKey;

  @override
  Future<UserDataExport?> export(
    ActiveServer server, {
    bool refresh = false,
  }) async {
    final container = server.container;
    final repository = _lookup<GameCollectionRepository>(container);
    if (repository == null) return null;

    final status = _lookup<GameCollectionHydrationStatus>(container);
    final refresher = _lookup<GameCollectionRefresher>(container);

    final Future<void>? pass;
    if (refresher != null && (refresh || _agedOut(status))) {
      // Joins a pass already running rather than starting a second.
      pass = refresher.refresh();
    } else if (status != null && status.state == HydrationState.running) {
      // A stream that closes first (the session ended mid-pass) ends the
      // wait; the read below then reports what the repository makes of it.
      pass = status
          .watch()
          .firstWhere(
            (reading) => reading.state != HydrationState.running,
            orElse: () => const Hydration(),
          )
          .then((_) {});
    } else {
      pass = null;
    }
    // A pass the wait gives up on goes on, and lands in the cache as usual.
    await pass?.timeout(passWait, onTimeout: () {});

    final items = await repository.watchCollectionListItems().first;
    return UserDataExport(
      {
        'entries': [for (final item in items) _entry(item)],
      },
      // A pass still running, given up on or closed mid-pass, reads
      // `running`: unconfirmed. So does a last pass that aged out with no
      // refresher to run another.
      confirmed:
          status != null &&
          status.state == HydrationState.refreshed &&
          !_agedOut(status),
    );
  }

  /// Whether the last pass landed rows longer ago than the collection's
  /// window. `failed` and `idle` are unconfirmed by state already, and the
  /// screen offers their retry.
  bool _agedOut(GameCollectionHydrationStatus? status) =>
      status != null &&
      status.state == HydrationState.refreshed &&
      status.isStaleAfter(GameCollectionHydrateInstaller.staleAfter);

  /// Not `tryGet`: that reads a throwing factory as absent, and an export
  /// must fail rather than leave a category out. `isRegistered` sees through
  /// a user-scope view to its parent, as `get` does.
  T? _lookup<T extends Object>(DependencyContainer container) =>
      container.isRegistered<T>() ? container.get<T>() : null;

  Map<String, Object?> _entry(GameCollectionListItem item) {
    final entry = item.entry;
    return {
      'gameId': item.gameId,
      'platformGameId': entry.platformGameId,
      'title': item.title,
      'platformName': item.platformName,
      'medium': entry.medium.toWire(),
      'quantity': entry.quantity,
      'releaseId': entry.releaseId,
      'rating': entry.rating,
      'comment': entry.comment,
      'playAgain': entry.playAgain,
      'favorite': entry.favorite,
      'playCount': entry.playCount,
      'lastPlayed': entry.lastPlayed?.toUtc().toIso8601String(),
      'createdAt': entry.createdAt.toUtc().toIso8601String(),
      'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
    };
  }
}
