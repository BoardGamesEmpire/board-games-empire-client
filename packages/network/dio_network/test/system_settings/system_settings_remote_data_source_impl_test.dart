import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

String _envelope(int status, String error, String message) =>
    jsonEncode({'statusCode': status, 'message': message, 'error': error});

String _coded(String code) => jsonEncode({'code': code, 'message': 'x'});

Map<String, dynamic> _row({String smtpSecurity = 'StartTls'}) => {
  'id': 'row 1',
  'smtpHost': 'mail.example.test',
  'smtpPort': 587,
  'smtpSecurity': smtpSecurity,
  'smtpUser': null,
  'smtpPasswordSet': true,
  'mailFromAddress': 'bge@example.test',
  'passwordResetLinkLifetimeMinutes': 1440,
  'allowPasswordResets': true,
  'providerLinkingPolicy': 'SignedIn',
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-01T10:30:00.000Z',
};

String _settings([Map<String, dynamic>? row]) =>
    jsonEncode({'settings': row ?? _row()});

class _MockDio extends Mock implements Dio {}

/// A real Dio whose every request is answered with no status, before it
/// reaches an adapter.
Dio _statuslessDio(String body) => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<String>(requestOptions: options, data: body),
      ),
    ),
  );

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

  SystemSettingsRemoteDataSource answering(
    String body, {
    int status = 200,
    bool strict = false,
  }) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(
      BaseOptions(
        validateStatus: strict ? (s) => s != null && s < 300 : (_) => true,
      ),
    )..httpClientAdapter = adapter;
    return SystemSettingsRemoteDataSourceImpl(dio);
  }

  group('fetch', () {
    test('maps a full row, ignoring the rest of it', () async {
      final remote = answering(_settings());

      final settings = await remote.fetch();

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/system-settings');
      expect(
        settings,
        const SystemSettings(
          id: 'row 1',
          smtpHost: 'mail.example.test',
          smtpPort: 587,
          smtpSecurity: SmtpSecurity.startTls,
          smtpUser: null,
          smtpPasswordSet: true,
          mailFromAddress: 'bge@example.test',
          passwordResetLinkLifetimeMinutes: 1440,
          allowPasswordResets: true,
          providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
        ),
      );
    });

    test('maps a security the client does not know to unknown', () async {
      final remote = answering(_settings(_row(smtpSecurity: 'Ssl')));

      expect((await remote.fetch()).smtpSecurity, SmtpSecurity.unknown);
    });

    test('a missing settings object is permanent', () async {
      final remote = answering(jsonEncode({'other': 1}));

      await expectLater(
        remote.fetch(),
        throwsA(isA<SystemSettingsPermanentException>()),
      );
    });

    test('a settings field that is not an object is permanent', () async {
      final remote = answering(jsonEncode({'settings': <Object>[]}));

      await expectLater(
        remote.fetch(),
        throwsA(isA<SystemSettingsPermanentException>()),
      );
    });

    test('a non-boolean smtpPasswordSet is permanent', () async {
      final remote = answering(
        _settings({..._row(), 'smtpPasswordSet': 'yes'}),
      );

      await expectLater(
        remote.fetch(),
        throwsA(isA<SystemSettingsPermanentException>()),
      );
    });

    test('an enveloped 403 is forbidden', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'nope'),
        status: 403,
      );

      await expectLater(
        remote.fetch(),
        throwsA(isA<SystemSettingsForbiddenException>()),
      );
    });

    test('a 403 without the envelope is transient', () async {
      final remote = answering('<html>blocked</html>', status: 403);

      await expectLater(
        remote.fetch(),
        throwsA(isA<SystemSettingsTransientException>()),
      );
    });
  });

  group('update', () {
    test(
      'sends only the set fields, a clear as null, to the row path',
      () async {
        final remote = answering(_settings());

        final result = await remote.update(
          'row 1',
          const SystemSettingsPatch(
            smtpHost: SettingValue.set('h'),
            smtpUser: SettingValue.clear(),
            smtpPort: 465,
          ),
        );

        expect(result.id, 'row 1');
        expect(adapter.sent.single.method, 'PATCH');
        expect(adapter.sent.single.path, '/api/system-settings/row%201');
        expect(adapter.sent.single.data, {
          'smtpHost': 'h',
          'smtpUser': null,
          'smtpPort': 465,
        });
      },
    );

    test('sends enums by wire name and the other fields as given', () async {
      final remote = answering(_settings());

      await remote.update(
        'r',
        const SystemSettingsPatch(
          smtpSecurity: SmtpSecurity.implicitTls,
          smtpPassword: SettingValue.set(' pw '),
          mailFromAddress: SettingValue.set('a@b.test'),
          passwordResetLinkLifetimeMinutes: 15,
          allowPasswordResets: false,
          providerLinkingPolicy: ProviderLinkingPolicy.automaticWhenVerified,
        ),
      );

      expect(adapter.sent.single.data, {
        'smtpSecurity': 'ImplicitTls',
        'smtpPassword': ' pw ',
        'mailFromAddress': 'a@b.test',
        'passwordResetLinkLifetimeMinutes': 15,
        'allowPasswordResets': false,
        'providerLinkingPolicy': 'AutomaticWhenVerified',
      });
    });

    group('rejects, with nothing sent', () {
      final cases = <String, SystemSettingsPatch>{
        'an empty patch': const SystemSettingsPatch(),
        'an unknown security': const SystemSettingsPatch(
          smtpSecurity: SmtpSecurity.unknown,
        ),
        'an unknown linking policy': const SystemSettingsPatch(
          providerLinkingPolicy: ProviderLinkingPolicy.unknown,
        ),
        'port 0': const SystemSettingsPatch(smtpPort: 0),
        'port 65536': const SystemSettingsPatch(smtpPort: 65536),
        'lifetime 14': const SystemSettingsPatch(
          passwordResetLinkLifetimeMinutes: 14,
        ),
        'lifetime 10081': const SystemSettingsPatch(
          passwordResetLinkLifetimeMinutes: 10081,
        ),
        'a 256-character host': SystemSettingsPatch(
          smtpHost: SettingValue.set('a' * 256),
        ),
        'a 256-character user': SystemSettingsPatch(
          smtpUser: SettingValue.set('a' * 256),
        ),
        'a 256-character password': SystemSettingsPatch(
          smtpPassword: SettingValue.set('a' * 256),
        ),
        'a 256-character From': SystemSettingsPatch(
          mailFromAddress: SettingValue.set('a' * 256),
        ),
      };
      for (final entry in cases.entries) {
        test(entry.key, () async {
          final remote = answering(_settings());

          await expectLater(
            remote.update('r', entry.value),
            throwsA(isA<ArgumentError>()),
          );
          expect(adapter.sent, isEmpty);
        });
      }

      test('measures length the way the server does', () async {
        final remote = answering(_settings());
        // 255 emoji are 510 UTF-16 units but 255 to the server.
        final host = '\u{1F600}' * 255;
        expect(serverStringLength(host), 255);

        await remote.update(
          'r',
          SystemSettingsPatch(smtpHost: SettingValue.set(host)),
        );

        expect(adapter.sent, hasLength(1));
      });

      test('accepts the limits themselves', () async {
        final remote = answering(_settings());

        await remote.update(
          'r',
          SystemSettingsPatch(
            smtpHost: SettingValue.set('a' * 255),
            smtpPort: 65535,
            passwordResetLinkLifetimeMinutes: 10080,
          ),
        );

        expect(adapter.sent, hasLength(1));
      });
    });

    test(
      '400 SMTP_PASSWORD_REQUIRED, with no envelope, is its own failure',
      () {
        final remote = answering(_coded('SMTP_PASSWORD_REQUIRED'), status: 400);

        return expectLater(
          remote.update('r', const SystemSettingsPatch(smtpPort: 25)),
          throwsA(isA<SmtpPasswordRequiredException>()),
        );
      },
    );

    test('a validation envelope is permanent', () {
      final remote = answering(
        jsonEncode({
          'statusCode': 400,
          'message': ['x'],
          'error': 'Bad Request',
        }),
        status: 400,
      );

      return expectLater(
        remote.update('r', const SystemSettingsPatch(smtpPort: 25)),
        throwsA(isA<SystemSettingsPermanentException>()),
      );
    });

    test('an enveloped 403 is forbidden', () {
      final remote = answering(
        _envelope(403, 'Forbidden', 'nope'),
        status: 403,
      );

      return expectLater(
        remote.update('r', const SystemSettingsPatch(smtpPort: 25)),
        throwsA(isA<SystemSettingsForbiddenException>()),
      );
    });

    test('a 403 without the envelope is transient', () {
      final remote = answering('nope', status: 403);

      return expectLater(
        remote.update('r', const SystemSettingsPatch(smtpPort: 25)),
        throwsA(isA<SystemSettingsTransientException>()),
      );
    });
  });

  group('sendMailTest', () {
    test('a 202 completes, posting to the mail-test route', () async {
      final remote = answering(jsonEncode({'queued': true}), status: 202);

      await remote.sendMailTest();

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/system-settings/mail-test');
    });

    test('a 202 with no readable body still completes', () async {
      final remote = answering('', status: 202);

      await remote.sendMailTest();
    });

    test('a response with no status is transient', () {
      final remote = SystemSettingsRemoteDataSourceImpl(_statuslessDio(''));

      return expectLater(
        remote.sendMailTest(),
        throwsA(isA<SystemSettingsTransientException>()),
      );
    });

    test("a failure that is not Dio's is transient", () {
      final dio = _MockDio();
      when(
        () => dio.post<String>(any(), options: any(named: 'options')),
      ).thenThrow(StateError('boom'));

      return expectLater(
        SystemSettingsRemoteDataSourceImpl(dio).sendMailTest(),
        throwsA(isA<SystemSettingsTransientException>()),
      );
    });

    test('409 MAIL_NOT_CONFIGURED is its own failure', () {
      final remote = answering(_coded('MAIL_NOT_CONFIGURED'), status: 409);

      return expectLater(
        remote.sendMailTest(),
        throwsA(isA<MailNotConfiguredException>()),
      );
    });

    for (final strict in [false, true]) {
      test(
        '503 MAIL_QUEUE_UNAVAILABLE is its own failure, '
        '${strict ? 'thrown' : 'returned'}',
        () {
          final remote = answering(
            _coded('MAIL_QUEUE_UNAVAILABLE'),
            status: 503,
            strict: strict,
          );

          return expectLater(
            remote.sendMailTest(),
            throwsA(
              isA<MailQueueUnavailableException>().having(
                (e) => e.statusCode,
                'statusCode',
                503,
              ),
            ),
          );
        },
      );
    }

    test('a 503 without the code is transient', () {
      final remote = answering('<html>down</html>', status: 503);

      return expectLater(
        remote.sendMailTest(),
        throwsA(isA<SystemSettingsTransientException>()),
      );
    });

    test('a 409 with another code is permanent', () {
      final remote = answering(_coded('SOMETHING_ELSE'), status: 409);

      return expectLater(
        remote.sendMailTest(),
        throwsA(isA<SystemSettingsPermanentException>()),
      );
    });

    test('an enveloped 403 is forbidden, thrown or returned', () async {
      for (final strict in [false, true]) {
        final remote = answering(
          _envelope(403, 'Forbidden', 'nope'),
          status: 403,
          strict: strict,
        );

        await expectLater(
          remote.sendMailTest(),
          throwsA(isA<SystemSettingsForbiddenException>()),
        );
      }
    });
  });
}
