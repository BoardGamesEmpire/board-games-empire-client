import 'dart:async';

import 'package:interfaces/services.dart';

/// A [ConnectivityService] a test drives by hand. Like the real one, [watch]
/// replays [current] to each new subscriber before any change.
class FakeConnectivity implements ConnectivityService {
  FakeConnectivity([this.current = ConnectivityState.online]);

  @override
  ConnectivityState current;

  final _changes = StreamController<ConnectivityState>.broadcast();

  @override
  Stream<ConnectivityState> watch() async* {
    yield current;
    yield* _changes.stream;
  }

  /// Moves to [next] and tells every subscriber.
  void change(ConnectivityState next) {
    current = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}
