/// The server's depth ceiling on a paged read (`DEFAULT_MAX_OFFSET`):
/// `(page - 1) * limit` may not exceed it. Every page-based list route
/// validates its query through the same base DTO, so the ceiling is the same
/// on all of them, and the server answers a deeper page with a 400. A source
/// whose interface names the ceiling passes that constant to [checkPage]
/// instead; the value is the same.
const int serverMaxPageDepth = 100000;

/// Refuses a page request the server would reject.
///
/// `page` is 1-based, `limit` is capped at [maxSize], and `(page - 1) * limit`
/// may not exceed [maxDepth]. The server **rejects** each violation with a 400
/// rather than clamping it. A 400 mid-hydrate classifies as permanent, so an
/// out-of-range page would fail the whole sync for a reason the caller could
/// have known locally.
///
/// The checks run in that order: limit, then page, then depth.
void checkPage({
  required int page,
  required int limit,
  required int maxSize,
  required int maxDepth,
}) {
  if (limit < 1 || limit > maxSize) {
    throw ArgumentError.value(
      limit,
      'limit',
      'must be between 1 and $maxSize (the server rejects a larger page '
          'rather than clamping it)',
    );
  }
  if (page < 1) {
    throw ArgumentError.value(page, 'page', 'is 1-based');
  }
  // Divided rather than multiplied: `(page - 1) * limit` wraps on the VM for
  // a large enough page and would land back under the ceiling. For integers,
  // `x * limit > depth` holds exactly when `x > depth ~/ limit`, and `limit`
  // is at least 1 by now.
  if (page - 1 > maxDepth ~/ limit) {
    throw ArgumentError.value(
      page,
      'page',
      '(page - 1) * limit must not exceed $maxDepth',
    );
  }
}

/// Refuses a `clientRequestId` the server would reject.
///
/// The server trims `clientRequestId`, then requires 1 to [maxLength]
/// characters, and answers a violation with a 400. That is permanent, and a
/// permanent create is parked on its first attempt (#121), so a key the caller
/// got wrong is refused here instead, with an error outside the
/// transient/permanent split (#499): the sender counts it as a client fault
/// rather than parking it as the server's verdict.
///
/// This matches the server exactly for ASCII keys, and every key this client
/// mints is a cuid2, which is ASCII. Past ASCII the two can disagree at the
/// edges: Dart's `trim` also strips U+0085, which the server's does not, and
/// the server counts a surrogate pair as one character where `length` counts
/// two.
///
/// The key is still sent untrimmed: the server trims it before storing or
/// matching it, so the two forms are one key.
void checkClientRequestId(String clientRequestId, {required int maxLength}) {
  final length = clientRequestId.trim().length;
  if (length == 0 || length > maxLength) {
    throw ArgumentError.value(
      clientRequestId,
      'clientRequestId',
      'must be 1 to $maxLength characters after trimming (the server '
          'rejects anything else with a 400)',
    );
  }
}

/// Refuses an id that would take its request to another route.
///
/// The id is percent-encoded into the path, but encoding leaves an empty id
/// empty and leaves `.` and `..` alone, and dio resolves those as path
/// segments. So `GET /api/events/` with an empty id reaches the list route,
/// and `/api/data-gateways/..` reaches `/api/`. The answer would then fail to
/// parse and read as the server breaking the contract, or a `DELETE` with no
/// route would 404 and read as the resource being gone, rather than as the
/// caller's mistake (#881).
///
/// An id that only contains dots, such as `...`, is an ordinary segment and
/// passes. So does an id equal to a literal segment beside the id's own:
/// `browse` sent as an event id reaches `GET /api/events/browse`. This guard
/// does not know a route's literal segments; a caller whose literal sibling
/// would do harm refuses it itself, as the member removal refuses `me`.
/// [name] is the argument the error names.
void checkPathId(String id, {String name = 'id'}) {
  checkIdNotEmpty(id, name: name);
  if (id == '.' || id == '..') {
    throw ArgumentError.value(
      id,
      name,
      'must not be "." or ".." (the URL would resolve it to another route)',
    );
  }
}

/// Refuses an empty id that goes in a request body or query rather than the
/// path. There `.` and `..` are only values, so emptiness is the one check.
/// [name] is the argument the error names.
void checkIdNotEmpty(String id, {String name = 'id'}) {
  if (id.isEmpty) {
    throw ArgumentError.value(id, name, 'must not be empty');
  }
}
