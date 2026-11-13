import 'package:flutter/foundation.dart';

/// Closes a screen's state holder once nothing it started is under way,
/// saying how a save that outlived the screen ended (#464).
///
/// Called from `State.dispose`, with the state holder the screen owns. When
/// [underWay] is false for [current] there is nothing to wait for or say, and
/// [close] runs at once. Otherwise this waits for the first state on [states]
/// that is not under way, passes its [outcomeOf] to [say], and closes.
/// [close] always runs, even if the wait fails.
///
/// [say] is the screen's `SessionMessenger.say`, which says nothing once the
/// session the save started in has ended or the messenger has gone: a save
/// that finished after the user signed out is no news to whoever signs in
/// next (#694). This never navigates; the screen is already gone, and the
/// bar lands on the page the user went to.
///
/// A save that settles while the screen's route is still leaving, before
/// `dispose`, is the screen's own to say, through the same messenger. By
/// `dispose` it has settled, so this closes without a word.
///
/// [states] is subscribed to before the first `await`. A bloc's stream is
/// broadcast, so a state emitted between the call and a later subscription
/// would be lost.
///
/// A stream error is not rethrown, because this runs unawaited from
/// `dispose`. It counts as no outcome and is reported through
/// [FlutterError.reportError]; `ui` cannot reach `core/di`'s
/// `debugReportSwallowed`. A [close] that throws is the returned future's
/// error, which goes unhandled when the caller doesn't await it, as a
/// `dispose` doesn't.
///
/// There is no time limit on the wait. Every request the app sends has the
/// network client's own timeouts, so a save always settles, and a limit
/// here would drop the outcome of a slow one.
///
/// The shape came from `CollectionEntryScreen`'s `dispose`
/// (`packages/features/collection/lib/src/entry/collection_entry_screen.dart`).
Future<void> closeWhenSettled<S extends Object>({
  required S current,
  required Stream<S> states,
  required bool Function(S state) underWay,
  required String? Function(S settled) outcomeOf,
  required void Function(String? message) say,
  required Future<void> Function() close,
}) async {
  try {
    if (!underWay(current)) return;

    // `firstWhere` listens now, before this function first suspends. An
    // ended stream gives null (via `orElse`) rather than a `StateError`, so
    // a stream error of that type is still reported below. A state is never
    // null (`S extends Object`), so null means only that.
    final settled = await states.cast<S?>().firstWhere(
      (state) => !underWay(state!),
      orElse: () => null,
    );
    // The stream ended while still under way: nothing to say.
    if (settled == null) return;

    say(outcomeOf(settled));
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'ui',
        context: ErrorDescription('while waiting for a save to settle (#464)'),
      ),
    );
  } finally {
    await close();
  }
}
