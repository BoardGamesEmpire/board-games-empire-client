/// Pagination metadata carried by every backend list endpoint (backend#230).
///
/// The backend standardised one envelope across every list route, so this
/// type is deliberately shared rather than per-resource: a household page and
/// a collection page differ in their rows, never in their paging.
///
/// Paging is **page-based**. `offset` does not exist on the wire — the API's
/// global validation pipe runs `forbidNonWhitelisted`, so an `offset` query
/// parameter is rejected with a 400 rather than ignored.
class PaginationMeta {
  const PaginationMeta({
    required this.page,
    required this.limit,
    required this.total,
    required this.totalPages,
    required this.hasMore,
  });

  /// Reads the `pagination` object from a list envelope.
  ///
  /// Throws [FormatException] — naming the offending field — when the object
  /// does not carry the full contract. Every field is required: the backend
  /// builds this envelope from one shared helper, so a partial object means
  /// the response came from somewhere other than the API, and guessing at the
  /// missing half would turn that into a plausible-looking page.
  factory PaginationMeta.fromJson(Map<String, dynamic> json) => PaginationMeta(
    page: _read<int>(json, 'page'),
    limit: _read<int>(json, 'limit'),
    total: _read<int>(json, 'total'),
    totalPages: _read<int>(json, 'totalPages'),
    hasMore: _read<bool>(json, 'hasMore'),
  );

  /// The 1-based page this response represents.
  final int page;

  /// The page size the server applied. May be smaller than the page size
  /// asked for only because the server capped it; it is never inferred from
  /// the row count.
  final int limit;

  /// Total rows matching the query across all pages.
  ///
  /// Unconditional — there is no opt-in count flag (backend D-230-2) — and
  /// scope-consistent with the rows, which are counted in the same
  /// `REPEATABLE READ` transaction that selected them.
  final int total;

  /// Total number of pages at this [limit].
  final int totalPages;

  /// Whether a further page exists after this one.
  ///
  /// This is the terminator for a drain loop. Do **not** infer the end of a
  /// list from a page shorter than [limit]: that heuristic predates this
  /// envelope and is wrong against a filtered query.
  final bool hasMore;

  static T _read<T>(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! T) {
      throw FormatException(
        value == null
            ? 'pagination is missing "$field"'
            : 'pagination field "$field" is ${value.runtimeType}, expected $T',
      );
    }
    return value;
  }
}

/// One page of [T], with the paging metadata that produced it.
class PaginatedResult<T> {
  const PaginatedResult({required this.items, required this.meta});

  /// Reads a list envelope — `{ <key>: [...], pagination: {...} }` — mapping
  /// each row with [item].
  ///
  /// Throws [FormatException] when the envelope is not the API's own shape.
  /// Callers translate that into their own failure taxonomy; this type stays
  /// free of any one resource's exceptions so it can be shared across them.
  factory PaginatedResult.fromEnvelope(
    Map<String, dynamic> json, {
    required String key,
    required T Function(Map<String, dynamic> json) item,
  }) {
    final rows = json[key];
    if (rows is! List) {
      throw FormatException(
        rows == null
            ? 'response is missing the "$key" array'
            : 'response field "$key" is ${rows.runtimeType}, expected a list',
      );
    }

    final pagination = json['pagination'];
    if (pagination is! Map<String, dynamic>) {
      throw FormatException(
        pagination == null
            ? 'response is missing the "pagination" object'
            : 'response field "pagination" is ${pagination.runtimeType}, '
                  'expected an object',
      );
    }

    return PaginatedResult(
      items: rows
          .map((row) {
            // Checked rather than cast: a bare `as` would throw TypeError and
            // break this factory's documented FormatException contract, leaving
            // each caller to guess which of the two it has to catch.
            if (row is! Map<String, dynamic>) {
              throw FormatException(
                'a row in "$key" is ${row.runtimeType}, expected an object',
              );
            }
            return item(row);
          })
          .toList(growable: false),
      meta: PaginationMeta.fromJson(pagination),
    );
  }

  /// The rows on this page, in the server's order.
  final List<T> items;

  /// The paging metadata for this page.
  final PaginationMeta meta;
}
