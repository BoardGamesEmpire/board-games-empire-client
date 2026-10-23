@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:web_network/web_network.dart' show SessionChange;
import 'package:web_platform/web_storage_composition.dart';

/// The browser transport behind the session monitor (#432).
///
/// One page, two channels. The test runner cannot open a second tab, and a
/// second `BroadcastChannel` of the same name in the same page receives what
/// the first posts — measured before this was written, not assumed. A test
/// across two real tabs is #482.
void main() {
  var counter = 0;

  /// A name no other test in the run shares, so one test's messages cannot
  /// reach another's channels.
  String freshName() =>
      'bge.session.test.${DateTime.now().microsecondsSinceEpoch}.${counter++}';

  /// Lets the browser deliver whatever has been posted.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('a change posted on one channel reaches another of the same name, '
      'and not the one that posted it', () async {
    final name = freshName();
    final sender = BroadcastSessionChannel(name);
    final receiver = BroadcastSessionChannel(name);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final heardBySender = <SessionChange>[];
    final heardByReceiver = <SessionChange>[];
    sender.changes.listen(heardBySender.add);
    receiver.changes.listen(heardByReceiver.add);

    sender
      ..post(SessionChange.signedOut)
      ..post(SessionChange.signedIn);
    await settle();

    expect(heardByReceiver, [SessionChange.signedOut, SessionChange.signedIn]);
    expect(heardBySender, isEmpty);
  });

  test('a message it cannot read is dropped', () async {
    final name = freshName();
    final receiver = BroadcastSessionChannel(name);
    final raw = web.BroadcastChannel(name);
    addTearDown(receiver.close);
    addTearDown(() => raw.close());
    final heard = <SessionChange>[];
    final errors = <Object>[];
    receiver.changes.listen(heard.add, onError: errors.add);

    raw
      ..postMessage('signedSideways'.toJS)
      ..postMessage(42.toJS)
      ..postMessage('signedIn'.toJS);
    await settle();

    expect(heard, [SessionChange.signedIn]);
    expect(errors, isEmpty);
  });

  test(
    'a closed channel hears nothing more, and posting on it is a no-op',
    () async {
      final name = freshName();
      final sender = BroadcastSessionChannel(name);
      final receiver = BroadcastSessionChannel(name);
      addTearDown(sender.close);
      final heard = <SessionChange>[];
      receiver.changes.listen(heard.add);

      await receiver.close();
      sender.post(SessionChange.signedOut);
      receiver.post(SessionChange.signedOut);
      await settle();

      expect(heard, isEmpty);
    },
  );
}
