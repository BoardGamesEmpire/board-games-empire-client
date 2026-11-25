import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:api_keys/src/list/api_key_list_event.dart';
import 'package:api_keys/src/list/api_key_list_state.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Drives the key list (#1028): the user's keys a page at a time, filtered
/// by status over the pages loaded, and the permissions they may grant.
///
/// Nothing is stored. Each [ApiKeyListRequested] reads again every page
/// loaded, or page 1 when none is, with the grantable permissions, and its
/// answer replaces everything loaded. So a key opened from page 3 still has
/// its row, and its focus, when the list reads again on its page closing.
/// The rows on screen stay while it runs, and stay when it fails:
/// the state then says the refresh failed, and the rows keep their place and
/// their focus. Only a failure with nothing loaded is a load failure, which
/// keeps why in [ApiKeyListState.loadFailure].
///
/// ## Overlapping reads
///
/// A read asked for while another runs takes its place: the earlier one's
/// answer is dropped. So does a More asked for while one is out, and a More
/// while the pages are being read again is dropped, as it would page
/// through a listing that's about to be replaced. A More that answers while
/// they are read again adds nothing either: the re-read only asked for the
/// pages loaded when it started, so rows added meanwhile would vanish as it
/// lands. A More that answers after the pages were read again belongs to the
/// old listing, so it adds nothing, and More can be pressed again at once.
/// One that answers after a re-read failed still belongs to the listing on
/// screen, and is added.
///
/// ## Keys made or removed between reads
///
/// The server counts pages from the newest key, so a key made or removed
/// between two reads moves every later key down or up. Each answer says how
/// many keys there are: a More whose count differs from the last read's
/// reads again every page up to its own, so no key is skipped and none is
/// listed twice. A key made and another removed between the same two reads
/// leave the count as it was, and then the next page can repeat a key, which
/// is listed once, or skip one, which shows at the next read.
///
/// ## The grantable permissions
///
/// They give each row its highest risk level. A failed read leaves them
/// null and never fails the list, whose rows then give a count alone. More
/// doesn't read them again.
class ApiKeyListBloc extends Bloc<ApiKeyListEvent, ApiKeyListState> {
  ApiKeyListBloc(
    this._remote, {
    this._pageSize = ApiKeyRemoteDataSource.defaultPageSize,
  }) : super(const ApiKeyListState()) {
    on<ApiKeyListRequested>(_onRequested, transformer: restartable());
    on<ApiKeyListMoreRequested>(_onMoreRequested, transformer: restartable());
    on<ApiKeyListFilterChanged>(_onFilterChanged);
  }

  final ApiKeyRemoteDataSource _remote;
  final int _pageSize;

  /// The last page loaded.
  int _page = 0;

  /// How many keys the server had at the last read.
  int _total = 0;

  /// Counts the reads that replaced the loaded keys, so a More can tell its
  /// listing was replaced while it was out.
  int _listing = 0;

  Future<void> _onRequested(
    ApiKeyListRequested event,
    Emitter<ApiKeyListState> emit,
  ) async {
    // A bloc's first emit is not compared with its initial state, so the
    // spinner it starts on is not emitted again.
    switch (state.status) {
      case ApiKeyListStatus.loaded:
        emit(state.copyWith(refreshing: true));
      case ApiKeyListStatus.loadFailed:
        emit(
          state.copyWith(
            status: ApiKeyListStatus.loading,
            loadFailure: () => null,
          ),
        );
      case ApiKeyListStatus.loading:
        break;
    }
    // Every page loaded, so no row on screen goes: page 1 when none is.
    final pages = _page < 1 ? 1 : _page;
    // Both start before either is awaited.
    final grantable = _readGrantable();
    final _Pages read;
    try {
      read = await _readPages(pages);
    } on Object catch (error) {
      if (emit.isDone) return;
      if (state.status == ApiKeyListStatus.loaded) {
        // The rows stay where they are, focus with them, and the screen says
        // they may be out of date.
        emit(state.copyWith(refreshing: false, refreshFailed: true));
        return;
      }
      _page = 0;
      emit(
        ApiKeyListState(
          status: ApiKeyListStatus.loadFailed,
          filter: state.filter,
          loadFailure: apiKeyFailureOf(error),
        ),
      );
      return;
    }
    final permissions = await grantable;
    // A read asked for since has taken this one's place.
    if (emit.isDone) return;
    _page = pages;
    _total = read.total;
    _listing++;
    emit(
      ApiKeyListState(
        status: ApiKeyListStatus.loaded,
        keys: read.keys,
        hasMore: read.hasMore,
        filter: state.filter,
        grantable: permissions,
      ),
    );
  }

  /// Pages 1 to [pages], read together, as one listing.
  Future<_Pages> _readPages(int pages) async {
    final answers = await Future.wait([
      for (var page = 1; page <= pages; page++)
        _remote.fetchPage(page: page, limit: _pageSize),
    ]);
    final last = answers.last.meta;
    return (
      keys: _distinct([for (final answer in answers) ...answer.items]),
      hasMore: last.hasMore,
      total: last.total,
    );
  }

  /// The permissions the user may grant, by slug, or null when the read
  /// fails. Never throws.
  Future<Map<String, GrantablePermission>?> _readGrantable() async {
    try {
      final permissions = await _remote.fetchGrantable();
      return {
        for (final permission in permissions) permission.slug: permission,
      };
    } on Object {
      return null;
    }
  }

  Future<void> _onMoreRequested(
    ApiKeyListMoreRequested event,
    Emitter<ApiKeyListState> emit,
  ) async {
    if (state.status != ApiKeyListStatus.loaded ||
        !state.hasMore ||
        state.refreshing) {
      // This More took the place of any still out, whose answer adds
      // nothing now: one still saying it loads would say so for ever.
      if (state.loadingMore) emit(state.copyWith(loadingMore: false));
      return;
    }
    final listing = _listing;
    final page = _page + 1;
    emit(state.copyWith(loadingMore: true, moreFailed: false));
    try {
      final next = await _remote.fetchPage(page: page, limit: _pageSize);
      if (_dropped(listing, emit)) return;
      if (next.meta.total == _total) {
        _page = page;
        emit(
          state.copyWith(
            keys: _distinct([...state.keys, ...next.items]),
            hasMore: next.meta.hasMore,
            loadingMore: false,
          ),
        );
        return;
      }
      // Keys were made or removed since the last read, which moved this
      // page: every page up to it is read again, so none is skipped.
      final read = await _readPages(page);
      if (_dropped(listing, emit)) return;
      _page = page;
      _total = read.total;
      emit(
        state.copyWith(
          keys: read.keys,
          hasMore: read.hasMore,
          loadingMore: false,
        ),
      );
    } on Object {
      if (_dropped(listing, emit)) return;
      emit(state.copyWith(loadingMore: false, moreFailed: true));
    }
  }

  /// Whether a More's answer is to be dropped: [listing] was replaced while it
  /// was out, or the pages are being read again now. The re-read only asked
  /// for the pages loaded when it started, so rows added now would vanish
  /// when it lands. A More dropped that way settles, so it doesn't say it
  /// loads for ever.
  bool _dropped(int listing, Emitter<ApiKeyListState> emit) {
    if (listing != _listing || emit.isDone) return true;
    if (!state.refreshing) return false;
    emit(state.copyWith(loadingMore: false));
    return true;
  }

  void _onFilterChanged(
    ApiKeyListFilterChanged event,
    Emitter<ApiKeyListState> emit,
  ) => emit(state.copyWith(filter: event.filter));

  /// [keys] with each id once, at its first place.
  static List<ApiKey> _distinct(List<ApiKey> keys) {
    final seen = <String>{};
    return [
      for (final key in keys)
        if (seen.add(key.id)) key,
    ];
  }
}

/// Pages read together: their keys, each once, whether a page follows the
/// last, and how many keys the server has.
typedef _Pages = ({List<ApiKey> keys, bool hasMore, int total});
