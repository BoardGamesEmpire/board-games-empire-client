import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

/// Makes [serverId] the active server: switches to it when it is already
/// connected, otherwise connects it and makes it active. Whatever the
/// orchestrator throws propagates, except one overlap: see below.
///
/// When another caller connects the same server while this call waits its
/// turn, the connect fails as "already connected" although the server is
/// now there to switch to; that case switches instead of failing.
Future<void> activateServer(
  ServerOrchestrator orchestrator,
  String serverId,
) async {
  if (orchestrator.getContext(serverId) != null) {
    await orchestrator.switchActiveServer(serverId);
    return;
  }

  try {
    await orchestrator.connectServer(serverId, makeActive: true);
    // Lifecycle calls queue behind one another (#174), so a second caller
    // reads "not connected" before the first finishes connecting, then fails
    // here with "already connected". A context now means the first caller
    // won; a StateError with none is a real failure.
    //
    // The orchestrator throws StateError for other faults too, and which
    // one this is doesn't matter. A connect registers a context only once
    // it has succeeded, so one that is there now was put there by another
    // caller: the server is connected, and switching to it is what was
    // asked for. A fault that stops every command, such as a disposed
    // orchestrator, fails the switch as it failed the connect.
    // ignore: avoid_catching_errors
  } on StateError {
    if (orchestrator.getContext(serverId) == null) rethrow;
    await orchestrator.switchActiveServer(serverId);
  }
}

/// The text for a failed [activateServer]: the capacity limit when the
/// device is full, otherwise [fallback].
String serverActivationFailureText(
  ShellLocalizations l10n,
  Object error, {
  required String fallback,
}) {
  if (error is ServerCapacityExceededException) {
    return l10n.shellServerCapacityReached(error.maxCapacity);
  }
  return fallback;
}
