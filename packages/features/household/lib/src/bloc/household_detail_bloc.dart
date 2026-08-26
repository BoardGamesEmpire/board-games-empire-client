import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import '../sync/household_hydration_status.dart';
import 'household_detail_event.dart';
import 'household_detail_state.dart';

/// Drives the household detail screen (#270): one household, its member
/// count, and the current user's role in it.
///
/// ## Where the household comes from (#270 D3)
///
/// `HouseholdRepository` has no `watchHousehold(id)` — only `getHousehold`
/// (a Future) and `watchHouseholds()`. This filters the list stream rather
/// than adding the method, and so inherits three behaviours that are
/// already implemented and covered rather than re-deriving them: the
/// membership gate, the tombstone exclusion, and the unauthenticated read
/// the repository routes through the stream body. Every way this household
/// can stop being readable — removed, tombstoned, signed out — arrives as
/// the id simply not being in the next emission.
///
/// The cost is a rebuild when an unrelated household upserts. Households
/// per user are single digits (#267 D13), so it is not a cost.
///
/// ## Why absence waits on the hydrate
///
/// An id that is not in the cache is not the same as an id that does not
/// exist, and on a deep link or a restored route the difference is the
/// whole answer: the drain runs unawaited from session activation (#267
/// D2), so this screen can be reached before the cache has been filled.
/// Saying "we couldn't find this household" to someone who has it is the
/// same failure #269 D1 built the list's loading state to avoid.
///
/// So an absent household is *loading* while a pass is running, and
/// not-found once one has settled — including when it settled by failing,
/// which is an answer of a kind: waiting on a pass that already gave up
/// would be a spinner nothing resolves. That case carries `refreshFailed`,
/// so the screen can say it could not check rather than presenting an
/// unverified absence as a settled one.
///
/// An **absent** hydration stream reads as settled, exactly as it does on
/// the list — a container with no household client (#137) must not hang.
///
/// ## Why the roster is a gate, not a decoration
///
/// The member count is one of the three things this screen exists to say,
/// and `Household` carries no count field — it is the roster's length. A
/// household with no member rows yet would render "No members", which is
/// false of every household (the creator's own row is synthesized at
/// create). So a household without its roster is still loading.
///
/// ## The current user's role (#270 D4)
///
/// `getCurrentUserMember` resolves *who we are* once; the role itself is
/// read off the roster on every emission. That is one query rather than
/// one per change, and it keeps the displayed role reactive — a role
/// changed on the server reaches this screen through the same rows the
/// count does, once the membership work (#122) makes that possible.
///
/// A failure to resolve identity is not a failure of the screen: the role
/// line is omitted and everything else renders. Losing the answer to "what
/// am I here" is much less than losing the household.
class HouseholdDetailBloc
    extends Bloc<HouseholdDetailEvent, HouseholdDetailState> {
  HouseholdDetailBloc({
    required String householdId,
    required HouseholdRepository repository,
    Stream<HouseholdHydrationState>? hydration,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.detail'),
       super(const HouseholdDetailLoading()) {
    on<HouseholdDetailHouseholdUpdated>(_onHouseholdUpdated);
    on<HouseholdDetailMembersUpdated>(_onMembersUpdated);
    on<HouseholdDetailIdentityResolved>(_onIdentityResolved);
    on<HouseholdDetailReadFailed>(_onReadFailed);
    on<HouseholdDetailReadEnded>(_onReadEnded);
    on<HouseholdDetailHydrationUpdated>(_onHydrationUpdated);
    on<HouseholdDetailHydrationEnded>(_onHydrationEnded);

    _households = repository.watchHouseholds().listen(
      (households) => add(
        HouseholdDetailHouseholdUpdated(
          households.where((h) => h.id == householdId).firstOrNull,
        ),
      ),
      onError: (Object error, StackTrace stackTrace) {
        _logger.warn(
          'Household read failed',
          error: error,
          stackTrace: stackTrace,
        );
        add(const HouseholdDetailReadFailed(HouseholdDetailSource.household));
      },
      onDone: () =>
          add(const HouseholdDetailReadEnded(HouseholdDetailSource.household)),
    );

    _members = repository
        .watchMembers(householdId)
        .listen(
          (members) => add(HouseholdDetailMembersUpdated(members)),
          onError: (Object error, StackTrace stackTrace) {
            _logger.warn(
              'Household member read failed',
              error: error,
              stackTrace: stackTrace,
            );
            add(const HouseholdDetailReadFailed(HouseholdDetailSource.members));
          },
          onDone: () => add(
            const HouseholdDetailReadEnded(HouseholdDetailSource.members),
          ),
        );

    _hydration = hydration?.listen(
      (state) => add(HouseholdDetailHydrationUpdated(state)),
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Household hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
      onDone: () => add(const HouseholdDetailHydrationEnded()),
    );

    unawaited(_resolveIdentity(repository, householdId));
  }

  final BgeLogger _logger;

  late final StreamSubscription<List<Household>> _households;
  late final StreamSubscription<List<HouseholdMember>> _members;
  StreamSubscription<HouseholdHydrationState>? _hydration;

  /// Null until the household stream has answered at all, which is not the
  /// same as it having answered with nothing — hence the separate flag.
  Household? _household;
  bool _householdAnswered = false;

  /// Null until the roster has answered.
  List<HouseholdMember>? _members0;

  /// Per-stream, never shared. The two streams fail and recover
  /// independently, and one flag between them would let an emission on
  /// either clear the other's failure — leaving a household with no roster
  /// on a loading state nothing resolves.
  bool _householdFailed = false;
  bool _membersFailed = false;

  /// Per-stream, for the same reason. A closed stream is the only thing
  /// that makes waiting for it pointless.
  bool _householdDone = false;
  bool _membersDone = false;
  bool _hydrationDone = false;

  /// The current user's id, once known. [_identityResolved] separates "not
  /// yet asked" from "asked, and there is no answer".
  String? _currentUserId;
  bool _identityResolved = false;

  HouseholdHydrationState _hydrationState = HouseholdHydrationState.idle;

  /// Resolves who the current user is, so their row can be found in the
  /// roster. Swallows everything: a disposed repository throws a
  /// `StateError` here during the teardown window, and the streams above
  /// are what report that the screen is over.
  Future<void> _resolveIdentity(
    HouseholdRepository repository,
    String householdId,
  ) async {
    String? userId;
    try {
      userId = (await repository.getCurrentUserMember(householdId))?.userId;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Could not resolve the current user for this household',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (isClosed) return;
    add(HouseholdDetailIdentityResolved(userId));
  }

  void _onHouseholdUpdated(
    HouseholdDetailHouseholdUpdated event,
    Emitter<HouseholdDetailState> emit,
  ) {
    // An emission is proof THIS stream recovered — the one thing that
    // clears its failure, and it says nothing about the other one.
    _householdFailed = false;
    _householdAnswered = true;
    _household = event.household;
    _emitDerived(emit);
  }

  void _onMembersUpdated(
    HouseholdDetailMembersUpdated event,
    Emitter<HouseholdDetailState> emit,
  ) {
    _membersFailed = false;
    _members0 = event.members;
    _emitDerived(emit);
  }

  void _onIdentityResolved(
    HouseholdDetailIdentityResolved event,
    Emitter<HouseholdDetailState> emit,
  ) {
    _identityResolved = true;
    _currentUserId = event.userId;
    _emitDerived(emit);
  }

  void _onReadFailed(
    HouseholdDetailReadFailed event,
    Emitter<HouseholdDetailState> emit,
  ) {
    switch (event.source) {
      case HouseholdDetailSource.household:
        _householdFailed = true;
      case HouseholdDetailSource.members:
        _membersFailed = true;
    }
    _emitDerived(emit);
  }

  void _onReadEnded(
    HouseholdDetailReadEnded event,
    Emitter<HouseholdDetailState> emit,
  ) {
    switch (event.source) {
      case HouseholdDetailSource.household:
        _householdDone = true;
      case HouseholdDetailSource.members:
        _membersDone = true;
    }
    // Whatever is already on screen stays — the route is being popped
    // around us. What must not survive is a spinner: _emitDerived turns
    // "still waiting" into an error once the stream being waited on has
    // closed.
    _emitDerived(emit);
  }

  void _onHydrationEnded(
    HouseholdDetailHydrationEnded event,
    Emitter<HouseholdDetailState> emit,
  ) {
    _hydrationDone = true;
    _emitDerived(emit);
  }

  void _onHydrationUpdated(
    HouseholdDetailHydrationUpdated event,
    Emitter<HouseholdDetailState> emit,
  ) {
    _hydrationState = event.hydration;
    _emitDerived(emit);
  }

  /// True while a first answer could still arrive from the server. A
  /// closed status stream can never leave `running`, so it does not count
  /// as still filling.
  bool get _filling =>
      _hydrationState == HouseholdHydrationState.running && !_hydrationDone;

  bool get _refreshFailed => _hydrationState == HouseholdHydrationState.failed;

  void _emitDerived(Emitter<HouseholdDetailState> emit) {
    // Holds against everything except fresh rows on the stream that
    // failed: a hydrate result is an annotation, not data, and an
    // emission on the *other* stream is not evidence about this one.
    if (_householdFailed || _membersFailed) {
      return emit(const HouseholdDetailError());
    }

    // Every wait below is "loading until the stream answers, and an error
    // once that stream has closed without answering" — a spinner nothing
    // can resolve is the one outcome worse than saying the read failed.
    if (!_householdAnswered) return emit(_waitingOn(_householdDone));

    final household = _household;
    if (household == null) {
      // Absent and still filling is unknown, not missing.
      if (_filling) return emit(const HouseholdDetailLoading());
      return emit(HouseholdDetailNotFound(refreshFailed: _refreshFailed));
    }

    // The count is load-bearing content, so it waits for a real answer
    // rather than showing zero. Identity waits with it: the role is part
    // of the same first paint, and it is one local query that always
    // reports — hence no done-flag of its own.
    final members = _members0;
    if (members == null) return emit(_waitingOn(_membersDone));
    if (!_identityResolved) return emit(const HouseholdDetailLoading());

    emit(
      HouseholdDetailReady(
        household: household,
        memberCount: members.length,
        role: _roleOf(members),
        refreshFailed: _refreshFailed,
      ),
    );
  }

  /// Loading while the answer can still arrive; an error once the stream
  /// that owed it has closed.
  HouseholdDetailState _waitingOn(bool sourceDone) => sourceDone
      ? const HouseholdDetailError()
      : const HouseholdDetailLoading();

  /// The current user's role, off the roster the screen is already showing
  /// a count of. Null when identity is unknown, or when our row carries no
  /// role binding — two different reasons the screen renders identically,
  /// because it has nothing to say in either case.
  HouseholdRole? _roleOf(List<HouseholdMember> members) {
    final userId = _currentUserId;
    if (userId == null) return null;
    return members.where((m) => m.userId == userId).firstOrNull?.role;
  }

  @override
  Future<void> close() async {
    await _households.cancel();
    await _members.cancel();
    await _hydration?.cancel();
    return super.close();
  }
}
