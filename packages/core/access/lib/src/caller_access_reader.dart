import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// The one place a session asks the server what the signed-in user may do
/// (#456).
///
/// Every screen that shows or hides a control by the caller's access reads
/// [current] and [changes] here, so one answer drives them all. A screen with
/// reason to doubt it, such as a change the server refused, calls [refresh]
/// rather than asking the server itself. Registered per user session by
/// `CallerAccessInstaller`, so a sign-out discards the answer and the next
/// user starts from unknown.
///
/// ## Asking
///
/// [refresh] asks for every type in the set it was built with, in one
/// request. One ask runs at a time. A call made while one is in flight is
/// answered by one more ask after it, shared by every call made meanwhile:
/// the ask in flight may have gone out before whatever gave the caller
/// reason to doubt the answer, such as a refusal from a role lowered since.
/// A failed ask keeps the last answer: an unreachable server says nothing
/// about the user's role, and a control already shown should not vanish
/// over a dropped connection.
///
/// ## An all-none first answer is asked once more
///
/// The server writes a new user's roles after sign-up has answered, so an ask
/// sent straight after it finds none of them, even for the server's first
/// owner (backend#490), the one user who has to add the first DataGateway.
/// So while the answer is still unknown, an answer that is none for every
/// action on every type is asked again after [noneRecheckDelay], and the
/// second answer is kept whatever it says. Once an answer is known, an
/// all-none answer is kept as it comes: by then it is a role that changed.
///
/// ## Whose session answered (#432)
///
/// On web another tab can move the shared session cookie to another user
/// under a tab still presenting this one, and an answer read then is that
/// user's access. So before keeping an answer this asks the
/// [SessionIdentityGuard] whether the session is still this user's, and drops
/// the answer on anything but [SessionConfirmation.confirmed]. Only the answer
/// about to be kept is checked, not a first all-none answer about to be asked
/// again. No guard, as on native, is a confirmed session.
class CallerAccessReader implements CallerAccessRepository {
  CallerAccessReader({
    required this._remote,
    required Set<ResourceType> resourceTypes,
    required this._userId,
    this._guard,
    this.noneRecheckDelay = defaultNoneRecheckDelay,
    BgeLogger? logger,
  }) : _resourceTypes = Set.unmodifiable(resourceTypes),
       _logger = logger ?? BgeLogger('bge.access');

  static const Duration defaultNoneRecheckDelay = Duration(seconds: 2);

  /// How long an all-none first answer waits before it is asked again. On a
  /// fresh server the owner's roles commit about 60ms after sign-up answers.
  final Duration noneRecheckDelay;

  final UserRemoteDataSource _remote;
  final Set<ResourceType> _resourceTypes;
  final String _userId;
  final SessionIdentityGuard? _guard;
  final BgeLogger _logger;
  final StreamController<CallerAccess> _changes =
      StreamController<CallerAccess>.broadcast();

  CallerAccess _current = const CallerAccess.unknown();
  Future<void>? _asking;

  /// The ask queued behind [_asking], for calls made while it is out.
  Future<void>? _askingNext;
  bool _disposed = false;

  @override
  CallerAccess get current => _current;

  // Held rather than read off the controller on each call, so every call
  // returns the same instance, as the contract promises.
  @override
  late final Stream<CallerAccess> changes = _changes.stream;

  /// Whether an ask is in flight, the wait before an all-none answer is asked
  /// again included.
  bool get isAsking => _asking != null;

  @override
  Future<void> refresh() {
    // An ask sent after the session ended could be sent as the next user.
    if (_disposed) return Future.value();
    final asking = _asking;
    if (asking == null) {
      return _asking = _ask().whenComplete(() => _asking = null);
    }
    // [asking] completes after it has cleared [_asking], so this starts the
    // next ask, or joins one a call made in between has started.
    return _askingNext ??= asking.then((_) {
      _askingNext = null;
      return refresh();
    });
  }

  Future<void> _ask() async {
    try {
      var answer = CallerAccess.known(
        await _remote.fetchAccess(_resourceTypes),
      );
      if (!_current.isKnown && answer.deniesEverything) {
        await Future<void>.delayed(noneRecheckDelay);
        if (_disposed) return;
        answer = CallerAccess.known(await _remote.fetchAccess(_resourceTypes));
      }
      if (_disposed) return;

      final confirmation = await _guard?.confirm(_userId);
      if (confirmation != null &&
          confirmation != SessionConfirmation.confirmed) {
        _logger.info(
          'Dropped the caller access answer: the session could not be '
          'confirmed as this user',
          context: {'answer': confirmation.name},
        );
        return;
      }
      _keep(answer);
    } on UserRemoteException catch (error, stackTrace) {
      _logger.info(
        'Could not ask what this user may do; keeping the last answer',
        error: error,
        stackTrace: stackTrace,
      );
    } on Object catch (error, stackTrace) {
      // Unreachable by contract: the remote wraps every failure, and a guard
      // answers rather than throwing. Caught all the same, because the first
      // ask runs unawaited on the sign-in path.
      _logger.warn(
        'Asking what this user may do failed unexpectedly; keeping the last '
        'answer',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _keep(CallerAccess answer) {
    // An ask can land after the session that owns this has ended.
    if (_disposed || answer == _current) return;
    _current = answer;
    _changes.add(answer);
  }

  /// Closes [changes]. An ask still in flight is dropped when it lands, and
  /// [refresh] asks nothing from here on.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.close());
  }
}
