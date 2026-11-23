import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the household list screen is showing (#269).
///
/// Three states, not four: *empty* is [HouseholdListReady] with no rows.
/// Splitting it out would have made the screen ask which of two states to
/// render from the same data, and made "empty, and also possibly stale" —
/// a real combination — an awkward pair rather than one value.
///
/// Every state carries [refreshing], because a pass the user asked for can
/// run whatever the list shows (#314).
sealed class HouseholdListState extends Equatable {
  const HouseholdListState({this.refreshing = false});

  /// A pass **the user asked for** is running (#300), by the banner's retry,
  /// the app bar's refresh button or a pull (#314). It is not "a pass is
  /// running": the #302 triggers re-hydrate on a connectivity edge and on
  /// app resume, and a screen that announces work nobody asked for is
  /// noise.
  ///
  /// The banner, shown only over [HouseholdListReady], is the one narrator.
  /// On [HouseholdListLoading] and [HouseholdListError] there is no banner,
  /// and the flag is there for the refresh button's label alone: it is
  /// what says the press was taken.
  final bool refreshing;

  @override
  List<Object?> get props => [refreshing];
}

/// Nothing to show yet: either the cache has not emitted, or it emitted
/// nothing while a hydrate is still filling it (#269).
///
/// A pass the user asked for over an emptiness no pass has confirmed lands
/// here too, with [refreshing] set: the spinner is the feedback, not a
/// banner (#269, #300).
final class HouseholdListLoading extends HouseholdListState {
  const HouseholdListLoading({super.refreshing});
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
/// [refreshing], here, is what the banner narrates (#300). The two flags can
/// both be true: a retry over a failure is `refreshFailed &&
/// refreshing` by design, and the banner shows its refreshing copy over the
/// failure it is trying to clear (#453). Nothing here ties either flag to the
/// other, because the state's job is to report what is true rather than to
/// police it.
final class HouseholdListReady extends HouseholdListState {
  const HouseholdListReady({
    required this.households,
    this.refreshFailed = false,
    super.refreshing,
  });

  final List<Household> households;
  final bool refreshFailed;

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
///
/// A pass the user asked for can still run from here, and fresh rows from
/// it clear the error (#314); [refreshing] says one is running.
final class HouseholdListError extends HouseholdListState {
  const HouseholdListError({super.refreshing});
}
