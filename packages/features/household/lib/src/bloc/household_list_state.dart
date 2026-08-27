import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the household list screen is showing (#269 D6).
///
/// Three states, not four: *empty* is [HouseholdListReady] with no rows.
/// Splitting it out would have made the screen ask which of two states to
/// render from the same data, and made "empty, and also possibly stale" —
/// a real combination — an awkward pair rather than one value.
sealed class HouseholdListState extends Equatable {
  const HouseholdListState();

  @override
  List<Object?> get props => [];
}

/// Nothing to show yet: either the cache has not emitted, or it emitted
/// nothing while a hydrate is still filling it (#269 D1).
final class HouseholdListLoading extends HouseholdListState {
  const HouseholdListLoading();
}

/// The cache's current answer. [households] may be empty, which means
/// there genuinely are none — the hydrate has settled, or there is no
/// hydrate to wait for.
///
/// [refreshFailed] says the last hydrate pass ended early, so these rows
/// may be stale. It is orthogonal to the row count: an empty list whose
/// refresh failed is both empty *and* unverified, and the screen says
/// both.
///
/// [refreshing] says a pass **the user asked for** is running (#300 D6).
/// It is not "a pass is running": the #302 triggers re-hydrate on a
/// connectivity edge and on app resume, and a screen that announces work
/// nobody asked for is noise. The two flags are mutually exclusive in
/// practice — a running pass has not failed yet — but nothing here
/// enforces that, because the state's job is to report what is true rather
/// than to police it.
final class HouseholdListReady extends HouseholdListState {
  const HouseholdListReady({
    required this.households,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  final List<Household> households;
  final bool refreshFailed;
  final bool refreshing;

  @override
  List<Object?> get props => [households, refreshFailed, refreshing];
}

/// The cache read itself failed.
///
/// Distinct from [HouseholdListReady] with `refreshFailed`: that one has
/// rows to show and a caveat about them; this one has nothing.
///
/// Two ways in, both while a session is ending and the auth redirect is a
/// step behind: the unauthenticated read `watchHouseholds()` delivers as a
/// stream **error**, and a stream that **closes** on scope teardown before
/// it ever emitted. The second is the ordinary one — `WatchDisposal`
/// closes vended streams rather than erroring them.
final class HouseholdListError extends HouseholdListState {
  const HouseholdListError();
}
