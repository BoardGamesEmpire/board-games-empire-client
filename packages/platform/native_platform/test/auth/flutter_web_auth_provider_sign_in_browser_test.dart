import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:interfaces/repositories.dart';
import 'package:native_platform/native_platform.dart';

void main() {
  final url = Uri.parse('https://example.com/api/auth/app/start?state=s');

  group('FlutterWebAuthProviderSignInBrowser', () {
    test('returns the URL the tab came back with', () async {
      final browser = FlutterWebAuthProviderSignInBrowser(
        authenticate: ({
          required url,
          required callbackUrlScheme,
          required options,
        }) async => 'bge://oauth?code=c&state=s',
        isSupported: true,
      );

      final result = await browser.authenticate(
        url: url,
        callbackScheme: 'bge',
      );

      expect(result, Uri.parse('bge://oauth?code=c&state=s'));
    });

    test('maps CANCELED to null', () async {
      final browser = FlutterWebAuthProviderSignInBrowser(
        authenticate: ({
          required url,
          required callbackUrlScheme,
          required options,
        }) => throw PlatformException(code: 'CANCELED'),
        isSupported: true,
      );

      expect(
        await browser.authenticate(url: url, callbackScheme: 'bge'),
        isNull,
      );
    });

    test('maps another PlatformException to '
        'AuthProviderSignInException(generic)', () async {
      final cause = PlatformException(code: 'NO_BROWSER');
      final browser = FlutterWebAuthProviderSignInBrowser(
        authenticate: ({
          required url,
          required callbackUrlScheme,
          required options,
        }) => throw cause,
        isSupported: true,
      );

      await expectLater(
        browser.authenticate(url: url, callbackScheme: 'bge'),
        throwsA(
          isA<AuthProviderSignInException>()
              .having(
                (e) => e.reason,
                'reason',
                ProviderSignInFailureReason.generic,
              )
              .having((e) => e.cause, 'cause', same(cause)),
        ),
      );
    });

    test(
      'asks for a non-ephemeral session under the scheme it is given',
      () async {
        String? sentUrl;
        String? sentScheme;
        FlutterWebAuth2Options? sentOptions;
        final browser = FlutterWebAuthProviderSignInBrowser(
          authenticate:
              ({
                required url,
                required callbackUrlScheme,
                required options,
              }) async {
                sentUrl = url;
                sentScheme = callbackUrlScheme;
                sentOptions = options;
                return 'bge://oauth?code=c';
              },
          isSupported: true,
        );

        await browser.authenticate(url: url, callbackScheme: 'bge');

        expect(sentUrl, url.toString());
        expect(sentScheme, 'bge');
        expect(sentOptions!.preferEphemeral, isFalse);
      },
    );

    test('reports unsupported on Windows and Linux', () {
      expect(
        FlutterWebAuthProviderSignInBrowser(isSupported: false).isSupported,
        isFalse,
      );
      expect(
        FlutterWebAuthProviderSignInBrowser(isSupported: true).isSupported,
        isTrue,
      );
    });
  });
}
