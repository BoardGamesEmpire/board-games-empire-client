import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Throws [ArgumentError] unless [size] is one a random sample can ask for:
/// `GET /games/random` and the household game pool sample alike.
void checkSampleSize(int size) {
  const maxSize = GamesRemoteDataSource.maxSampleSize;
  if (size < 1 || size > maxSize) {
    throw ArgumentError.value(
      size,
      'size',
      'must be between 1 and $maxSize (the server rejects anything else '
          'rather than clamping it)',
    );
  }
}

/// Maps a game's `baseGames` to [ExpansionLink]s (#711).
///
/// Null unless [wire] is a list, so a response that did not send the links
/// reads differently from one that sent none. Only each link's `gameId` and
/// `isStandalone` are read: the detail's rows also carry the linked `game`.
List<ExpansionLink>? mapExpansionLinks(Object? wire) {
  if (wire is! List) return null;
  return [
    for (final link in wire.cast<Map<String, dynamic>>())
      ExpansionLink(
        gameId: link['gameId'] as String,
        isStandalone: link['isStandalone'] as bool,
      ),
  ];
}

/// Maps one game of a random sample to a [GameSummary].
///
/// `GET /games/random` and the household game pool sample send the server's
/// game summary (#615): `id`, `title`, `thumbnail` and `description`. The
/// description is not read, because nothing that shows a sample shows it, and
/// there is no field for it. An empty thumbnail is none, as the column can
/// hold one.
GameSummary mapGameSummary(Map<String, dynamic> json) {
  final thumbnail = json['thumbnail'];
  return GameSummary(
    id: json['id'] as String,
    title: json['title'] as String,
    thumbnail: thumbnail is String && thumbnail.isNotEmpty ? thumbnail : null,
  );
}
