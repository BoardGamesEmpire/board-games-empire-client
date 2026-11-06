import 'package:network_interface/network_interface.dart';

/// What [judgeWholeList] found in a page 1 that says it is the last page.
enum WholeListVerdict {
  /// One consistent read of the whole list: its envelope agrees with itself,
  /// and it sent every row it counts. A row it doesn't name is gone, so it
  /// licenses a purge.
  whole,

  /// Its envelope contradicts itself, so it is no proof of what it left out.
  /// A pass that gets one fails, and purges nothing.
  contradicts,

  /// It sent fewer rows than it counts. Not a contradiction, but not the
  /// API's own answer either, so a pass caches its rows and purges nothing.
  short,
}

/// Whether a page 1 that says it is the last page (`hasMore: false`), with
/// envelope [meta], is the whole list, having sent [rows] rows.
///
/// Shared by the two passes that purge against such a page, `EventHydrator`
/// and `HouseholdEventsHydrator` (#503). Each logs the verdict in its own
/// terms.
///
/// The purge deletes whatever page 1 leaves out, so `hasMore` alone does not
/// license it. A page 1 contradicts itself when it is numbered as another
/// page, counts other than one page, counts more rows than one page holds, or
/// counts fewer rows than it sent. The server derives `totalPages` from
/// `total` over `limit`, rounded up, so a single page counts one, or none
/// when it is empty.
///
/// A page short of its count does not contradict itself, but it is not the
/// API's own answer: the server reads the rows and the count in one
/// REPEATABLE READ, under the same filter, and filters nothing after, so its
/// only page holds every row it counts. A shorter one came through something
/// else, a proxy or a truncated response, and a count it doesn't back up
/// proves nothing about the rows it left out.
WholeListVerdict judgeWholeList(PaginationMeta meta, int rows) {
  if (meta.page != 1 ||
      meta.totalPages != (meta.total == 0 ? 0 : 1) ||
      meta.total > meta.limit ||
      rows > meta.total) {
    return WholeListVerdict.contradicts;
  }
  if (rows < meta.total) return WholeListVerdict.short;
  return WholeListVerdict.whole;
}
