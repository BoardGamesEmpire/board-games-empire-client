import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show GameCollectionRemoteDataSourceImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// A collection row as `GET /api/game-collections` returns it, trimmed to the
/// fields the mapper requires. The full-fidelity fixture lives with the data
/// source's own tests (`dio_network/test/game_collection/`); duplicating it
/// here would be a second copy of the wire shape to keep in step, and nothing
/// below asserts on mapping beyond the id.
Map<String, dynamic> _row() => {
  'id': 'gc_1',
  'userId': 'user-abc',
  'platformGameId': 'pg_1',
  'medium': 'Physical',
  'quantity': 1,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-02-02T09:00:00.000Z',
};

String _listBody() => jsonEncode({
  'collections': [_row()],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 1,
    'totalPages': 1,
    'hasMore': false,
  },
});

/// #368: the per-origin collection remote is the web network installer's to
/// register, beside the household remote (#125) and on the same convention as
/// native's (`register_server_network.dart`). It shares the per-origin Dio,
/// which carries the base URL and the browser-owned session cookie, and adds
/// no auth of its own.
///
/// Like the household suite next door, these run on the VM and replace the
/// transport, so they prove the *registered* remote over the *registered* Dio
/// classifies as the contract says. They say nothing about browser-specific
/// failure shapes; #369 owns that gap.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetworkWeb(
      container: container,
      identity: testServerIdentity(),
      // Uri.base has no origin on the VM, so tests inject one; production
      // defaults to WebDioFactory.currentOrigin (the address bar).
      originProvider: () => 'https://bge.example.com',
    );
  });

  tearDown(() async {
    await container.dispose();
  });

  /// Replaces the transport under the Dio the installer registered.
  void canned({required String body, required int status}) {
    container.get<Dio>().httpClientAdapter = CannedAdapter(
      body: body,
      statusCode: status,
    );
  }

  GameCollectionRemoteDataSource remote() =>
      container.get<GameCollectionRemoteDataSource>();

  group('registerServerNetworkWeb collection remote (#368)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(remote(), isA<GameCollectionRemoteDataSourceImpl>());
      // Registering the concrete type alongside the interface would let a
      // consumer bind to it and defeat the seam, and every other assertion
      // here would still pass.
      expect(
        container.isRegistered<GameCollectionRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers beside the household remote, not instead of it', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });

    test('resolves as a singleton — a hydrate and a drain would share one '
        'instance over the shared per-origin Dio', () {
      expect(remote(), same(remote()));
    });

    test('requests through the Dio the installer registered, not one of its '
        'own', () async {
      // The adapter is swapped on the *registered* Dio, so a parsed page can
      // only mean the remote sent its request through that instance.
      canned(body: _listBody(), status: 200);

      final page = await remote().fetchCollectionPage();

      expect(page.items.single.id, 'gc_1');
      expect(page.meta.hasMore, isFalse);
    });
  });

  group('collection classification over the web transport (#368)', () {
    test(
      'a 2xx whose body is not JSON is permanent, not a retry forever',
      () async {
        // Web is where a captive portal or an SPA catch-all is most likely to
        // answer the list route with HTML under a 200.
        canned(body: '<html>Sign in to the hotel wifi</html>', status: 200);

        await expectLater(
          remote().fetchCollectionPage(),
          throwsA(isA<GameCollectionRemotePermanentException>()),
        );
      },
    );

    test(
      'an envelope-free 403 on a queued removal is transient — a proxy '
      'blocked it, and filing it permanent would discard the deletion',
      () async {
        canned(body: '<html>Blocked by corporate proxy</html>', status: 403);

        await expectLater(
          remote().removeEntry('gc_1'),
          throwsA(isA<GameCollectionRemoteTransientException>()),
        );
      },
    );
  });
}
