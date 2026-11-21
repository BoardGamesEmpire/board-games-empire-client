import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:server_onboarding/src/bloc/expected_server.dart';
import 'package:server_onboarding/src/bloc/server_onboarding_event.dart';
import 'package:server_onboarding/src/bloc/server_onboarding_state.dart';
import 'package:server_onboarding/src/url/server_url_input.dart';

/// Drives the first-run server-add flow (#36):
///
/// normalize/validate the URL → connectivity fast-fail (#9) →
/// `WellKnownClient.fetchIdentity` → expected-server check, only while the
/// submitted address is the link's (#971) → `VersionNegotiator.negotiate`
/// (#13) → `ServerOrchestrator.addAndActivateServer`.
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
    required this._wellKnownClient,
    required this._versionNegotiator,
    required this._connectivityService,
    required this._buildInfo,
    required this._orchestrator,
    this._expectedServer,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.onboarding'),
       super(const ServerOnboardingIdle()) {
    on<ServerOnboardingSubmitted>(_onSubmitted, transformer: droppable());
    on<ServerOnboardingFailureCleared>(_onFailureCleared);
  }

  final WellKnownClient _wellKnownClient;
  final VersionNegotiator _versionNegotiator;
  final ConnectivityService _connectivityService;
  final BuildInfo _buildInfo;
  final ServerOrchestrator _orchestrator;

  /// The server a link names, when the form was opened from one (#971).
  ///
  /// The check applies only while the submitted address normalizes to what
  /// [ExpectedServer.address] does: a server whose identity has another id is
  /// refused with [ServerOnboardingWrongServer], so a link can't get a
  /// different server added by naming the wrong address. An address the user
  /// typed instead is an ordinary add, with nothing compared.
  final ExpectedServer? _expectedServer;
  final BgeLogger _logger;

  /// Retires a failure the user has already been told about by other means.
  ///
  /// Deliberately narrow: it clears a [ServerOnboardingFailure] and nothing
  /// else. In particular it cannot interrupt an in-flight request or undo a
  /// success, both of which would be a form widget reaching past its remit.
  void _onFailureCleared(
    ServerOnboardingFailureCleared event,
    Emitter<ServerOnboardingState> emit,
  ) {
    if (state is ServerOnboardingFailure) emit(const ServerOnboardingIdle());
  }

  Future<void> _onSubmitted(
    ServerOnboardingSubmitted event,
    Emitter<ServerOnboardingState> emit,
  ) async {
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
    } on WellKnownServerErrorException {
      emit(const ServerOnboardingServerError());
      return;
    } on WellKnownInvalidResponseException {
      emit(const ServerOnboardingInvalidResponse());
      return;
    }

    // 3b. A link's address must answer as the server the link names (#971).
    // After discovery, since the id is only known from the identity, and
    // before negotiation, so a different server is never reported as a
    // version problem or saved.
    //
    // The link's address is normalized again, as the submitted one was:
    // normalizing drops one trailing slash a pass, so an address the form
    // was prefilled with and submitted unchanged can come out one slash
    // shorter than the link's.
    final expected = _expectedServer;
    if (expected != null &&
        normalizeServerUrl(expected.address) == urlResult &&
        identity.serverId != expected.bgeServerId) {
      emit(const ServerOnboardingWrongServer());
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
    } on Object catch (e, st) {
      _logger.error(
        'Server onboarding failed after negotiation',
        error: e,
        stackTrace: st,
      );
      emit(ServerOnboardingUnexpectedFailure(e));
    }
  }
}
