import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the household detail screen is showing (#270 D3).
///
/// Four states, where the list has three. The extra one is
/// [HouseholdDetailNotFound], and it is not an error: the repository
/// answering "no" is the documented contract of an id-addressed read, not
/// a fault. [HouseholdDetailError] is the read itself failing.
sealed class HouseholdDetailState extends Equatable {
  const HouseholdDetailState();

  @override
  List<Object?> get props => [];
}

/// Nothing to show yet. Either the cache has not answered, or it answered
/// without this household while a hydrate is still filling it (#270 D3,
/// the same distinction #269 D1 draws for the list).
final class HouseholdDetailLoading extends HouseholdDetailState {
  const HouseholdDetailLoading();
}

/// The household, as the cache currently holds it.
///
/// [memberCount] comes from the roster rather than a field: `Household`
/// carries no count, and the server's is not cached. [role] is the current
/// user's own, read off the same roster (#270 D4) — null when their member
/// row carries no role binding, or when the row could not be identified at
/// all.
///
/// [refreshFailed] says the last hydrate pass ended early, so this copy may
/// be stale. Orthogonal to everything else here: a household can be shown
/// and unverified at once, and the screen says both (#269 D2's reasoning,
/// applied to one household).
final class HouseholdDetailReady extends HouseholdDetailState {
  const HouseholdDetailReady({
    required this.household,
    required this.memberCount,
    this.role,
    this.refreshFailed = false,
  });

  final Household household;
  final int memberCount;
  final HouseholdRole? role;
  final bool refreshFailed;

  @override
  List<Object?> get props => [household, memberCount, role, refreshFailed];
}

/// No readable household at this id.
///
/// Deliberately one state for three causes — not cached, not a member,
/// tombstoned — because the repository deliberately makes them
/// indistinguishable, and a screen cannot un-merge what the gate merged.
/// Reached only once the hydrate has settled, so it is an answer rather
/// than an early guess.
///
/// [refreshFailed] qualifies it: the pass that would have confirmed the
/// absence did not finish, so the screen says "we couldn't find it" and
/// "we couldn't check" together rather than presenting an unverified
/// absence as a settled one.
final class HouseholdDetailNotFound extends HouseholdDetailState {
  const HouseholdDetailNotFound({this.refreshFailed = false});

  final bool refreshFailed;

  @override
  List<Object?> get props => [refreshFailed];
}

/// The local read failed outright.
///
/// Same two ways in as the list's error state, for the same reasons: the
/// unauthenticated read the repository delivers as a stream **error**, and
/// a stream that **closes** on scope teardown before it ever emitted.
final class HouseholdDetailError extends HouseholdDetailState {
  const HouseholdDetailError();
}
