@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:web_network/web_network.dart'
    show
        WebProviderSignInBindings,
        providerSignInMarkerKey,
        providerSignInReturnKey;
import 'package:web_platform/web_storage_composition.dart';

/// What a page load brings back from a sign-in provider, read once at
/// startup (#583).
///
/// The return is staged on the test page's own address with
/// `history.replaceState`, which changes the address without navigating, and
/// put back afterwards. The page-show listener is injected: the runner's page
/// is never restored from the back-forward cache. Nothing here navigates or
/// reloads, so the bindings' page navigator is not called either.
void main() {
  late String original;

  setUp(() {
    original = web.window.location.href;
    web.window.sessionStorage.removeItem(providerSignInMarkerKey);
  });

  tearDown(() {
    web.window.sessionStorage.removeItem(providerSignInMarkerKey);
    web.window.history.replaceState(null, '', original);
  });

  String? marker() =>
      web.window.sessionStorage.getItem(providerSignInMarkerKey);

  const returnId = 'r3TurN-id_1';

  void leftForProvider() =>
      web.window.sessionStorage.setItem(providerSignInMarkerKey, returnId);

  /// The test page's address with [query] added, as the server would send
  /// the user back to it. The server's redirect carries the attempt's
  /// [returnId] under [providerSignInReturnKey].
  void cameBackWith(Map<String, String> query) {
    final here = Uri.parse(web.window.location.href);
    web.window.history.replaceState(
      null,
      '',
      here
          .replace(queryParameters: {...here.queryParameters, ...query})
          .toString(),
    );
  }

  /// A capture with no real page-show listener and no real reload.
  WebProviderSignInBindings capture() => captureWebProviderSignIn(
    listenForPageShow: (_) {},
    reload: () => fail('nothing here reloads the page'),
  );

  group('a page load', () {
    test('with the marker, reads a failed return, consumes the marker, and '
        'takes error and error_description out of the address', () {
      leftForProvider();
      final before = Uri.parse(original);
      cameBackWith({
        providerSignInReturnKey: returnId,
        'error': 'access_denied',
        'error_description': 'No.',
      });

      final captured = capture();

      expect(captured.startupReturn?.errorCode, 'access_denied');
      expect(marker(), isNull);
      final after = Uri.parse(web.window.location.href);
      expect(after.path, before.path);
      expect(after.queryParameters, before.queryParameters);
    });

    test('with the marker and its return id, reads a success and takes the '
        'id out of the address', () {
      leftForProvider();
      cameBackWith({providerSignInReturnKey: returnId});

      final captured = capture();

      expect(captured.startupReturn, isNotNull);
      expect(captured.startupReturn!.errorCode, isNull);
      expect(marker(), isNull);
      expect(web.window.location.href, original);
    });

    // Back from the provider page, a reload of the page that left, or the
    // app's address typed or followed from a bookmark in the same tab after
    // giving up on the provider: the marker is still set, but no load but
    // the return carries its id.
    test('with the marker but no return id in the address, reads no return '
        'and leaves the address alone', () {
      leftForProvider();
      cameBackWith({'error': 'access_denied'});
      final staged = web.window.location.href;

      final captured = capture();

      expect(captured.startupReturn, isNull);
      expect(marker(), isNull);
      expect(web.window.location.href, staged);
    });

    test("with another attempt's return id, reads no return", () {
      leftForProvider();
      cameBackWith({providerSignInReturnKey: 'other'});

      final captured = capture();

      expect(captured.startupReturn, isNull);
      expect(marker(), isNull);
      expect(
        Uri.parse(web.window.location.href).queryParameters,
        isNot(contains(providerSignInReturnKey)),
      );
    });

    test('without the marker, ignores ?error= and leaves it in the '
        'address', () {
      cameBackWith({'error': 'access_denied'});
      final staged = web.window.location.href;

      final captured = capture();

      expect(captured.startupReturn, isNull);
      expect(web.window.location.href, staged);
    });

    // A reload captures again, and must not read the same return twice.
    test('a second capture reads no return: the first consumed the '
        'marker', () {
      leftForProvider();
      cameBackWith({
        providerSignInReturnKey: returnId,
        'error': 'access_denied',
      });

      capture();

      expect(capture().startupReturn, isNull);
    });
  });

  // A page the back-forward cache restores runs no `main()`, so nothing
  // captures again: it would sit on the provider attempt it left from, with
  // the marker still set for its next load.
  group('a page shown again', () {
    late void Function(bool persisted) pageShown;
    late int reloads;

    setUp(() {
      reloads = 0;
      captureWebProviderSignIn(
        listenForPageShow: (listener) => pageShown = listener,
        reload: () => reloads += 1,
      );
    });

    test('from the back-forward cache after leaving for a provider is '
        'reloaded once, with the marker gone', () {
      leftForProvider();

      pageShown(true);

      expect(marker(), isNull);
      expect(reloads, 1);
    });

    test('from the back-forward cache without the marker is left as it '
        'is', () {
      pageShown(true);

      expect(reloads, 0);
    });

    test('by a load of its own is left as it is', () {
      leftForProvider();

      pageShown(false);

      expect(reloads, 0);
      expect(marker(), returnId);
    });
  });

  test('bgeWebPlatformBootstrap captures as it is built, before anything '
      'else can read the address', () {
    leftForProvider();

    bgeWebPlatformBootstrap();

    expect(marker(), isNull);
  });
}
