import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../url/server_url_input.dart';
import 'server_onboarding_event.dart';
import 'server_onboarding_state.dart';

/// Drives the first-run server-add flow (#36):
///
/// normalize/validate the URL → connectivity fast-fail (#9) →
/// `WellKnownClient.fetchIdentity` → `VersionNegotiator.negotiate` (#13)
/// → `ServerOrchestrator.addAndActivateServer`.
///
/// Invariants enforced here (and pinned by bloc tests):
/// - a version-negotiation mismatch **never** reaches the persist step;
/// - an offline device fails immediately, before any fetch (no timeout
///   wait);
/// - local URL validation failures never touch the network.
///
/// All collaborators are root-scope: server-add runs before any
/// `ServerContext` exists. The orchestrator arrives as the interface —
/// this package never sees a platform concrete.
class ServerOnboardingBloc
    extends Bloc<ServerOnboardingEvent, ServerOnboardingState> {
  ServerOnboardingBloc({
    required WellKnownClient wellKnownClient,
    required VersionNegotiator versionNegotiator,
    required ConnectivityService connectivityService,
    required BuildInfo buildInfo,
    required ServerOrchestrator orchestrator,
    BgeLogger? logger,
  }) : _wellKnownClient = wellKnownClient,
       _versionNegotiator = versionNegotiator,
       _connectivityService = connectivityService,
       _buildInfo = buildInfo,
       _orchestrator = orchestrator,
       _logger = logger ?? BgeLogger('bge.onboarding'),
       super(const ServerOnboardingIdle()) {
    on<ServerOnboardingSubmitted>(_onSubmitted);
  }

  final WellKnownClient _wellKnownClient;
  final VersionNegotiator _versionNegotiator;
  final ConnectivityService _connectivityService;
  final BuildInfo _buildInfo;
  final ServerOrchestrator _orchestrator;
  final BgeLogger _logger;

  Future<void> _onSubmitted(
    ServerOnboardingSubmitted event,
    Emitter<ServerOnboardingState> emit,
  ) async {
    // Re-entrancy: ignore submits while one is in flight (the form
    // disables its button, but a race between tap and rebuild is cheap
    // to close here too).
    if (state is ServerOnboardingInProgress) return;

    // 1. Local validation — never touches the network.
    final urlResult = normalizeServerUrl(event.url);
    if (urlResult is ServerUrlInvalid) {
      emit(ServerOnboardingInvalidUrl(urlResult.error));
      return;
    }
    final serverUrl = (urlResult as ServerUrlValid).normalized;

    emit(const ServerOnboardingInProgress());

    // 2. Offline fast-fail (#9): surface immediately instead of letting
    // the fetch run into its 10s timeout.
    if (_connectivityService.current == ConnectivityState.offline) {
      emit(const ServerOnboardingOffline());
      return;
    }

    // 3. Discovery.
    final ServerIdentity identity;
    try {
      identity = await _wellKnownClient.fetchIdentity(serverUrl);
    } on WellKnownNotFoundException {
      emit(const ServerOnboardingNotBgeServer());
      return;
    } on WellKnownUnreachableException {
      emit(const ServerOnboardingUnreachable());
      return;
    } on WellKnownInvalidResponseException {
      emit(const ServerOnboardingInvalidResponse());
      return;
    }

    // 4. Version negotiation (#13) — a mismatch never persists.
    final negotiation = _versionNegotiator.negotiate(
      buildInfo: _buildInfo,
      identity: identity,
    );
    switch (negotiation) {
      case VersionCompatible():
        break;
      case ClientTooOld(:final clientVersion, :final requiredMinimum):
        emit(
          ServerOnboardingClientTooOld(
            clientVersion: clientVersion,
            requiredMinimum: requiredMinimum,
          ),
        );
        return;
      case ClientTooNew(:final clientVersion, :final supportedMaximum):
        emit(
          ServerOnboardingClientTooNew(
            clientVersion: clientVersion,
            supportedMaximum: supportedMaximum,
          ),
        );
        return;
      case SchemaTooNew():
        emit(const ServerOnboardingSchemaTooNew());
        return;
    }

    // 5. Persist + activate. Blank alias falls back to the server's
    // advertised display name.
    final alias = event.alias?.trim();
    final displayName = (alias == null || alias.isEmpty)
        ? identity.name
        : alias;

    try {
      final serverId = await _orchestrator.addAndActivateServer(
        displayName: displayName,
        serverUrl: serverUrl,
        bgeServerId: identity.serverId,
        identity: identity,
      );
      emit(
        ServerOnboardingSucceeded(serverId: serverId, displayName: displayName),
      );
    } on DuplicateServerException {
      emit(const ServerOnboardingDuplicate());
    } on ServerCapacityExceededException {
      emit(const ServerOnboardingCapacityExceeded());
    } catch (e, st) {
      _logger.error(
        'Server onboarding failed after negotiation',
        error: e,
        stackTrace: st,
      );
      emit(ServerOnboardingUnexpectedFailure(e));
    }
  }
}
