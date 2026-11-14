import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

Map<String, dynamic> _row() => {
  'userId': 'u_1',
  'username': 'ana',
  'displayName': 'Ana B',
  'avatarUrl': 'https://cdn.example.test/a.png',
  'bio': 'Hi **there**',
  'pronouns': 'she/her',
  'location': 'Lisbon',
  'preferredPlayerCount': 4,
  'willingToTeach': true,
  'openToNewPlayers': false,
  'houseRulesPreference': 'No phones',
  'hostingCapability': true,
  'dietaryRestrictions': 'Vegan',
  'accessibilityNeeds': 'Large print',
  'reach': 'ExtendedNetwork',
  'isSearchable': true,
};

String _profile([Map<String, dynamic>? row]) =>
    jsonEncode({'profile': row ?? _row()});

String _envelope(int status, String error, String message, [String? code]) =>
    jsonEncode({
      'statusCode': status,
      'error': error,
      'message': message,
      'code': ?code,
    });

typedef _Sent = ({String method, String path, Object? data});

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body, this.status);

  final String body;
  final int status;
  final List<_Sent> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add((method: options.method, path: options.path, data: options.data));
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;

  UserProfileRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return UserProfileRemoteDataSourceImpl(dio);
  }

  group('fetchOwn', () {
    test("reads the owner's view", () async {
      final remote = answering(_profile());

      final profile = await remote.fetchOwn();

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/users/me/profile');
      expect(
        profile,
        const UserProfile(
          userId: 'u_1',
          username: 'ana',
          displayName: 'Ana B',
          avatarUrl: 'https://cdn.example.test/a.png',
          bio: 'Hi **there**',
          pronouns: 'she/her',
          location: 'Lisbon',
          preferredPlayerCount: 4,
          willingToTeach: true,
          openToNewPlayers: false,
          houseRulesPreference: 'No phones',
          hostingCapability: true,
          dietaryRestrictions: 'Vegan',
          accessibilityNeeds: 'Large print',
          reach: Reach.extendedNetwork,
          isSearchable: true,
        ),
      );
    });

    test('reads absent owner-only fields as null', () async {
      final row = _row()
        ..remove('dietaryRestrictions')
        ..remove('accessibilityNeeds')
        ..remove('reach')
        ..remove('isSearchable')
        ..['bio'] = null
        ..['preferredPlayerCount'] = null;
      final remote = answering(_profile(row));

      final profile = await remote.fetchOwn();

      expect(profile.dietaryRestrictions, isNull);
      expect(profile.accessibilityNeeds, isNull);
      expect(profile.reach, isNull);
      expect(profile.isSearchable, isNull);
      expect(profile.bio, isNull);
      expect(profile.preferredPlayerCount, isNull);
    });

    test('an unknown reach reads as unknown, not a failure', () async {
      final remote = answering(_profile({..._row(), 'reach': 'Galactic'}));

      expect((await remote.fetchOwn()).reach, Reach.unknown);
    });

    test('a body without profile is permanent', () async {
      final remote = answering(jsonEncode({'other': 1}));

      await expectLater(
        remote.fetchOwn(),
        throwsA(isA<UserProfilePermanentException>()),
      );
    });

    test('an enveloped 404 is not-found', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'Profile for user u_1 not found'),
        status: 404,
      );

      await expectLater(
        remote.fetchOwn(),
        throwsA(isA<UserProfileNotFoundException>()),
      );
    });

    test('ROUTE_NOT_FOUND is transient, not not-found', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'Cannot GET', 'ROUTE_NOT_FOUND'),
        status: 404,
      );

      await expectLater(
        remote.fetchOwn(),
        throwsA(isA<UserProfileTransientException>()),
      );
    });

    test('a 404 without the envelope is transient', () async {
      final remote = answering('<html>nope</html>', status: 404);

      await expectLater(
        remote.fetchOwn(),
        throwsA(isA<UserProfileTransientException>()),
      );
    });

    test('an enveloped 403 is refused', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'nope'),
        status: 403,
      );

      await expectLater(
        remote.fetchOwn(),
        throwsA(isA<UserProfileRefusedException>()),
      );
    });

    test('a 503 is transient', () async {
      final remote = answering(
        _envelope(503, 'Service Unavailable', 'down'),
        status: 503,
      );

      await expectLater(
        remote.fetchOwn(),
        throwsA(isA<UserProfileTransientException>()),
      );
    });
  });

  group('updateOwn', () {
    test("sends only the patch's fields", () async {
      final remote = answering(_profile());

      final result = await remote.updateOwn(
        const ProfilePatch(
          displayName: 'Ana B',
          bio: SettingValue.clear(),
          preferredPlayerCount: SettingValue.set(4),
          reach: Reach.friends,
        ),
      );

      expect(result.userId, 'u_1');
      expect(adapter.sent.single.method, 'PATCH');
      expect(adapter.sent.single.path, '/api/users/me/profile');
      expect(adapter.sent.single.data, {
        'displayName': 'Ana B',
        'bio': null,
        'preferredPlayerCount': 4,
        'reach': 'Friends',
      });
    });

    test('sends every field when the patch has every field', () async {
      final remote = answering(_profile());

      await remote.updateOwn(
        const ProfilePatch(
          displayName: 'Ana',
          bio: SettingValue.set('b'),
          pronouns: SettingValue.set('p'),
          location: SettingValue.set('l'),
          houseRulesPreference: SettingValue.set('h'),
          dietaryRestrictions: SettingValue.set('d'),
          accessibilityNeeds: SettingValue.set('a'),
          preferredPlayerCount: SettingValue.set(2),
          willingToTeach: false,
          openToNewPlayers: true,
          hostingCapability: false,
          isSearchable: true,
          reach: Reach.extendedNetwork,
        ),
      );

      expect(adapter.sent.single.data, {
        'displayName': 'Ana',
        'bio': 'b',
        'pronouns': 'p',
        'location': 'l',
        'houseRulesPreference': 'h',
        'dietaryRestrictions': 'd',
        'accessibilityNeeds': 'a',
        'preferredPlayerCount': 2,
        'willingToTeach': false,
        'openToNewPlayers': true,
        'hostingCapability': false,
        'isSearchable': true,
        'reach': 'ExtendedNetwork',
      });
    });

    test('clear is sent as null', () async {
      final remote = answering(_profile());

      await remote.updateOwn(
        const ProfilePatch(
          bio: SettingValue.clear(),
          pronouns: SettingValue.clear(),
          location: SettingValue.clear(),
          houseRulesPreference: SettingValue.clear(),
          dietaryRestrictions: SettingValue.clear(),
          accessibilityNeeds: SettingValue.clear(),
          preferredPlayerCount: SettingValue.clear(),
        ),
      );

      expect(adapter.sent.single.data, {
        'bio': null,
        'pronouns': null,
        'location': null,
        'houseRulesPreference': null,
        'dietaryRestrictions': null,
        'accessibilityNeeds': null,
        'preferredPlayerCount': null,
      });
    });

    group('ArgumentError, before any request', () {
      Future<void> refuses(ProfilePatch patch) async {
        final remote = answering(_profile());
        await expectLater(remote.updateOwn(patch), throwsArgumentError);
        expect(adapter.sent, isEmpty);
      }

      Future<void> accepts(ProfilePatch patch) async {
        final remote = answering(_profile());
        await remote.updateOwn(patch);
        expect(adapter.sent, hasLength(1));
      }

      test('for an empty patch', () => refuses(const ProfilePatch()));

      test(
        'for Reach.unknown',
        () => refuses(const ProfilePatch(reach: Reach.unknown)),
      );

      test(
        'for a blank display name',
        () => refuses(const ProfilePatch(displayName: ' \n ')),
      );

      test('for a player count outside 1..100', () async {
        await refuses(
          const ProfilePatch(preferredPlayerCount: SettingValue.set(0)),
        );
        await refuses(
          const ProfilePatch(preferredPlayerCount: SettingValue.set(101)),
        );
        await accepts(
          const ProfilePatch(preferredPlayerCount: SettingValue.set(1)),
        );
        await accepts(
          const ProfilePatch(preferredPlayerCount: SettingValue.set(100)),
        );
      });

      test("past a cap, measured the server's way: bio", () async {
        final atCap = '\u{1F600}' * UserProfileRemoteDataSource.maxBioLength;
        await accepts(ProfilePatch(bio: SettingValue.set(atCap)));
        await refuses(
          ProfilePatch(bio: SettingValue.set('${'a' * 2000}a')),
        );
        await refuses(
          ProfilePatch(bio: SettingValue.set('\u{1F600}' * 2001)),
        );
      });

      test('the bio is measured as sent, not trimmed', () async {
        await refuses(ProfilePatch(bio: SettingValue.set(' ${'a' * 2000}')));
      });

      test('the trimmed fields are measured after trimming', () async {
        await accepts(ProfilePatch(displayName: ' ${'a' * 64} '));
        await refuses(ProfilePatch(displayName: 'a' * 65));
        await accepts(
          ProfilePatch(pronouns: SettingValue.set(' ${'a' * 40} ')),
        );
        await refuses(ProfilePatch(pronouns: SettingValue.set('a' * 41)));
        await accepts(
          ProfilePatch(location: SettingValue.set(' ${'a' * 100} ')),
        );
        await refuses(ProfilePatch(location: SettingValue.set('a' * 101)));
        await accepts(
          ProfilePatch(
            houseRulesPreference: SettingValue.set(' ${'a' * 200} '),
          ),
        );
        await refuses(
          ProfilePatch(houseRulesPreference: SettingValue.set('a' * 201)),
        );
        await accepts(
          ProfilePatch(dietaryRestrictions: SettingValue.set(' ${'a' * 500} ')),
        );
        await refuses(
          ProfilePatch(dietaryRestrictions: SettingValue.set('a' * 501)),
        );
        await accepts(
          ProfilePatch(accessibilityNeeds: SettingValue.set(' ${'a' * 500} ')),
        );
        await refuses(
          ProfilePatch(accessibilityNeeds: SettingValue.set('a' * 501)),
        );
      });
    });

    group('failures', () {
      test('an enveloped 404 is not-found', () async {
        final remote = answering(
          _envelope(404, 'Not Found', 'Profile for user u_1 not found'),
          status: 404,
        );

        await expectLater(
          remote.updateOwn(const ProfilePatch(isSearchable: true)),
          throwsA(isA<UserProfileNotFoundException>()),
        );
      });

      test('an enveloped 403 is refused', () async {
        final remote = answering(
          _envelope(403, 'Forbidden', 'nope'),
          status: 403,
        );

        await expectLater(
          remote.updateOwn(const ProfilePatch(isSearchable: true)),
          throwsA(isA<UserProfileRefusedException>()),
        );
      });

      test('a 400 is permanent', () async {
        final remote = answering(
          jsonEncode({
            'statusCode': 400,
            'message': ['bio must be shorter'],
            'error': 'Bad Request',
          }),
          status: 400,
        );

        await expectLater(
          remote.updateOwn(const ProfilePatch(isSearchable: true)),
          throwsA(isA<UserProfilePermanentException>()),
        );
      });

      test('a 503 is transient', () async {
        final remote = answering(
          _envelope(503, 'Service Unavailable', 'down'),
          status: 503,
        );

        await expectLater(
          remote.updateOwn(const ProfilePatch(isSearchable: true)),
          throwsA(isA<UserProfileTransientException>()),
        );
      });
    });
  });
}
