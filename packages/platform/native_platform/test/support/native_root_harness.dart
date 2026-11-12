import 'dart:async';
import 'dart:io';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:bge_test_support/waits.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_storage/drift_storage_native.dart';
import 'package:events/events.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';
import 'package:sync_queue/sync_queue.dart';

/// Boots the real native composition root, [NativePlatformBootstrap], with
/// only its external boundaries faked (#435), so a test can assert what the
/// shipped installers actually do.
///
/// Faked:
///
/// - **The database executor.** Unencrypted drift databases in a temp
///   directory, one file for the meta database and one per server. They are
///   files, not in-memory databases, so that [shutdown] then [boot] is a
///   restart: the second boot reads what the first one wrote.
/// - **The encryption key service.** Fixed keys; nothing asks for one while
///   encryption is off.
/// - **The keychain.** `FlutterSecureStorage.setMockInitialValues`, which
///   swaps the plugin for an in-memory store that outlives each bootstrap,
///   as the real keychain outlives the process.
/// - **The HTTP transport.** [server], swapped under each active server
///   scope's real `Dio` by [swapTransport]. A request that reaches the
///   default adapter instead is refused and recorded on [escapedRequests],
///   and a request no route answers is recorded on `server.unrouted`;
///   [dispose] throws for either.
/// - **The stored-session delete** a reset runs, as a no-op.
///
/// Real: the bootstrap, the meta repositories, [ServerOrchestratorImpl] (built
/// by the injected factory, as the bootstrap's own default builds it), the
/// context factory the bootstrap composes and every server and user installer
/// in it, the remotes, the interceptors, the token storage and its session
/// tombstones, and `AuthRepositoryImpl`.
///
/// No other platform channel needed faking. `initialize()` never builds the
/// root container, the deep-link source or the hydrated-storage directory,
/// which are what reach `package_info_plus`, `app_links` and `path_provider`.
/// The provider sign-in browser is built, but opens only on a provider sign-in.
class NativeRootHarness {
  NativeRootHarness._({
    required Directory directory,
    required this._previousOverrides,
    required this._escapes,
  }) : _directory = directory,
       _executorFactory = _FileExecutorFactory(
         keyService: _keyService,
         directory: directory,
       );

  /// Makes a harness over a fresh temp directory and an empty keychain, with
  /// [server] answering the default routes. Boots nothing: call [boot].
  ///
  /// Installs an `HttpOverrides.global` whose `HttpClient`s connect to
  /// nothing, so a request sent on a `Dio` whose adapter was never swapped
  /// fails and is recorded on [escapedRequests] instead of reaching the
  /// network. [dispose] restores the previous overrides.
  static Future<NativeRootHarness> create() async {
    final directory = await Directory.systemTemp.createTemp('native_root_');
    FlutterSecureStorage.setMockInitialValues({});
    final escapes = _EscapeRecorder();
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = escapes;
    return NativeRootHarness._(
      directory: directory,
      previousOverrides: previousOverrides,
      escapes: escapes,
    ).._routeDefaults();
  }

  /// The user the session fixture signs in.
  static const String userId = 'user-1';

  /// The token of the session the fixture's `get-session` answers with.
  static const String sessionToken = 'session-tok-renewed';

  /// The address of the fixture server. `.invalid` never resolves, so a
  /// request that escaped [server] could not reach anything either.
  static const String serverUrl = 'https://bge.test.invalid';

  /// The fixture server's stable id.
  static const String bgeServerId = '550e8400-e29b-41d4-a716-446655440000';

  /// The id of the household in [householdPageWithOne].
  static const String householdId = 'hh_1';

  /// A household row as `GET /api/households` embeds it, with the signed-in
  /// user as its member: `_householdRow` and `_memberRow` in
  /// `dio_network/test/household/household_remote_data_source_fetch_test.dart`,
  /// cut to what the remote reads. The cache lists a household for the members
  /// it holds, so a row with no member for the user never appears.
  static final Map<String, Object?> householdPageWithOne = {
    'households': [
      {
        'id': householdId,
        'name': 'Game Night HQ',
        'description': null,
        'image': null,
        'languageTagId': null,
        'createdById': userId,
        'visibility': 'Private',
        'deletedAt': null,
        'createdAt': '2026-01-15T10:30:00.000Z',
        'updatedAt': '2026-01-15T10:30:00.000Z',
        'languageTag': null,
        'members': [
          {
            'id': 'hm_1',
            'userId': userId,
            'householdId': householdId,
            'showAllGames': true,
            'origin': 'Founder',
            'addedById': null,
            'createdAt': '2026-01-15T10:30:00.000Z',
            'updatedAt': '2026-01-15T10:30:00.000Z',
            'role': {
              'id': 'hr_1',
              'householdMemberId': 'hm_1',
              'roleId': 'role_1',
              'role': {'id': 'role_1', 'name': 'HouseholdOwner'},
            },
            'user': {
              'id': userId,
              'username': 'ada',
              'profile': {'avatarUrl': null, 'displayName': 'Ada'},
            },
          },
        ],
      },
    ],
    'pagination': {
      'page': 1,
      'limit': 100,
      'total': 1,
      'totalPages': 1,
      'hasMore': false,
    },
  };

  /// The fixture server's discovery document: email and password sign-in.
  static final ServerIdentity identity = testServerIdentity().copyWith(
    serverId: bgeServerId,
    issuer: serverUrl,
  );

  static const _keyService = _FixedKeyService();

  /// The fake server every swapped `Dio` sends to. Answers the default routes
  /// from [create]; a test adds or replaces routes on it.
  final ScriptedServer server = ScriptedServer();

  final Directory _directory;
  final HttpOverrides? _previousOverrides;
  final _EscapeRecorder _escapes;
  final _FileExecutorFactory _executorFactory;

  NativePlatformBootstrap? _bootstrap;
  ServerOrchestrator? _orchestrator;

  /// Each request that reached a `Dio`'s default adapter instead of [server],
  /// as `METHOD url`, in arrival order. Each was refused before it left the
  /// process.
  List<String> get escapedRequests => List.unmodifiable(_escapes.requests);

  /// The orchestrator the latest [boot] built. Throws before the first boot
  /// and after [shutdown].
  ServerOrchestrator get orchestrator =>
      _orchestrator ??
      (throw StateError('No orchestrator: call boot() first.'));

  /// The orchestrator's active server context. Throws when none is active.
  ServerContext get active =>
      orchestrator.getActiveContext() ??
      (throw StateError('No active server: call addServer() first.'));

  /// The active context's container, which resolves from the open user
  /// scope first and falls through to the server scope.
  DependencyContainer get container => active.container;

  /// Builds a new [NativePlatformBootstrap] over the same files and keychain
  /// and runs its `initialize()`, then swaps the transport if a server came
  /// back active. A second boot after [shutdown] is a restart.
  ///
  /// The harness counts as booted only once `initialize()` returns. One that
  /// throws has already rolled back what it built, so the harness keeps
  /// neither the bootstrap nor the orchestrator it disposed, and the next
  /// [boot] starts over on a new bootstrap.
  Future<void> boot() async {
    if (_bootstrap != null) {
      throw StateError('Already booted: call shutdown() first.');
    }
    _orchestrator = null;
    final bootstrap = NativePlatformBootstrap(
      keyService: _keyService,
      executorFactory: _executorFactory,
      orchestratorFactory:
          ({
            required serverRepository,
            required preferencesRepository,
            required contextFactory,
          }) => _orchestrator = ServerOrchestratorImpl(
            serverRepository: serverRepository,
            preferencesRepository: preferencesRepository,
            contextFactory: contextFactory,
          ),
      deleteStoredSessions: () async {},
    );
    try {
      await bootstrap.initialize();
    } catch (_) {
      _orchestrator = null;
      rethrow;
    }
    _bootstrap = bootstrap;
    if (orchestrator.activeServerId != null) swapTransport();
  }

  /// Adds the fixture server through `addAndActivateServer`, as onboarding
  /// does, then swaps the transport under its new scope.
  Future<void> addServer() async {
    await orchestrator.addAndActivateServer(
      displayName: 'Game Night Server',
      serverUrl: serverUrl,
      bgeServerId: bgeServerId,
      identity: identity,
    );
    swapTransport();
  }

  /// Points the active server scope's `Dio` at [server]. Each activation
  /// that installs the scope builds a new `Dio`, so this has to follow every
  /// one of them.
  void swapTransport() => container.get<Dio>().httpClientAdapter = server;

  /// Signs the fixture user in with email and password through the real
  /// `AuthRepositoryImpl`: a sign-in grant, then a session read.
  Future<void> signIn() => container.get<AuthRepository>().signIn(
    email: 'test@example.com',
    password: 'correct horse battery staple',
  );

  /// Enters on the session the keychain holds, without asking the server, as
  /// a start with no network does.
  Future<void> restoreSession() =>
      container.get<AuthRepository>().restoreCachedSession();

  /// Opens the user scope for [userId], which runs every user installer, as
  /// the shell does once the user is signed in.
  Future<void> activateUser() =>
      container.get<UserSessionScope>().activate(userId);

  /// Waits until the household, collection and event hydrates have each
  /// landed a pass ([HydrationState.refreshed]).
  ///
  /// The user tier sends its first requests after [activateUser] returns, so
  /// a test that reads the cache or counts requests waits on this first. It
  /// waits on the condition, not a delay. A pass that fails fails it at once,
  /// and one that never runs fails it after [timeout], each naming the
  /// status; see [awaitRefreshed].
  Future<void> awaitHydrated({
    Duration timeout = const Duration(seconds: 10),
  }) => awaitRefreshed({
    'HouseholdHydrationStatus': container.get<HouseholdHydrationStatus>(),
    'GameCollectionHydrationStatus': container
        .get<GameCollectionHydrationStatus>(),
    'EventHydrationStatus': container.get<EventHydrationStatus>(),
  }, timeout: timeout);

  /// Waits until [server] has recorded at least [count] requests to
  /// [method] [pathSuffix], and returns them. Throws a [TimeoutException]
  /// after [timeout].
  ///
  /// For a request the root sends after [activateUser] returns and that no
  /// status reports, such as the caller access read.
  Future<List<RecordedRequest>> awaitRequests(
    String method,
    String pathSuffix, {
    int count = 1,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await pollUntil(
      () => server.requestsTo(method, pathSuffix).length >= count,
      describe: () =>
          'Fewer than $count $method $pathSuffix requests arrived: '
          '${server.requests.map((r) => '${r.method} ${r.path}').toList()}',
      timeout: timeout,
    );
    return server.requestsTo(method, pathSuffix);
  }

  /// Joins the user tier's [SyncQueueDrain] pass in flight, or runs one, and
  /// returns when that pass completes. Throws a [TimeoutException] after
  /// [timeout].
  ///
  /// The drain joins a pass in flight, so this waits out the pass the user
  /// tier starts at activation, which runs after [activateUser] returns and
  /// which no status reports. With none in flight it runs one, which sends
  /// whatever is queued.
  ///
  /// A test waits on this before it queues an op that it means a later pass
  /// to find, since a pass already in flight may or may not read it, and
  /// before it asserts what a pass did not send. It cannot show that the
  /// root started a pass of its own, since it runs one where none is.
  Future<void> joinOrRunDrainPass({
    Duration timeout = const Duration(seconds: 10),
  }) => container.get<SyncQueueDrain>().drain().timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      'The sync drain still had a pass in flight',
      timeout,
    ),
  );

  /// Disposes the bootstrap, closing every scope and database, as the
  /// process ending does. The files and the keychain stay for the next
  /// [boot].
  Future<void> shutdown() async {
    final bootstrap = _bootstrap;
    _bootstrap = null;
    _orchestrator = null;
    await bootstrap?.dispose();
  }

  /// Shuts down, restores the previous `HttpOverrides` and deletes the temp
  /// directory, then throws a [StateError] if any request escaped [server]
  /// or reached it with no route to answer it. Either counts from [create]
  /// on: `server.clear()` forgets only the requests a test counts.
  ///
  /// The cleanup comes first, so a failure never leaks the directory or the
  /// overrides. Register it with `addTearDown`, where the throw fails the
  /// test: under the root, transport errors are caught and become a failed
  /// state, not a failed test.
  ///
  /// A shutdown that throws is reported with those requests, not instead of
  /// them, since a request that went nowhere may be what left the root
  /// unable to shut down.
  Future<void> dispose() async {
    Object? shutdownError;
    StackTrace? shutdownStack;
    try {
      await shutdown();
    } on Object catch (error, stack) {
      shutdownError = error;
      shutdownStack = stack;
    } finally {
      HttpOverrides.global = _previousOverrides;
      if (_directory.existsSync()) await _directory.delete(recursive: true);
    }

    final problems = [
      for (final request in server.unrouted)
        'no route answered ${request.method} ${request.path}',
      for (final request in _escapes.requests)
        '$request escaped ScriptedServer: its Dio was never swapped',
    ];
    if (shutdownError != null) {
      if (problems.isEmpty) {
        Error.throwWithStackTrace(shutdownError, shutdownStack!);
      }
      throw StateError(
        [
          'shutdown() threw $shutdownError',
          ...problems,
          '$shutdownStack',
        ].join('\n'),
      );
    }
    if (problems.isNotEmpty) {
      throw StateError(problems.join('\n'));
    }
  }

  void _routeDefaults() {
    server
      ..json('POST', '/sign-in/email', _grantJson())
      ..json('GET', '/get-session', _sessionJson())
      ..json('POST', '/sign-out', <String, dynamic>{})
      ..json('GET', '/api/households', _emptyHouseholdPage)
      ..json('GET', '/api/game-collections', _emptyCollectionPage)
      ..json('GET', '/api/events', _emptyEventPage)
      ..json('GET', '/api/users/me/access', _someAccess);
  }
}

// The wire fixtures, each the success case of the suite named above it, cut
// to the smallest answer the remote accepts.

// `dio_network/test/auth/auth_repository_impl_body_test.dart`.
Map<String, dynamic> _wireUser() => {
  'id': NativeRootHarness.userId,
  'name': 'testuser',
  'email': 'test@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

Map<String, dynamic> _grantJson() => {
  'token': 'session-tok-abc',
  'user': _wireUser(),
};

Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': NativeRootHarness.sessionToken,
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': NativeRootHarness.userId,
  },
  'user': _wireUser(),
};

// `platform/web/test/web_household_hydrate_seam_test.dart`.
const Map<String, Object> _emptyHouseholdPage = {
  'households': <Object?>[],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 0,
    'totalPages': 0,
    'hasMore': false,
  },
};

// `dio_network/test/game_collection/game_collection_remote_data_source_impl_test.dart`.
const Map<String, Object> _emptyCollectionPage = {
  'collections': <Object?>[],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 0,
    'totalPages': 0,
    'hasMore': false,
  },
};

// `dio_network/test/event/event_remote_data_source_impl_test.dart`. An empty
// list counts no pages: the hydrate treats a first page that counts one for
// no events as contradicting itself, and the pass fails.
const Map<String, Object> _emptyEventPage = {
  'events': <Object?>[],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 0,
    'totalPages': 0,
    'hasMore': false,
  },
};

// `dio_network/test/user/user_remote_data_source_impl_test.dart`, the
// `fetchAccess` success case. It allows something on purpose: an answer that
// denies everything makes the reader ask again after its recheck delay, which
// would put a second request and a pending timer into every root test.
const _someAccess = {
  'access': {
    'DataGateway': {
      'create': 'all',
      'read': 'all',
      'update': 'some',
      'delete': 'none',
      'manage': 'none',
    },
    // The session asks about households too (#684); a reply that omits a
    // requested type is malformed, so the canned one answers both.
    'Household': {
      'create': 'none',
      'read': 'none',
      'update': 'none',
      'delete': 'none',
      'manage': 'none',
    },
    // And the server settings (#807), for the same reason.
    'SystemSetting': {
      'create': 'none',
      'read': 'none',
      'update': 'none',
      'delete': 'none',
      'manage': 'none',
    },
  },
};

/// Hands out [_RefusingHttpClient]s, which record each request on [requests].
///
/// dio's `IOHttpClientAdapter` makes its `HttpClient` on its first request,
/// so a `Dio` whose adapter was never swapped gets one of these.
class _EscapeRecorder extends HttpOverrides {
  /// Each refused request, as `METHOD url`, in arrival order.
  final List<String> requests = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RefusingHttpClient(requests);
}

/// An `HttpClient` that connects to nothing: each request it is asked to open
/// is recorded and refused.
///
/// Recording at `openUrl` rather than refusing the client itself is what
/// names the request: the `HttpClient` is made before dio has a URL, and the
/// stack at that point ends inside dio's interceptor chain.
class _RefusingHttpClient implements HttpClient {
  _RefusingHttpClient(this._requests);

  final List<String> _requests;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _refuse('$method $url');

  /// dio closes the client with its `Dio`.
  @override
  void close({bool force = false}) {}

  /// dio sets its timeouts on the client it makes, which do nothing here. Any
  /// other call opens a request some other way, and is refused too.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isAccessor ? null : _refuse('${invocation.memberName}');

  Never _refuse(String request) {
    _requests.add(request);
    throw StateError(
      'A request escaped ScriptedServer: $request was sent on a Dio whose '
      'adapter was not swapped.',
    );
  }
}

/// Answers fixed keys. Nothing asks for one while encryption is off.
class _FixedKeyService implements EncryptionKeyService {
  const _FixedKeyService();

  @override
  Future<String> getOrCreateServerKey(String serverId) async => 'a' * 64;

  @override
  Future<String> getOrCreateMetaKey() async => 'b' * 64;

  @override
  Future<String?> findServerKey(String serverId) async => 'a' * 64;

  @override
  Future<String?> findMetaKey() async => 'b' * 64;

  @override
  Future<void> deleteServerKey(String serverId) async {}

  @override
  Future<void> deleteMetaKey() async {}
}

/// Opens unencrypted databases as files in [directory]: `meta.db`, and
/// `server-<bgeServerId>.db` for each server.
///
/// [resolveDatabaseFile] answers the meta file for any path. Only a reset and
/// a key-loss recovery ask for it, and with encryption off no key can be
/// lost.
class _FileExecutorFactory extends EncryptedExecutorFactory {
  _FileExecutorFactory({required super.keyService, required this.directory})
    : super(encryptionEnabled: false);

  final Directory directory;

  File get _metaFile => File('${directory.path}/meta.db');

  @override
  QueryExecutor metaExecutor() => NativeDatabase(_metaFile);

  @override
  QueryExecutor serverExecutor(
    String serverId, {
    String? relativeDatabasePath,
  }) => NativeDatabase(File('${directory.path}/server-$serverId.db'));

  @override
  Future<File> resolveDatabaseFile(String relativePath) async => _metaFile;
}
