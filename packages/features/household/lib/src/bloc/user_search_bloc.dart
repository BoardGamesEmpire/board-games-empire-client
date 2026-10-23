import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'user_search_event.dart';
import 'user_search_state.dart';

/// Finds users to invite by account, as the person types (#455).
///
/// A query is sent once typing pauses for [debounce], and only when it is
/// at least [HouseholdInviteRemoteDataSource.minSearchLength] characters
/// after trimming: the server refuses a shorter one. Each new query replaces
/// the one before it, whether that one is still waiting out its pause or
/// already asking, so the results shown are always for the latest query.
class UserSearchBloc extends Bloc<UserSearchEvent, UserSearchState> {
  UserSearchBloc({
    required this._remote,
    this.debounce = const Duration(milliseconds: 300),
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.invites.search'),
       super(const UserSearchIdle()) {
    on<UserSearchQueryChanged>(_onQueryChanged, transformer: restartable());
  }

  /// How long typing must pause before a query is sent.
  final Duration debounce;

  final HouseholdInviteRemoteDataSource _remote;
  final BgeLogger _logger;

  Future<void> _onQueryChanged(
    UserSearchQueryChanged event,
    Emitter<UserSearchState> emit,
  ) async {
    final query = event.query.trim();
    if (query.length < HouseholdInviteRemoteDataSource.minSearchLength) {
      emit(const UserSearchIdle());
      return;
    }

    // Before the pause, not after: the last query's results would otherwise
    // stay pickable through it, and a pick among them would outlast them.
    emit(const UserSearchLoading());
    await Future<void>.delayed(debounce);
    // A newer query arrived during the pause.
    if (emit.isDone) return;

    try {
      final page = await _remote.searchUsers(query);
      emit(UserSearchResults(page.items));
    } on Object catch (error, stackTrace) {
      _logger.warn('User search failed', error: error, stackTrace: stackTrace);
      emit(const UserSearchFailed());
    }
  }
}
