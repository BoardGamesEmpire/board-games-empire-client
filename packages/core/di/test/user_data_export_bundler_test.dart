import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

class _MockDependencyContainer extends Mock implements DependencyContainer {}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockUserDataExporter extends Mock implements UserDataExporter {}

const _bgeServerId = 'bge-uuid-1234';

// The locally-editable nickname deliberately differs from the
// server-vended identity name, so the envelope tests pin `serverName`
// to the vended source rather than the nickname.
const _displayNameNickname = 'My nickname';
const _vendedServerName = 'Example BGE';

const _buildInfo = BuildInfo(
  version: '0.1.0',
  buildNumber: '42',
  appName: 'Board Games Empire',
  packageName: 'com.example.bge',
);

final AuthResponse _session = testAuthResponse().copyWith.user(
  id: 'user-1',
  username: 'alice',
);

ServerIdentity _identity() => testServerIdentity().copyWith(
  serverId: _bgeServerId,
  name: _vendedServerName,
);

void main() {
  late ActiveServer server;

  setUpAll(() {
    registerFallbackValue(
      ActiveServer(
        serverId: 'fallback',
        displayName: 'fallback',
        identity: _identity(),
        container: _MockDependencyContainer(),
      ),
    );
  });

  group('UserDataExportBundler', () {
    late _MockDependencyContainer container;
    late _MockAuthRepository authRepository;
    late UserDataExportRegistryImpl registry;

    setUp(() {
      container = _MockDependencyContainer();
      authRepository = _MockAuthRepository();
      registry = UserDataExportRegistryImpl();
      server = ActiveServer(
        serverId: 'local-1',
        displayName: _displayNameNickname,
        identity: _identity(),
        container: container,
      );

      when(() => container.get<AuthRepository>()).thenReturn(authRepository);
    });

    UserDataExportBundler bundler({DateTime Function()? now}) =>
        UserDataExportBundler(
          registry: registry,
          buildInfo: _buildInfo,
          now: now ?? () => DateTime.utc(2026, 5, 17, 19, 33),
        );

    void stubAuthenticated() {
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => _session);
    }

    _MockUserDataExporter exporterReturning(
      String key,
      Map<String, Object?>? payload, {
      bool confirmed = true,
    }) {
      final exporter = _MockUserDataExporter();
      when(() => exporter.key).thenReturn(key);
      when(
        () => exporter.export(server, refresh: any(named: 'refresh')),
      ).thenAnswer(
        (_) async => payload == null
            ? null
            : UserDataExport(payload, confirmed: confirmed),
      );
      return exporter;
    }

    test('assembles the envelope with locked metadata sourcing', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('profile', {'username': 'alice'}))
        ..register(
          exporterReturning('gameCollection', {'entries': <Object?>[]}),
        );

      final bundle = await bundler().assemble(server);

      expect(bundle.json, {
        'schemaVersion': 1,
        'bgeClientVersion': '0.1.0',
        'exportedAt': '2026-05-17T19:33:00.000Z',
        'serverId': _bgeServerId,
        'serverName': _vendedServerName,
        'userId': 'user-1',
        'categories': {
          'profile': {'username': 'alice'},
          'gameCollection': {'entries': <Object?>[]},
        },
      });
      expect(bundle.unconfirmedKeys, isEmpty);
    });

    test(
      'serverId and serverName come from the active server identity',
      () async {
        stubAuthenticated();

        final bundle = await bundler().assemble(server);

        expect(bundle.json['serverId'], server.identity.serverId);
        expect(bundle.json['serverName'], server.identity.name);
        expect(bundle.json['serverName'], isNot(_displayNameNickname));
        expect(bundle.json['serverId'], isNot(server.serverId));
      },
    );

    test('categories preserve registration order', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('profile', {'a': 1}))
        ..register(exporterReturning('gameCollection', {'b': 2}));

      final bundle = await bundler().assemble(server);
      final categories = bundle.json['categories']! as Map<String, Object?>;

      expect(categories.keys.toList(), ['profile', 'gameCollection']);
    });

    test('a null export omits the category entirely', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('empty', null))
        ..register(exporterReturning('profile', {'username': 'alice'}));

      final bundle = await bundler().assemble(server);
      final categories = bundle.json['categories']! as Map<String, Object?>;

      expect(categories, hasLength(1));
      expect(categories, isNot(contains('empty')));
      expect(categories, contains('profile'));
      expect(bundle.unconfirmedKeys, isEmpty);
    });

    test('an empty registry yields an empty categories object', () async {
      stubAuthenticated();

      final bundle = await bundler().assemble(server);

      expect(bundle.json['categories'], equals(<String, Object?>{}));
    });

    test('unconfirmedKeys lists the categories whose export is not '
        'confirmed, in registration order', () async {
      stubAuthenticated();
      registry
        ..register(exporterReturning('a', {'a': 1}))
        ..register(exporterReturning('b', {'b': 2}, confirmed: false))
        ..register(exporterReturning('c', {'c': 3}, confirmed: false));

      final bundle = await bundler().assemble(server);

      expect(bundle.unconfirmedKeys, ['b', 'c']);
      expect(
        (bundle.json['categories']! as Map<String, Object?>).keys,
        ['a', 'b', 'c'],
      );
      expect(() => bundle.unconfirmedKeys.add('d'), throwsUnsupportedError);
    });

    test('refresh is passed to every exporter', () async {
      stubAuthenticated();
      final first = exporterReturning('first', {'a': 1});
      final second = exporterReturning('second', {'b': 2});
      registry
        ..register(first)
        ..register(second);

      await bundler().assemble(server, refresh: true);

      verify(() => first.export(server, refresh: true)).called(1);
      verify(() => second.export(server, refresh: true)).called(1);
    });

    test('refresh defaults to false', () async {
      stubAuthenticated();
      final exporter = exporterReturning('first', {'a': 1});
      registry.register(exporter);

      await bundler().assemble(server);

      verify(() => exporter.export(server)).called(1);
    });

    test('no exporter runs before the session gate passes: a null cached '
        'session throws ExportNotAuthenticatedException', () async {
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => null);
      final exporter = exporterReturning('profile', {'a': 1});
      registry.register(exporter);

      await expectLater(
        () => bundler().assemble(server),
        throwsA(isA<ExportNotAuthenticatedException>()),
      );

      verifyNever(
        () => exporter.export(any(), refresh: any(named: 'refresh')),
      );
    });

    test('a session-read AuthException is wrapped as '
        'ExportSessionUnavailableException with the cause preserved and no '
        'exporter runs', () async {
      const authFailure = AuthNetworkException(message: 'No connection.');
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => throw authFailure);
      final exporter = exporterReturning('profile', {'a': 1});
      registry.register(exporter);

      await expectLater(
        () => bundler().assemble(server),
        throwsA(
          isA<ExportSessionUnavailableException>().having(
            (e) => e.cause,
            'cause',
            same(authFailure),
          ),
        ),
      );

      verifyNever(
        () => exporter.export(any(), refresh: any(named: 'refresh')),
      );
    });

    test('an exporter failure fails the whole bundle fast', () async {
      stubAuthenticated();
      final failing = _MockUserDataExporter();
      when(() => failing.key).thenReturn('failing');
      when(
        () => failing.export(server, refresh: any(named: 'refresh')),
      ).thenAnswer((_) async => throw StateError('boom'));
      final later = exporterReturning('later', {'a': 1});
      registry
        ..register(failing)
        ..register(later);

      await expectLater(() => bundler().assemble(server), throwsStateError);

      verifyNever(() => later.export(any(), refresh: any(named: 'refresh')));
    });

    // An exporter whose scope is torn down mid-export answers null, as
    // the collection exporter does when its repository is gone; the
    // session read after it reflects the change [change] made.
    _MockUserDataExporter exporterEndingSession(void Function() change) {
      final exporter = _MockUserDataExporter();
      when(() => exporter.key).thenReturn('gameCollection');
      when(
        () => exporter.export(server, refresh: any(named: 'refresh')),
      ).thenAnswer((_) async {
        change();
        return null;
      });
      return exporter;
    }

    test(
      'a session that ends while the exporters run fails the export',
      () async {
        AuthResponse? current = _session;
        when(
          () => authRepository.getCachedSession(),
        ).thenAnswer((_) async => current);
        registry.register(exporterEndingSession(() => current = null));

        await expectLater(
          () => bundler().assemble(server),
          throwsA(isA<ExportNotAuthenticatedException>()),
        );
      },
    );

    test('a different user by the end fails the export', () async {
      AuthResponse? current = _session;
      when(
        () => authRepository.getCachedSession(),
      ).thenAnswer((_) async => current);
      registry.register(
        exporterEndingSession(
          () => current = _session.copyWith.user(id: 'user-2'),
        ),
      );

      await expectLater(
        () => bundler().assemble(server),
        throwsA(isA<ExportNotAuthenticatedException>()),
      );
    });

    test(
      'a failing second session read is a session-unavailable failure',
      () async {
        const authFailure = AuthNetworkException(message: 'No connection.');
        var reads = 0;
        when(() => authRepository.getCachedSession()).thenAnswer((_) async {
          reads += 1;
          if (reads > 1) throw authFailure;
          return _session;
        });
        registry.register(exporterReturning('profile', {'a': 1}));

        await expectLater(
          () => bundler().assemble(server),
          throwsA(
            isA<ExportSessionUnavailableException>().having(
              (e) => e.cause,
              'cause',
              same(authFailure),
            ),
          ),
        );
        expect(reads, 2);
      },
    );

    test(
      'exportedAt converts an injected local clock to UTC ISO-8601',
      () async {
        stubAuthenticated();
        final local = DateTime(2026, 5, 17, 12);

        final bundle = await bundler(now: () => local).assemble(server);

        expect(bundle.json['exportedAt'], local.toUtc().toIso8601String());
      },
    );

    test('the default clock emits a UTC timestamp', () async {
      stubAuthenticated();
      final before = DateTime.now().toUtc();

      final bundle = await UserDataExportBundler(
        registry: registry,
        buildInfo: _buildInfo,
      ).assemble(server);

      final exportedAt = DateTime.parse(bundle.json['exportedAt']! as String);
      expect(exportedAt.isUtc, isTrue);
      expect(
        exportedAt.isAfter(before.subtract(const Duration(seconds: 5))),
        isTrue,
      );
    });
  });
}
