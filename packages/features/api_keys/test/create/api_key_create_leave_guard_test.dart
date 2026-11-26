import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiKeyCreateLeaveGuard', () {
    test('with no page attached it says yes at once', () {
      // At once: a bool, not a future, so the route's holder moves on in the
      // same turn.
      expect(ApiKeyCreateLeaveGuard().mayLeave(), isTrue);
    });

    test('it answers what the attached page answers', () async {
      final guard = ApiKeyCreateLeaveGuard();
      var answer = false;
      var asked = 0;
      guard.attach(() {
        asked++;
        return answer;
      });

      expect(guard.mayLeave(), isFalse);
      answer = true;
      expect(guard.mayLeave(), isTrue);
      expect(asked, 2);
    });

    test("it waits on a page's answer that is yet to come", () async {
      final guard = ApiKeyCreateLeaveGuard();
      final answer = Completer<bool>();
      guard.attach(() => answer.future);

      final asked = guard.mayLeave();
      expect(asked, isA<Future<bool>>());
      answer.complete(false);

      expect(await asked, isFalse);
    });

    test('a page that detaches is asked no more', () {
      final guard = ApiKeyCreateLeaveGuard();
      final detach = guard.attach(() => false);
      expect(guard.mayLeave(), isFalse);

      detach();

      expect(guard.mayLeave(), isTrue);
    });

    test("a page that has been replaced can't detach the one that took its "
        'place', () {
      final guard = ApiKeyCreateLeaveGuard();
      // The new page mounts before the old one has gone.
      final detachOld = guard.attach(() => true);
      final detachNew = guard.attach(() => false);

      detachOld();
      expect(guard.mayLeave(), isFalse);

      detachNew();
      expect(guard.mayLeave(), isTrue);
    });
  });
}
