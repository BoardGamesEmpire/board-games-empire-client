import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';

import 'package:user_search/l10n/user_search_localizations.dart';

import 'user_search_bloc.dart';
import 'user_search_state.dart';

/// What a user search found, as rows to pick from (#455, #499).
///
/// Reads the [UserSearchBloc] above it. While the query is too short to send
/// it draws nothing, and while the server is asked a progress bar. A search
/// that matched no one, or failed, says so, and one that matched draws a row
/// for each user: their name, and under it their username when the name is a
/// profile name.
///
/// What is picked is the caller's. [isPicked] marks a user's row selected and
/// checked, for as many users as it answers true for: a form that takes one
/// person answers true for one, and a form that takes several for each. A tap
/// goes to [onPick] with that row's user, and the caller decides what that
/// does to its picks.
class UserSearchResultList extends StatelessWidget {
  const UserSearchResultList({
    required this.isPicked,
    required this.onPick,
    required this.resultKey,
    super.key,
  });

  /// Whether [user] is picked. A picked user's row is selected and checked.
  final bool Function(UserSummary user) isPicked;

  /// Called with the user whose row is tapped. Null while the caller can take
  /// no pick, such as while it is sending: the rows are still drawn, but none
  /// can be tapped.
  final void Function(UserSummary user)? onPick;

  /// The key of the row for the user with [userId]. The caller's, so that its
  /// tests keep finding rows by the keys they already use.
  final Key Function(String userId) resultKey;

  @override
  Widget build(BuildContext context) {
    final l10n = UserSearchLocalizations.of(context);
    final theme = Theme.of(context);

    return BlocBuilder<UserSearchBloc, UserSearchState>(
      builder: (context, state) => switch (state) {
        UserSearchIdle() => const SizedBox.shrink(),
        UserSearchLoading() => const LinearProgressIndicator(),
        UserSearchFailed() => Text(
          l10n.userSearchFailed,
          style: theme.textTheme.bodyMedium,
        ),
        UserSearchResults(:final users) when users.isEmpty => Text(
          l10n.userSearchEmpty,
          style: theme.textTheme.bodyMedium,
        ),
        UserSearchResults(:final users) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (final user in users) _row(user)],
        ),
      },
    );
  }

  Widget _row(UserSummary user) {
    final picked = isPicked(user);
    final onPick = this.onPick;

    return ListTile(
      key: resultKey(user.id),
      title: Text(user.label),
      subtitle: user.displayName == null ? null : Text(user.username),
      selected: picked,
      trailing: picked ? const Icon(Icons.check_circle) : null,
      onTap: onPick == null ? null : () => onPick(user),
    );
  }
}
