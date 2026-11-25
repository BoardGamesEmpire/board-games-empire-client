import 'package:api_keys/src/list/api_key_list_event.dart';
import 'package:api_keys/src/list/api_key_list_state.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Drives the key list (#1028): the user's keys a page at a time, filtered
/// by status over the pages loaded, and the permissions they may grant.
///
/// Nothing is stored. Each [ApiKeyListRequested] reads page 1 and the
/// grantable permissions together, and its answer replaces everything
/// loaded. The rows on screen stay while it runs, and stay when it fails:
/// the state then says the refresh failed, and the rows keep their place and
/// their focus. Only a failure with nothing loaded is a load failure.
///
/// ## Overlapping reads
///
/// A read asked for while another runs takes its place: the earlier one's
/// answer is dropped. A More while one is out is dropped too, and so is a
/// More while page 1 is being read, which would page through a listing
/// that's about to be replaced. A More that answers after page 1 was read
/// again belongs to the old listing, so it adds nothing. One that answers
/// after a re-read failed still belongs to the listing on screen, and is
/// added.
///
/// A key made between two reads moves the rest down a page, so the next page
/// can begin with a key already loaded. It is not listed twice.
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
    on<ApiKeyListMoreRequested>(_onMoreRequested, transformer: droppable());
    on<ApiKeyListFilterChanged>(_onFilterChanged);
  }

  final ApiKeyRemoteDataSource _remote;
  final int _pageSize;

  /// The last page loaded.
  int _page = 0;

  /// Counts the answers of page 1 that replaced the loaded keys, so a More
  /// can tell its listing was replaced while it was out.
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
        emit(state.copyWith(status: ApiKeyListStatus.loading));
      case ApiKeyListStatus.loading:
        break;
    }
    // Both start before either is awaited.
    final grantable = _readGrantable();
    final PaginatedResult<ApiKey> first;
    try {
      first = await _remote.fetchPage(limit: _pageSize);
    } on Object {
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
        ),
      );
      return;
    }
    final permissions = await grantable;
    // A read asked for since has taken this one's place.
    if (emit.isDone) return;
    _page = 1;
    _listing++;
    emit(
      ApiKeyListState(
        status: ApiKeyListStatus.loaded,
        keys: _distinct(first.items),
        hasMore: first.meta.hasMore,
        filter: state.filter,
        grantable: permissions,
      ),
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
      return;
    }
    final listing = _listing;
    final page = _page + 1;
    emit(state.copyWith(loadingMore: true, moreFailed: false));
    try {
      final next = await _remote.fetchPage(page: page, limit: _pageSize);
      if (listing != _listing || emit.isDone) return;
      _page = page;
      emit(
        state.copyWith(
          keys: _distinct([...state.keys, ...next.items]),
          hasMore: next.meta.hasMore,
          loadingMore: false,
        ),
      );
    } on Object {
      if (listing != _listing || emit.isDone) return;
      emit(state.copyWith(loadingMore: false, moreFailed: true));
    }
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
