import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

class _MockServerContext extends Mock implements ServerContext {}

class _MockDependencyContainer extends Mock implements DependencyContainer {}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockServerRepository extends Mock implements ServerRepository {}

class _MockUserDataExporter extends Mock implements UserDataExporter {}

const _localServerId = 'local-cuid-1';
const _bgeServerId = 'bge-uuid-1234';

// The locally-editable nickname deliberately differs from the
// server-vended identity name, so the envelope test pins `serverName`
// to the vended source rather than the nickname.
const _displayNameNickname = 'My Home Server';
const _vendedServerName = 'Example BGE';

const _buildInfo = BuildInfo(
  version: '0.1.0',
  buildNumber: '42',
  appName: 'Board Games Empire',
  packageName: 'com.example.bge',
);

final _session = AuthResponse(
  token: 'session-token',
  user: AuthUser(
    id: 'user-1',
    username: 'alice',
    email: 'alice@example.com',
    emailVerified: true,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
);

ServerIdentity _identity() => const ServerIdentity(
  wellKnownSchemaVersion: 1,
  serverId: _bgeServerId,
  name: _vendedServerName,
  issuer: 'https://bge.example.com',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
);

ServerConfig _serverConfig() => ServerConfig(
  id: _localServerId,
  displayName: _displayNameNickname,
  serverUrl: 'https://bge.example.com',
  connectionState: ConnectionState.active,
  bgeServerId: _bgeServerId,
  cachedIdentity: _identity(),
  lastIdentityFetchedAt: DateTime.utc(2026, 7),
);

void main() {
  setUpAll(() {
    registerFallbackValue(_MockServerContext());
  });

  group('UserDataExportBundler', () {
    late _MockServerContext context;
    late _MockDependencyContainer container;
    late _MockAuthRepository authRepository;
    late _MockServerRepository serverRepository;
    late UserDataExportRegistryImpl registry;

    setUp(() {
      context = _MockServerContext();
      container = _MockDependencyContainer();
      authRepository = _MockAuthRepository();
      serverRepository = _MockServerRepository();
      registry = UserDataExportRegistryImpl();

      when(() => context.serverId).thenReturn(_localServerId);
      when(() => context.container).thenReturn(container);
      when(() => container.get<AuthRepository>()).thenReturn(authRepository);
    });

    UserDataExportBundler bundler({DateTime Function()? now}) =>
        UserDataExportBundler(
          registry: registry,
          serverRepository: serverRepository,
          buildInfo: _buildInfo,
          now: now ?? () => DateTime.utc(2026, 5, 17, 19, 33),
        );

    void stubAuthenticated() {
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => _session);
      when(
        () => serverRepository.getServer(_localServerId),
      ).thenAnswer((_) async => _serverConfig());
    }

    _MockUserDataExporter exporterReturning(
      String key,
      Map<String, Object?>? payload,
    ) {
      final exporter = _MockUserDataExporter();
      when(() => exporter.key).thenReturn(key);
      when(() => exporter.export(context)).thenAnswer((_) async => payload);
      return exporter;
    }

    test('assembles the envelope with locked metadata sourcing', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('profile', {'username': 'alice'}))
        ..register(
          exporterReturning('gameCollection', {'entries': <Object?>[]}),
        );

      final bundle = await bundler().assemble(context);

      expect(bundle, {
        'schemaVersion': 1,
        'bgeClientVersion': '0.1.0',
        'exportedAt': '2026-05-17T19:33:00.000Z',
        // The stable server-vended id (data-controller identity),
        // NOT the local ServerConfig.id the context is keyed by.
        'serverId': _bgeServerId,
        // The server-vended identity name, NOT the locally-editable
        // displayName nickname ('My Home Server').
        'serverName': _vendedServerName,
        'userId': 'user-1',
        'categories': {
          'profile': {'username': 'alice'},
          'gameCollection': {'entries': <Object?>[]},
        },
      });
    });

    test('serverName is the vended identity name, not the nickname', () async {
      stubAuthenticated();

      final bundle = await bundler().assemble(context);

      expect(bundle['serverName'], _vendedServerName);
      expect(bundle['serverName'], isNot(_displayNameNickname));
    });

    test('categories preserve registration order', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('profile', {'a': 1}))
        ..register(exporterReturning('gameCollection', {'b': 2}));

      final bundle = await bundler().assemble(context);
      final categories = bundle['categories']! as Map<String, Object?>;

      expect(categories.keys.toList(), ['profile', 'gameCollection']);
    });

    test('a null payload omits the category entirely', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('empty', null))
        ..register(exporterReturning('profile', {'username': 'alice'}));

      final bundle = await bundler().assemble(context);
      final categories = bundle['categories']! as Map<String, Object?>;

      expect(categories, hasLength(1));
      expect(categories, isNot(contains('empty')));
      expect(categories, contains('profile'));
    });

    test('an empty registry yields an empty categories object', () async {
      stubAuthenticated();

      final bundle = await bundler().assemble(context);

      expect(bundle['categories'], equals(<String, Object?>{}));
    });

    test('a null cached session throws ExportNotAuthenticatedException '
        'before any server lookup or exporter runs', () async {
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => null);
      final exporter = exporterReturning('profile', {'a': 1});
      registry.register(exporter);

      await expectLater(
        () => bundler().assemble(context),
        throwsA(isA<ExportNotAuthenticatedException>()),
      );

      verifyNever(() => serverRepository.getServer(any()));
      verifyNever(() => exporter.export(any()));
    });

    test('a session-read AuthException is wrapped as '
        'ExportSessionUnavailableException (web-offline path) with the '
        'cause preserved and no server lookup or exporter runs', () async {
      const authFailure = AuthNetworkException(message: 'No connection.');
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => throw authFailure);
      final exporter = exporterReturning('profile', {'a': 1});
      registry.register(exporter);

      await expectLater(
        () => bundler().assemble(context),
        throwsA(
          isA<ExportSessionUnavailableException>().having(
            (e) => e.cause,
            'cause',
            same(authFailure),
          ),
        ),
      );

      verifyNever(() => serverRepository.getServer(any()));
      verifyNever(() => exporter.export(any()));
    });

    test('a null server config throws ExportUnknownServerException '
        'with the unresolved id, a null cause, and no exporter runs', () async {
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => _session);
      when(
        () => serverRepository.getServer(_localServerId),
      ).thenAnswer((_) async => null);
      final exporter = exporterReturning('profile', {'a': 1});
      registry.register(exporter);

      await expectLater(
        () => bundler().assemble(context),
        throwsA(
          isA<ExportUnknownServerException>()
              .having((e) => e.serverId, 'serverId', _localServerId)
              .having((e) => e.cause, 'cause', isNull),
        ),
      );

      verifyNever(() => exporter.export(any()));
    });

    test('a CorruptedServerIdentityException is wrapped as '
        'ExportUnknownServerException with the cause preserved and no '
        'exporter runs', () async {
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => _session);
      final corruption = CorruptedServerIdentityException(
        _localServerId,
        const FormatException('bad identity blob'),
      );
      when(
        () => serverRepository.getServer(_localServerId),
      ).thenAnswer((_) async => throw corruption);
      final exporter = exporterReturning('profile', {'a': 1});
      registry.register(exporter);

      await expectLater(
        () => bundler().assemble(context),
        throwsA(
          isA<ExportUnknownServerException>()
              .having((e) => e.serverId, 'serverId', _localServerId)
              .having((e) => e.cause, 'cause', same(corruption)),
        ),
      );

      verifyNever(() => exporter.export(any()));
    });

    test('an exporter failure fails the whole bundle fast', () async {
      stubAuthenticated();
      final failing = _MockUserDataExporter();
      when(() => failing.key).thenReturn('failing');
      when(
        () => failing.export(context),
      ).thenAnswer((_) async => throw StateError('boom'));
      final later = exporterReturning('later', {'a': 1});
      registry
        ..register(failing)
        ..register(later);

      await expectLater(() => bundler().assemble(context), throwsStateError);

      verifyNever(() => later.export(any()));
    });

    test(
      'exportedAt converts an injected local clock to UTC ISO-8601',
      () async {
        stubAuthenticated();
        final local = DateTime(2026, 5, 17, 12);

        final bundle = await bundler(now: () => local).assemble(context);

        expect(bundle['exportedAt'], local.toUtc().toIso8601String());
      },
    );

    test('the default clock emits a UTC timestamp', () async {
      stubAuthenticated();
      final before = DateTime.now().toUtc();

      final bundle = await UserDataExportBundler(
        registry: registry,
        serverRepository: serverRepository,
        buildInfo: _buildInfo,
      ).assemble(context);

      final exportedAt = DateTime.parse(bundle['exportedAt']! as String);
      expect(exportedAt.isUtc, isTrue);
      expect(
        exportedAt.isAfter(before.subtract(const Duration(seconds: 5))),
        isTrue,
      );
    });
  });
}
