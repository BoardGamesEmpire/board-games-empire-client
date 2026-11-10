import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// What the staff households list asks the server for (#685): which
/// households, in what order, and the search as typed.
final class AdminHouseholdQuery extends Equatable {
  const AdminHouseholdQuery({
    this.status = AdminHouseholdStatus.live,
    this.sort = AdminHouseholdSort.name,
    this.text = '',
  }) : // AdminHouseholdSort.allowedWith, spelled out: a const constructor's
       // assert can't call a method.
       assert(
         sort != AdminHouseholdSort.deleted ||
             status != AdminHouseholdStatus.live,
         'the server refuses the deleted sort over live households',
       );

  final AdminHouseholdStatus status;
  final AdminHouseholdSort sort;

  /// The search as typed, untrimmed.
  final String text;

  /// The search the server is sent: [termOf] [text], when the server takes
  /// a term that long, else null, and the list is read unsearched.
  ///
  /// The length is the server's (see
  /// [AdminHouseholdRemoteDataSource.queryLength]), so one emoji is one
  /// character, and no term sent is refused for its length.
  String? get sentQuery {
    final term = termOf(text);
    final length = AdminHouseholdRemoteDataSource.queryLength(term);
    return length >= AdminHouseholdRemoteDataSource.minQueryLength &&
            length <= AdminHouseholdRemoteDataSource.maxQueryLength
        ? term
        : null;
  }

  /// The term [typed] searches for: trimmed, without U+0000. The server
  /// refuses a term holding one, as Postgres stores no text that does, so
  /// no name it could match is lost.
  static String termOf(String typed) => typed.replaceAll('\u0000', '').trim();

  /// Whether this asks the server the same as [other]: any difference is in
  /// text that sends the same search.
  bool readsAs(AdminHouseholdQuery other) =>
      status == other.status &&
      sort == other.sort &&
      sentQuery == other.sentQuery;

  AdminHouseholdQuery copyWith({
    AdminHouseholdStatus? status,
    AdminHouseholdSort? sort,
    String? text,
  }) => AdminHouseholdQuery(
    status: status ?? this.status,
    sort: sort ?? this.sort,
    text: text ?? this.text,
  );

  @override
  List<Object?> get props => [status, sort, text];
}

/// What the staff households list is showing (#685). Each state carries the
/// [query] its content answers.
sealed class AdminHouseholdListState extends Equatable {
  const AdminHouseholdListState({required this.query});

  final AdminHouseholdQuery query;

  @override
  List<Object?> get props => [query];
}

/// The first page is being read from the server.
final class AdminHouseholdListLoading extends AdminHouseholdListState {
  const AdminHouseholdListLoading({super.query = const AdminHouseholdQuery()});
}

/// The server refused: the caller's role may not see every household.
final class AdminHouseholdListRefused extends AdminHouseholdListState {
  const AdminHouseholdListRefused({super.query = const AdminHouseholdQuery()});
}

/// The read failed for a reason that says nothing about access. Retryable.
final class AdminHouseholdListFailed extends AdminHouseholdListState {
  const AdminHouseholdListFailed({super.query = const AdminHouseholdQuery()});
}

/// The server's households under [query], as many pages as were read. May
/// be empty.
final class AdminHouseholdListReady extends AdminHouseholdListState {
  const AdminHouseholdListReady({
    required this.rows,
    super.query = const AdminHouseholdQuery(),
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.restoring = const {},
    this.outcome,
  });

  final List<AdminHouseholdRow> rows;

  /// Whether the server has rows past the ones shown.
  final bool hasMore;

  /// Whether the next page is being read, or waits for the first page to be
  /// read again.
  final bool loadingMore;

  /// Whether the last load more failed. The rows shown are still right, and
  /// load more can be tried again.
  final bool loadMoreFailed;

  /// Ids of the households with a restore in flight.
  final Set<String> restoring;

  /// What the last restore answered, until the person dismisses it, starts
  /// another, or changes the query.
  final AdminHouseholdRestoreOutcome? outcome;

  @override
  List<Object?> get props => [
    ...super.props,
    rows,
    hasMore,
    loadingMore,
    loadMoreFailed,
    restoring,
    outcome,
  ];
}

/// How a restore ended.
enum AdminHouseholdRestoreResult {
  /// The household is live: restored now, or by someone else first.
  restored,

  /// The server has nothing this caller may restore: the household is gone,
  /// or the caller's role may not restore it.
  notRestorable,

  /// The request got no answer that says anything, or the server refused the
  /// request itself.
  failed,
}

/// The last restore's outcome, for the outcome banner.
final class AdminHouseholdRestoreOutcome extends Equatable {
  const AdminHouseholdRestoreOutcome({
    required this.result,
    required this.name,
  });

  final AdminHouseholdRestoreResult result;

  /// The household's name, as its row showed it when the restore started.
  final String name;

  @override
  List<Object?> get props => [result, name];
}
