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
