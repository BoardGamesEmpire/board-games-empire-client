@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:web_platform/web_storage_composition.dart';

@JS('Object.defineProperty')
external void _defineProperty(
  JSObject target,
  JSString name,
  JSObject descriptor,
);

@JS('Reflect.deleteProperty')
external bool _deleteProperty(JSObject target, JSString name);

/// The page-attention stream behind the session monitor's re-reads (#432).
///
/// The monitor reads the cookie for every event, so one return to the page
/// must be one event though the browser usually fires both visibilitychange
/// and focus for it. The events are dispatched by hand: the runner cannot
/// switch tabs. A hidden page is staged by shadowing `visibilityState` on
/// the document, which the browser's own getter sits behind.
void main() {
  late List<void> heard;
  late StreamSubscription<void> subscription;

  setUp(() {
    heard = [];
    subscription = pageAttention().listen(heard.add);
  });

  tearDown(() async {
    await subscription.cancel();
    _deleteProperty(web.document, 'visibilityState'.toJS);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void blur() => web.window.dispatchEvent(web.Event('blur'));
  void focus() => web.window.dispatchEvent(web.Event('focus'));
  void turn(String visibility) {
    _defineProperty(
      web.document,
      'visibilityState'.toJS,
      {'value': visibility, 'configurable': true}.jsify()! as JSObject,
    );
    web.document.dispatchEvent(web.Event('visibilitychange'));
  }

  test('switching back to the tab fires once, though the page turns visible '
      'and gains focus', () async {
    turn('hidden');
    blur();

    turn('visible');
    focus();
    await settle();

    expect(heard, hasLength(1));
  });

  test('focus returning to a window that stayed visible fires', () async {
    blur();

    focus();
    await settle();

    expect(heard, hasLength(1));
  });

  test('nothing more fires until the page has left again', () async {
    blur();
    focus();
    await settle();

    focus();
    turn('visible');
    await settle();

    expect(heard, hasLength(1));
  });

  test('every return fires', () async {
    blur();
    focus();
    turn('hidden');
    turn('visible');
    blur();
    focus();
    await settle();

    expect(heard, hasLength(3));
  });

  test('hears nothing once its last listener has cancelled', () async {
    await subscription.cancel();
    final again = <void>[];
    final probe = pageAttention().listen(again.add);
    await probe.cancel();

    blur();
    focus();
    await settle();

    expect(heard, isEmpty);
    expect(again, isEmpty);
  });
}
