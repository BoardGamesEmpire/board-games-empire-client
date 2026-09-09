import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import '../support/canned_adapter.dart';

const _kHtml = '<!doctype html><html><body>Sign in to continue</body></html>';

/// Nest's rendering of any `HttpException` that carries a message.
String _envelope(int status, String error) => jsonEncode({
  'statusCode': status,
  'message': 'errors.game_collection.not_found',
  'error': error,
});

Map<String, dynamic> _entry(String id) => {
  'id': id,
  'userId': 'user-abc',
  'platformGameId': 'pg_1',
  'medium': 'Physical',
  'releaseId': null,
  'quantity': 1,
  'rating': null,
  'playCount': 0,
  'playAgain': null,
  'favorite': false,
  'comment': null,
  'lastPlayed': null,
  'lastUpdated': null,
  'deletedAt': null,
  'deleteReason': null,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-02-02T09:00:00.000Z',
  'visibility': 'Private',
  'platformGame': {
    'id': 'pg_1',
    'image': null,
    'thumbnail': null,
    'platform': {'id': 'plat_1', 'name': 'Tabletop', 'slug': 'tabletop'},
    'game': {
      'id': 'g_1',
      'title': 'Brass: Birmingham',
      'subtitle': null,
      'image': null,
      'thumbnail': null,
    },
  },
};

void main() {
  GameCollectionRemoteDataSource remoteOver(Dio dio) =>
      GameCollectionRemoteDataSourceImpl(dio);

  // The rows measured on #351, against a real Dio. The suite next door stubs
  // `Dio` itself, so Dio's own body handling never runs and every one of these
  // passes against the bug.
  group('an answered request classifies by its status (#351)', () {
    test('an HTML 200 under text/html is permanent, with its status', () async {
      final remote = remoteOver(
        cannedDio(body: _kHtml, statusCode: 200, contentType: 'text/html'),
      );

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
    });

    test('an HTML 200 under application/json keeps its status', () async {
      final remote = remoteOver(cannedDio(body: _kHtml, statusCode: 200));

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
    });

    test('a truncated JSON 200 is permanent, with its status', () async {
      final remote = remoteOver(
        cannedDio(body: '{"collections": [{"id": "gc_1"', statusCode: 200),
      );

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
    });

    test('an HTML 400 under application/json keeps its status', () async {
      final remote = remoteOver(cannedDio(body: _kHtml, statusCode: 400));

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    test('an HTML 404 under application/json is transient, with its '
        'status', () async {
      final remote = remoteOver(cannedDio(body: _kHtml, statusCode: 404));

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('a 5xx with an HTML body stays transient', () async {
      final remote = remoteOver(
        cannedDio(body: _kHtml, statusCode: 502, contentType: 'text/html'),
      );

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a valid envelope still maps through the real pipeline', () async {
      final remote = remoteOver(
        cannedDio(
          body: jsonEncode({
            'collections': [_entry('gc_1')],
          }),
          statusCode: 200,
        ),
      );

      final page = await remote.fetchCollectionPage();
      expect(page, hasLength(1));
      expect(page.single.id, 'gc_1');
    });
  });

  // `_send` moves to `Response<String>`, which takes the body out from under
  // Dio's transformer — including the 50 KB isolate offload it applies.
  group('a large body still decodes off-isolate', () {
    test('a page over the 50 KB threshold parses correctly', () async {
      final entries = List.generate(120, (i) => _entry('gc_$i'));
      final body = jsonEncode({'collections': entries});
      expect(
        body.codeUnits.length,
        greaterThan(50 * 1024),
        reason: 'the fixture must cross the isolate threshold to test it',
      );

      final remote = remoteOver(cannedDio(body: body, statusCode: 200));

      final page = await remote.fetchCollectionPage(limit: 100);
      expect(page, hasLength(120));
      expect(page.last.id, 'gc_119');
    });
  });

  // `fetch`'s forcing block is skipped when the injected instance is already
  // set to bytes/stream, and `assureResponse` then casts to `String` anyway —
  // the same status-losing throw by another route. So the type is pinned on
  // the request rather than inherited (#360).
  group('responseType is pinned per request', () {
    for (final type in [ResponseType.bytes, ResponseType.stream]) {
      test('an injected Dio set to responseType.$type cannot reintroduce the '
          'status-losing cast', () async {
        final dio = cannedDio(body: _kHtml, statusCode: 400)
          ..options.responseType = type;

        await expectLater(
          remoteOver(dio).fetchCollectionPage(),
          throwsA(
            isA<GameCollectionRemotePermanentException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
      });
    }
  });

  // The 404 branch reads the API's error envelope before it will call a 404 a
  // statement about a row. With the body arriving as a `String`, that check
  // has to probe it — otherwise every application 404 reads as unreachable.
  group('the 404 envelope check survives a String body', () {
    test('an application 404 on a single entry is a missing row', () async {
      final remote = remoteOver(
        cannedDio(body: _envelope(404, 'Not Found'), statusCode: 404),
      );

      await expectLater(
        remote.fetchEntry('gc_1'),
        throwsA(isA<GameCollectionNotFoundException>()),
      );
    });

    test('a proxy 404 on the same route is transient, not a missing '
        'row', () async {
      final remote = remoteOver(
        cannedDio(body: _kHtml, statusCode: 404, contentType: 'text/html'),
      );

      await expectLater(
        remote.fetchEntry('gc_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('an application 404 on a removal means already removed', () async {
      final remote = remoteOver(
        cannedDio(body: _envelope(404, 'Not Found'), statusCode: 404),
      );

      await expectLater(
        remote.removeEntry('gc_1'),
        throwsA(isA<GameCollectionAlreadyRemovedException>()),
      );
    });

    test('a proxy 404 on a removal does not report the row removed', () async {
      final remote = remoteOver(
        cannedDio(body: _kHtml, statusCode: 404, contentType: 'text/html'),
      );

      await expectLater(
        remote.removeEntry('gc_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    // The probe that reads the envelope out of raw text is bounded, because it
    // runs synchronously on the UI isolate. That bound is a second condition on
    // the row-level 404 rule, and it narrows it: an envelope past the bound is
    // not read, so the 404 falls back to "the route was not reachable".
    //
    // The direction is the safe one — a removal retries instead of being
    // marked completed for a request the service may never have seen — and no
    // real envelope comes close to the bound. Pinned so the narrowing is a
    // decision on the record rather than a surprise.
    test('an envelope past the probe bound is not read, so the 404 stays '
        'transient', () async {
      final oversized = jsonEncode({
        'statusCode': 404,
        'message': 'x' * (8 * 1024),
        'error': 'Not Found',
      });

      final remote = remoteOver(cannedDio(body: oversized, statusCode: 404));

      await expectLater(
        remote.removeEntry('gc_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('an envelope comfortably inside the bound is still read', () async {
      final sized = jsonEncode({
        'statusCode': 404,
        'message': 'x' * 512,
        'error': 'Not Found',
      });

      final remote = remoteOver(cannedDio(body: sized, statusCode: 404));

      await expectLater(
        remote.removeEntry('gc_1'),
        throwsA(isA<GameCollectionAlreadyRemovedException>()),
      );
    });

    test('a list 404 is transient even with the envelope', () async {
      final remote = remoteOver(
        cannedDio(body: _envelope(404, 'Not Found'), statusCode: 404),
      );

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });
  });

  // No collection route emits a 407 either — it is defined to come from a
  // proxy, so it says the request never reached the application. Same
  // reasoning as #350, no per-source decision attached. The 403 half is #365.
  group('proxy-originated 4xx (#365, 407 half)', () {
    test('407 is transient on a queued write', () async {
      final remote = remoteOver(
        cannedDio(
          body: '<html>Proxy Authentication Required</html>',
          statusCode: 407,
          contentType: 'text/html',
        ),
      );

      await expectLater(
        remote.removeEntry('gc_1'),
        throwsA(
          isA<GameCollectionRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            407,
          ),
        ),
      );
    });

    test('407 is transient on a read too', () async {
      final remote = remoteOver(
        cannedDio(
          body: '<html>Proxy Authentication Required</html>',
          statusCode: 407,
          contentType: 'text/html',
        ),
      );

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('403 stays permanent here — the rule is not ported (#365)', () async {
      final remote = remoteOver(
        cannedDio(
          body: '<html>Blocked</html>',
          statusCode: 403,
          contentType: 'text/html',
        ),
      );

      await expectLater(
        remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });
  });
}
