import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

/// A container that records what is registered, and nothing else. The
/// catalog may not depend on `di`, so the real one is not here.
class _RecordingContainer extends Fake implements DependencyContainer {
  final registered = <Object>[];
  final disposers = <Object?>[];

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) {
    registered.add(instance);
    disposers.add(dispose);
  }
}

class _Server extends Fake implements ScopedServer {}

void main() {
  group('DataGatewaySearchReach', () {
    test('a signed-in session asks until refused', () {
      final reach = DataGatewaySearchReach();

      expect(reach.mayAsk, isTrue);
      expect(reach.serverMessage, isNull);
    });

    test('a signed-out session never asks', () {
      final reach = DataGatewaySearchReach.signedOut();

      expect(reach.mayAsk, isFalse);
      expect(reach.serverMessage, isNull);
    });

    test('refuse keeps the first message and stops asking', () {
      final reach = DataGatewaySearchReach()
        ..refuse('first')
        ..refuse('other');

      expect(reach.mayAsk, isFalse);
      expect(reach.serverMessage, 'first');
    });

    test('a refusal with no message stays without one', () {
      final reach = DataGatewaySearchReach()..refuse(null);

      expect(reach.mayAsk, isFalse);
      expect(reach.serverMessage, isNull);
    });
  });

  group('DataGatewaySearchReachInstaller', () {
    test('registers a reach that may ask, with nothing to dispose', () async {
      final container = _RecordingContainer();

      await const DataGatewaySearchReachInstaller().install(
        container,
        _Server(),
        'user-1',
      );

      final reach = container.registered.single as DataGatewaySearchReach;
      expect(reach.mayAsk, isTrue);
      expect(container.disposers.single, isNull);
    });

    test('registers a new reach for each install', () async {
      final first = _RecordingContainer();
      final second = _RecordingContainer();
      const installer = DataGatewaySearchReachInstaller();

      await installer.install(first, _Server(), 'user-1');
      (first.registered.single as DataGatewaySearchReach).refuse('no');
      await installer.install(second, _Server(), 'user-1');

      expect(first.registered.single, isNot(same(second.registered.single)));
      expect(
        (second.registered.single as DataGatewaySearchReach).mayAsk,
        isTrue,
      );
    });
  });
}
