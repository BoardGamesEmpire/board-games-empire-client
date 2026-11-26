import 'dart:async';

import 'package:di/di.dart' show ServerSkewClockService;
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart'
    show
        ClockService,
        ProviderSignInBrowser,
        SessionRejectionSignal,
        UnsupportedProviderSignInBrowser;
import 'package:models/domain.dart';
import 'package:native_network/src/auth/auth_repository_impl.dart';
import 'package:native_network/src/auth/token_storage_service.dart';
import 'package:native_network/src/network/token_interceptor.dart';
import 'package:network_interface/network_interface.dart'
    show
        AdminHouseholdRemoteDataSource,
        ApiKeyRemoteDataSource,
        DataGatewayRemoteDataSource,
        EventRemoteDataSource,
        GameCollectionRemoteDataSource,
        GamesRemoteDataSource,
        HouseholdInviteRemoteDataSource,
        HouseholdMemberRemoteDataSource,
        HouseholdRemoteDataSource,
        NotificationRemoteDataSource,
        SystemSettingsRemoteDataSource,
        UserProfileRemoteDataSource,
        UserRemoteDataSource;
import 'package:observability/observability.dart' show FeedbackTransport;

/// Registers the mobile/desktop network stack for [config] into the per-server
/// [container].
///
/// This is the composition root for the Dio-based stack — the one place that
/// knows how the pieces fit together. It wires:
///
///   ClockService -> TokenStorageService -> TokenInterceptor -> DioFactory
///                                      -> shared Dio -> AuthRepository
///
/// The factory's [Dio] is registered as a shared per-server singleton so future
/// repositories (game search, collection sync, …) resolve the same instance and
/// inherit the interceptor stack — including token attachment — without any
/// construction-order dependency.
///
/// Beside the Dio, it registers the [RealtimeEndpoint] the session's socket
/// connects with, whose token comes from the same [TokenStorageService]
/// (#473).
///
/// Beside the repository, it registers the [SessionRejectionSignal] a 401
/// from any of this server's data endpoints is reported to, and that the
/// sync drain and the search socket report to as well (#484).
///
/// Lifecycle: the container owns the shared [Dio] and closes it on dispose; the
/// repository only closes its own resources (it must not close a [Dio] that
/// other repositories share).
///
/// [sessionTombstones] is passed in rather than built here because it reads the
/// meta database, which outlives every per-server scope (#356).
void registerServerNetwork({
  required DependencyContainer container,
  required ServerConfig config,
  required SessionTombstoneStore sessionTombstones,
  ProviderSignInBrowser providerBrowser =
      const UnsupportedProviderSignInBrowser(),
}) {
  // #12: per-server skew-corrected clock. Registered here — not in its
  // own installer — per the registration convention: it is fed by this
  // stack's Dio responses (via ClockSkewInterceptor below). Registered
  // under the read interface only; the feed surface (ClockSkewRecorder)
  // is a private wiring detail between this composition root and the
  // interceptor. Each server has its own clock, so estimates never leak
  // across scopes.
  //
  // Constructed FIRST because both the token interceptor and the auth
  // repository now read it for session-expiry arithmetic (#98) — every
  // timestamp on the auth path goes through the corrected clock rather
  // than the raw device wall clock.
  final clock = ServerSkewClockService();
  container.registerSingleton<ClockService>(
    clock,
    dispose: (_) => clock.dispose(),
  );

  // Session material is keyed by the stable server-vended UUID so it
  // survives user-facing URL changes for the same server instance.
  final tokenStorage = TokenStorageService(
    serverId: config.bgeServerId,
    tombstones: sessionTombstones,
  );
  container
    ..registerSingleton<TokenStorageService>(tokenStorage)
    // #473: where the session's socket connects, and the token its handshake
    // sends. The server scope holds it, and the user scope's RealtimeInstaller
    // builds the session's connection from it. The token is read on every
    // connect and reconnect, never once here, as the stored session can change
    // or expire between connects. The expiry rule is the one TokenInterceptor
    // reads, StoredSession.tokenToSendAt: a session known to be dead sends no
    // token, and the server refuses the handshake, which leaves search on
    // REST.
    ..registerSingleton<RealtimeEndpoint>(
      RealtimeEndpoint(
        server: Uri.parse(config.serverUrl),
        token: () async =>
            (await tokenStorage.retrieve())?.tokenToSendAt(clock.nowUtc()),
      ),
    );

  const factory = DefaultDioFactory();
  container.registerSingleton<DioFactory>(factory);

  // #484: assigned once the repository it re-reads the session through
  // exists, below, before this function returns. Nothing can read it sooner:
  // this function is synchronous, and Dio runs every interceptor in a later
  // event, never inside the call that starts a request.
  late final SessionRejectionSignal sessionRejection;

  final dio = factory.buildForServer(
    baseUrl: config.serverUrl,
    interceptors: [
      // #100: permanent network observability, first in the stack so it
      // observes every outgoing request and its resolution. Redaction-safe
      // — logs method + resolved URI + status/error type only, never
      // bodies, headers, query parameters, or tokens. Request/response
      // tracing is at debug and self-gates to non-release builds; a
      // transport failure logs at error always.
      NetworkLogInterceptor(),
      // #484: reports a 401 from any endpoint outside the auth API, so the
      // session is re-read. After the log, which stays first, and ahead of
      // the token and clock interceptors, so the clock's send stamp stays
      // last. Dio runs response interceptors in the same order, not
      // reversed, and none of these changes a response, so it sees the
      // status the server sent. `sessionAuthBase` builds the auth base the
      // way this Dio builds the repository's requests.
      SessionRejectionInterceptor(
        authBase: sessionAuthBase(
          config.serverUrl,
          config.cachedIdentity.authBasePath,
        ),
        onRejected: () => unawaited(sessionRejection.report()),
      ),
      TokenInterceptor(tokenStorage: tokenStorage, clock: clock),
      // #12: feeds server Date headers to the skew estimator. Every
      // response through this Dio is a free calibration sample. LAST in
      // the stack, after TokenInterceptor: its send stamp is taken after
      // the async token-storage read — the only non-trivial latency in
      // the chain — so the measured round trip excludes it.
      ClockSkewInterceptor(recorder: clock),
    ],
  );
  container.registerSingleton<Dio>(dio, dispose: (_) => dio.close());

  final authRepository = AuthRepositoryImpl(
    identity: config.cachedIdentity,
    serverUrl: config.serverUrl,
    tokenStorage: tokenStorage,
    dio: dio,
    clock: clock,
    providerBrowser: providerBrowser,
  );
  // #484: what the interceptor above reports to. Concurrent reports of a
  // session that is gone share one `getSession()`, whose definitive "no
  // session" ends the session through the repository's own path.
  sessionRejection = MergedSessionRevalidation(authRepository.getSession);
  // Disposable, so the container closes it with the scope.
  container
    ..registerSingleton<AuthRepository>(authRepository)
    // #484: the same signal for the user scope's sync drain and search
    // socket, so one refused session costs one session read however many
    // places saw it. Holds nothing to dispose.
    ..registerSingleton<SessionRejectionSignal>(sessionRejection)
    // #97: the per-server feedback transport. Registered here — not in its
    // own installer — per the registration convention: services sharing a
    // per-server resource register in that resource's installer, and this
    // shares the per-server Dio (which carries the base URL and the
    // BetterAuth session the feedback endpoint requires). Const and
    // stateless; nothing to dispose (the container owns the Dio).
    ..registerSingleton<FeedbackTransport>(FeedbackDioTransport(dio))
    // #39: the per-server household remote. Same convention as the feedback
    // transport above — it shares the per-server Dio (base URL + BetterAuth
    // session the `/api/households` endpoints require) and adds no auth of its
    // own. Const and stateless; the container owns the Dio.
    ..registerSingleton<HouseholdRemoteDataSource>(
      HouseholdRemoteDataSourceImpl(dio),
    )
    // #455: the per-server household invite remote, for the invite screens.
    // Same convention and placement as the household remote above: it shares
    // the per-server Dio and adds no auth of its own. Const and stateless; the
    // container owns the Dio.
    ..registerSingleton<HouseholdInviteRemoteDataSource>(
      HouseholdInviteRemoteDataSourceImpl(dio),
    )
    // #1028: the per-server API key remote, for the API keys screens. Same
    // convention and placement as the remotes above: it shares the per-server
    // Dio (base URL + BetterAuth session the `/api/api-keys` routes require)
    // and adds no auth of its own. Const and stateless; the container owns the
    // Dio.
    ..registerSingleton<ApiKeyRemoteDataSource>(ApiKeyRemoteDataSourceImpl(dio))
    // #480: the per-server household member remote, for changing a member's
    // role and removing a member. Same convention and placement as the
    // remotes above: it shares the per-server Dio and adds no auth of its own.
    // Const and stateless; the container owns the Dio.
    ..registerSingleton<HouseholdMemberRemoteDataSource>(
      HouseholdMemberRemoteDataSourceImpl(dio),
    )
    // #499: the per-server user remote, for the screens that pick people by
    // searching. Same convention and placement as the invite remote above: it
    // shares the per-server Dio (base URL + the BetterAuth session
    // `/api/users/search` requires) and adds no auth of its own. Const and
    // stateless; the container owns the Dio.
    ..registerSingleton<UserRemoteDataSource>(
      UserRemoteDataSourceImpl(dio),
    )
    // #547: the caller's own profile remote, beside the user remote and for
    // the same reason: it shares the per-server Dio (base URL + the session
    // `/api/users/me/profile` requires) and adds no auth of its own. Const and
    // stateless; the container owns the Dio.
    ..registerSingleton<UserProfileRemoteDataSource>(
      UserProfileRemoteDataSourceImpl(dio),
    )
    // #253: the per-server collection remote — the network seam the collection
    // slice had none of. Same convention and the same placement as the
    // household remote above: it shares the per-server Dio (base URL + the
    // BetterAuth session `/api/game-collections` requires) and adds no auth of
    // its own. Const and stateless; the container owns the Dio.
    //
    // The read side feeds the collection hydrate (#259), and the write side is
    // what the sync queue's sender pushes queued collection operations through
    // (#121).
    ..registerSingleton<GameCollectionRemoteDataSource>(
      GameCollectionRemoteDataSourceImpl(dio),
    )
    // #41: the per-server DataGateway remote, for the admin screen and the read
    // that decides whether the drawer offers it. Same convention and placement
    // as the two remotes above: the per-server Dio carries the base URL and the
    // session `/api/data-gateways` requires. Const and stateless; the container
    // owns the Dio.
    ..registerSingleton<DataGatewayRemoteDataSource>(
      DataGatewayRemoteDataSourceImpl(dio),
    )
    // #684: the per-server staff households remote, for the admin households
    // section. Same convention and placement as the DataGateway remote: the
    // per-server Dio carries the base URL and the session
    // `/api/admin/households` requires. Const and stateless; the container
    // owns the Dio.
    ..registerSingleton<AdminHouseholdRemoteDataSource>(
      AdminHouseholdRemoteDataSourceImpl(dio),
    )
    // #807: the per-server system settings and notification remotes, for the
    // admin server settings section. Same convention and placement as the
    // staff households remote: the per-server Dio carries the base URL and the
    // session `/api/system-settings` and `/api/notifications` require. Const
    // and stateless; the container owns the Dio.
    ..registerSingleton<SystemSettingsRemoteDataSource>(
      SystemSettingsRemoteDataSourceImpl(dio),
    )
    ..registerSingleton<NotificationRemoteDataSource>(
      NotificationRemoteDataSourceImpl(dio),
    )
    // #42: the per-server games remote, for browse, search and the game
    // detail. Same convention and placement as the remotes above: the
    // per-server Dio carries the base URL and the session `/api/games`
    // requires. Const and stateless; the container owns the Dio. Its search
    // asks for a longer receive timeout per request than this Dio's default.
    ..registerSingleton<GamesRemoteDataSource>(
      GamesRemoteDataSourceImpl(dio),
    )
    // #496: the per-server event remote, for the event hydrate. Same convention
    // and placement as the remotes above: the per-server Dio carries the base
    // URL and the session `/api/events` requires. Const and stateless; the
    // container owns the Dio.
    ..registerSingleton<EventRemoteDataSource>(
      EventRemoteDataSourceImpl(dio),
    );
}
