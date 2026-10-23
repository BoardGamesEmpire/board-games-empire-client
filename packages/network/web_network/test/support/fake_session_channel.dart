import 'dart:async';

import 'package:web_network/src/auth/session_channel.dart';

/// One tab's end of the cross-tab broadcast (#432): what it posted, and a way
/// to deliver what another tab posted.
///
/// Shared by the monitor suite and the registration suite, which both need a
/// channel without a browser.
class FakeSessionChannel implements SessionChannel {
  FakeSessionChannel([this.name = 'fake']);

  /// The name it was opened under.
  final String name;

  final posted = <SessionChange>[];
  final _incoming = StreamController<SessionChange>.broadcast();
  var closed = false;

  /// Delivers [change] as if another tab had posted it.
  void deliver(SessionChange change) => _incoming.add(change);

  @override
  void post(SessionChange change) => posted.add(change);

  @override
  Stream<SessionChange> get changes => _incoming.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}
