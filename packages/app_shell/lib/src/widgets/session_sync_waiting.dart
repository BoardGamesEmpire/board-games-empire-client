import 'dart:async';

import 'package:flutter/foundation.dart';

/// How many of the session's changes are waiting to go out, carried up to
/// the offline strip (#47).
///
/// The strip sits above the Navigator, where no session's services are in
/// reach, and the session's sync status is read below it, by a
/// `SyncStatusScopeHost` around the navigation shell. That host reports here,
/// and the strip listens. Null is no count: no session, or one that has
/// reported nothing yet.
///
/// Each report names its owner, the host that made it, because more than one
/// host can be mounted for a moment, as when a session ends or is replaced.
/// A host that leaves takes its count with it, and only its own: once
/// another host has reported, the one that went can no longer clear it.
///
/// [report] notifies at once. A host reports only as its queue's stream
/// delivers, never while the tree builds. [release] clears at once, but
/// notifies a microtask later: a host releases from its `dispose`, which
/// runs while the tree is locked, and a listener that rebuilt then would
/// throw.
class SessionSyncWaiting extends ChangeNotifier
    implements ValueListenable<int?> {
  int? _value;

  /// The host whose count [value] is, or null for none.
  Object? _owner;

  bool _disposed = false;

  @override
  int? get value => _value;

  /// Sets the count to [owner]'s [waiting], and makes [owner] the one whose
  /// count it is.
  void report(Object owner, int waiting) {
    _owner = owner;
    if (_value == waiting) return;
    _value = waiting;
    notifyListeners();
  }

  /// Clears the count, if it is [owner]'s.
  ///
  /// The listeners hear of it a microtask later, unless a report has come
  /// in by then: that report notified already, and its count stands.
  void release(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    if (_value == null) return;
    _value = null;
    scheduleMicrotask(() {
      // Disposed meanwhile: the app went, after the hosts below it.
      if (_disposed || _owner != null) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
