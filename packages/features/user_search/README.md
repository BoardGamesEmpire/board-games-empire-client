# user_search

Search for people by name or username (#455, #499): the bloc that asks the
server who matches what is being typed, and the rows that show the answer.

It is shared by the two forms that pick people this way: `household`'s invite
form (#455), which picks one person to invite, and `events`' create form
(#499), which picks up to fifty invitees. This is the one feature package
another feature may depend on: features otherwise don't depend on each other,
and `app_shell` depends on features, never the reverse.

## Shape

- `UserSearchBloc` — takes `UserSearchQueryChanged` and answers
  `UserSearchIdle`, `UserSearchLoading`, `UserSearchResults` or
  `UserSearchFailed`. A query is sent to a `UserRemoteDataSource` once typing
  pauses for 300 ms, and only when it has at least
  `UserRemoteDataSource.minSearchLength` characters after trimming. Each new
  query replaces the one before it, so the results shown are for the latest.
  The loading state is emitted before the pause, so the last query's results
  can't be picked through it.
- `UserSearchResultList` — the rows for the bloc above it: nothing while
  idle, a progress bar while asking, a line when no one matched or the
  search failed, and a row for each user otherwise. It is multi-pick:
  `isPicked` marks as many rows as it likes, `onPick` takes a tap (null while
  the caller can take none, which leaves the rows drawn but untappable), and
  `resultKey` is the caller's key for each row.

## Boundaries

This package runs the search and draws its answer. The field and the pick stay
with the form.

- The **search field** is each form's own. It dispatches
  `UserSearchQueryChanged` as the text changes, and takes its label and hint
  from `UserSearchLocalizations` (`userSearchLabel`, `userSearchHint`).
- The **pick** is each form's own. The household form keeps one person and the
  events form a list of up to fifty; the rows only draw what `isPicked` says
  and report taps.
- The form creates the bloc over the per-server `UserRemoteDataSource`, which
  `registerServerNetwork` and `registerServerNetworkWeb` register. This
  package never resolves one itself and touches neither routing nor DI.

## i18n

All copy comes from `UserSearchLocalizations` (gitignored, regenerated —
`melos run generate`). `app_shell` registers its delegate, and a widget test
of a screen that draws the list adds it to its own delegates.
