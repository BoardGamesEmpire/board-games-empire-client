import 'package:equatable/equatable.dart';

import '../url/server_url_input.dart';

/// States for `ServerOnboardingBloc` (#36).
///
/// Failures carry *kinds* (and payloads where messages need
/// interpolation), never display strings — localization is the widget
/// layer's job, keeping the bloc free of any locale concern (#33).
sealed class ServerOnboardingState extends Equatable {
  const ServerOnboardingState();

  @override
  List<Object?> get props => const [];
}

/// Form idle, awaiting input.
final class ServerOnboardingIdle extends ServerOnboardingState {
  const ServerOnboardingIdle();
}

/// Discovery/persist in flight; the form disables its submit control.
final class ServerOnboardingInProgress extends ServerOnboardingState {
  const ServerOnboardingInProgress();
}

/// The server was persisted and activated. The shell reacts by advancing
/// bootstrap past the server-add leg.
final class ServerOnboardingSucceeded extends ServerOnboardingState {
  const ServerOnboardingSucceeded({
    required this.serverId,
    required this.displayName,
  });

  /// Local (MetaDB) id of the persisted server.
  final String serverId;

  /// The resolved display name (user alias or the server's advertised
  /// name) — available for a success announcement.
  final String displayName;

  @override
  List<Object?> get props => [serverId, displayName];
}

/// Why onboarding failed. Each kind maps to one localized message in the
/// widget layer; kinds that need interpolation carry their payloads.
sealed class ServerOnboardingFailure extends ServerOnboardingState {
  const ServerOnboardingFailure();
}

/// The entered URL failed local validation — no network was touched.
final class ServerOnboardingInvalidUrl extends ServerOnboardingFailure {
  const ServerOnboardingInvalidUrl(this.error);

  final ServerUrlError error;

  @override
  List<Object?> get props => [error];
}

/// The device is offline (#9 fast-fail — surfaced before any fetch, no
/// timeout wait).
final class ServerOnboardingOffline extends ServerOnboardingFailure {
  const ServerOnboardingOffline();
}

/// Network failure or timeout reaching the server.
final class ServerOnboardingUnreachable extends ServerOnboardingFailure {
  const ServerOnboardingUnreachable();
}

/// 404 on the well-known document — wrong URL or not a BGE server.
final class ServerOnboardingNotBgeServer extends ServerOnboardingFailure {
  const ServerOnboardingNotBgeServer();
}

/// Non-200 or unparseable identity document.
final class ServerOnboardingInvalidResponse extends ServerOnboardingFailure {
  const ServerOnboardingInvalidResponse();
}

/// Version negotiation (#13): this client is older than the server's
/// minimum.
final class ServerOnboardingClientTooOld extends ServerOnboardingFailure {
  const ServerOnboardingClientTooOld({
    required this.clientVersion,
    required this.requiredMinimum,
  });

  final String clientVersion;
  final String requiredMinimum;

  @override
  List<Object?> get props => [clientVersion, requiredMinimum];
}

/// Version negotiation (#13): this client is newer than the server's
/// maximum.
final class ServerOnboardingClientTooNew extends ServerOnboardingFailure {
  const ServerOnboardingClientTooNew({
    required this.clientVersion,
    required this.supportedMaximum,
  });

  final String clientVersion;
  final String supportedMaximum;

  @override
  List<Object?> get props => [clientVersion, supportedMaximum];
}

/// Version negotiation (#13): the discovery document's schema is newer
/// than this client understands.
final class ServerOnboardingSchemaTooNew extends ServerOnboardingFailure {
  const ServerOnboardingSchemaTooNew();
}

/// This server (by URL or BGE id) is already registered. Richer
/// known-server UX is #82's scope.
final class ServerOnboardingDuplicate extends ServerOnboardingFailure {
  const ServerOnboardingDuplicate();
}

/// The device is at its configured connected-server capacity.
final class ServerOnboardingCapacityExceeded extends ServerOnboardingFailure {
  const ServerOnboardingCapacityExceeded();
}

/// Anything unanticipated (activation failure, storage error, …). The
/// original error is retained for the feedback pipeline, but excluded
/// from equality so bloc tests can match on the state alone.
final class ServerOnboardingUnexpectedFailure extends ServerOnboardingFailure {
  const ServerOnboardingUnexpectedFailure(this.cause);

  final Object cause;
}
