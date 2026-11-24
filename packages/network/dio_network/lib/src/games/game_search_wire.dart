import 'package:dio_network/src/network/non_empty_string.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

// What a game search says and hears, apart from how it travels: the REST
// search and the `games/search` socket both go through these, so the two
// transports map and validate alike (#473).

/// Maps one search hit, which is how a row of the REST search's body and a
/// `search:result` frame's result both become a [GameSearchHit].
///
/// Shared by the REST search and the `games/search` socket so both transports
/// map alike (#473, #558).
GameSearchHit mapSearchHit(Map<String, dynamic> json) => GameSearchHit(
  externalId: json['externalId'] as String,
  title: json['title'] as String,
  contentType: _searchContentType(json['contentType'] as String),
  // The server's id only means "on this server" alongside `inSystem`.
  gameId: json['inSystem'] == true ? json['gameId'] as String? : null,
  yearPublished: json['yearPublished'] as int?,
  minPlayers: json['minPlayers'] as int?,
  maxPlayers: json['maxPlayers'] as int?,
  // A DataGateway's unset proto string arrives as "", not absent.
  thumbnailUrl: nonEmptyString(json['thumbnailUrl']),
  summary: nonEmptyString(json['summary']),
  platforms: [
    for (final p
        in (json['platforms'] as List? ?? const [])
            .cast<Map<String, dynamic>>())
      GameSearchPlatform(
        name: p['name'] as String,
        abbreviation: nonEmptyString(p['abbreviation']),
        platformType: _searchPlatformType(p['platformType'] as String),
      ),
  ],
);

/// The proto name of each content type a DataGateway result may carry
/// (`bge.gateway.v1.ContentType`), with its stored name.
const Map<String, String> _protoContentTypes = {
  'CONTENT_TYPE_BASE_GAME': 'BaseGame',
  'CONTENT_TYPE_EXPANSION': 'Expansion',
  'CONTENT_TYPE_DLC': 'DLC',
  'CONTENT_TYPE_STANDALONE_EXPANSION': 'StandaloneExpansion',
  'CONTENT_TYPE_ACCESSORY': 'Accessory',
  'CONTENT_TYPE_BUNDLE': 'Bundle',
  'CONTENT_TYPE_REMAKE': 'Remake',
  'CONTENT_TYPE_REMASTER': 'Remaster',
  'CONTENT_TYPE_EXPANDED_EDITION': 'ExpandedEdition',
  'CONTENT_TYPE_PORT': 'Port',
  'CONTENT_TYPE_MOD': 'Mod',
};

/// As [_protoContentTypes], for `bge.gateway.v1.PlatformType`.
const Map<String, String> _protoPlatformTypes = {
  'PLATFORM_TYPE_TABLETOP': 'Tabletop',
  'PLATFORM_TYPE_CONSOLE': 'Console',
  'PLATFORM_TYPE_PORTABLE': 'Portable',
  'PLATFORM_TYPE_PC': 'PC',
  'PLATFORM_TYPE_MOBILE': 'Mobile',
  'PLATFORM_TYPE_ARCADE': 'Arcade',
  'PLATFORM_TYPE_OTHER': 'Other',
};

/// Reads either naming scheme (backend#662). An unspecified or
/// unrecognised proto name falls through to `unknown`, as an unknown stored
/// name does.
ContentType _searchContentType(String wire) =>
    ContentType.fromWire(_protoContentTypes[wire] ?? wire);

PlatformType _searchPlatformType(String wire) =>
    PlatformType.fromWire(_protoPlatformTypes[wire] ?? wire);

/// Refuses a page [limit] the server would answer with a 400 rather than
/// clamping it.
///
/// Shared by the REST search and the `games/search` socket so both transports
/// validate alike (#473).
void checkPageLimit(int limit) {
  const maxPageSize = GamesRemoteDataSource.maxPageSize;
  if (limit < 1 || limit > maxPageSize) {
    throw ArgumentError.value(
      limit,
      'limit',
      'must be between 1 and $maxPageSize (the server rejects a larger '
          'page rather than clamping it)',
    );
  }
}

/// Refuses a search the server would answer with a 400: a [limit] or
/// [offset] out of range, a filter naming an unknown kind, or a range out of
/// bounds or reversed.
///
/// Shared by the REST search and the `games/search` socket so both transports
/// validate alike (#473).
void checkSearchArguments({
  required int limit,
  required int offset,
  required GameSearchFilter filter,
}) {
  checkPageLimit(limit);
  if (offset < 0 || offset > GamesRemoteDataSource.maxDepth) {
    throw ArgumentError.value(
      offset,
      'offset',
      'must be between 0 and ${GamesRemoteDataSource.maxDepth}',
    );
  }
  final GameSearchFilter(:contentTypes, :platformTypes) = filter;
  if (contentTypes.contains(ContentType.unknown)) {
    // The server refuses `Unknown` as a filter: it names no kind of game.
    throw ArgumentError.value(
      contentTypes,
      'contentTypes',
      'cannot name ContentType.unknown',
    );
  }
  if (platformTypes.contains(PlatformType.unknown)) {
    throw ArgumentError.value(
      platformTypes,
      'platformTypes',
      'cannot name PlatformType.unknown',
    );
  }
  _checkRange(
    filter.publishYear,
    'publishYear',
    lowest: GamesRemoteDataSource.minRangeBound,
  );
  _checkRange(
    filter.playerCount,
    'playerCount',
    lowest: GamesRemoteDataSource.minPlayerCount,
  );
  _checkRange(
    filter.playTime,
    'playTime',
    lowest: GamesRemoteDataSource.minPlayTime,
  );
}

/// Refuses a [range] the server would answer with a 400: a bound below
/// [lowest] or past an int32, or a minimum above the maximum.
void _checkRange(
  GameSearchRange range,
  String name, {
  required int lowest,
}) {
  for (final bound in [range.min, range.max]) {
    if (bound != null &&
        (bound < lowest || bound > GamesRemoteDataSource.maxRangeBound)) {
      throw ArgumentError.value(
        range,
        name,
        'bounds must be between $lowest and '
        '${GamesRemoteDataSource.maxRangeBound}',
      );
    }
  }
  if (range.isReversed) {
    throw ArgumentError.value(range, name, 'min is above max');
  }
}

/// [filter] as typed wire fields: a set as a `List<String>` of wire names,
/// a bound as its `int`, and the include-unknown flag as `true` only when
/// set. An axis that names nothing contributes no field.
///
/// Shared by the REST search, which stringifies and comma-joins these into
/// its query, and the `games/search` socket, which sends them as they are,
/// so both transports name the filter alike (#473).
Map<String, Object> searchFilterFields(GameSearchFilter filter) => {
  if (filter.contentTypes.isNotEmpty)
    'contentTypes': [for (final t in filter.contentTypes) t.toWire()],
  if (filter.platformTypes.isNotEmpty)
    'platformTypes': [for (final t in filter.platformTypes) t.toWire()],
  ..._rangeFields('publishYear', filter.publishYear),
  ..._rangeFields('playerCount', filter.playerCount),
  ..._rangeFields('playTime', filter.playTime),
};

/// [range]'s fields, named from [prefix]: none without a bound, and the
/// include-unknown flag only when set, as `true`.
Map<String, Object> _rangeFields(String prefix, GameSearchRange range) => {
  if (range.narrows) ...{
    '${prefix}Min': ?range.min,
    '${prefix}Max': ?range.max,
    if (range.includeUnknown) '${prefix}IncludeUnknown': true,
  },
};
