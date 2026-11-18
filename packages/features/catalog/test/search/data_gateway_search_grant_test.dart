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
  group('DataGatewaySearchGrant', () {
    test('a signed-in session asks until refused', () {
      final grant = DataGatewaySearchGrant();

      expect(grant.mayAsk, isTrue);
      expect(grant.serverMessage, isNull);
    });

    test('a signed-out session never asks', () {
      final grant = DataGatewaySearchGrant.signedOut();

      expect(grant.mayAsk, isFalse);
      expect(grant.serverMessage, isNull);
    });

    test('refuse keeps the first message and stops asking', () {
      final grant = DataGatewaySearchGrant()
        ..refuse('first')
        ..refuse('other');

      expect(grant.mayAsk, isFalse);
      expect(grant.serverMessage, 'first');
    });

    test('a refusal with no message stays without one', () {
      final grant = DataGatewaySearchGrant()..refuse(null);

      expect(grant.mayAsk, isFalse);
      expect(grant.serverMessage, isNull);
    });
  });

  group('DataGatewaySearchGrantInstaller', () {
    test('registers a grant that may ask, with nothing to dispose', () async {
      final container = _RecordingContainer();

      await const DataGatewaySearchGrantInstaller().install(
        container,
        _Server(),
        'user-1',
      );

      final grant = container.registered.single as DataGatewaySearchGrant;
      expect(grant.mayAsk, isTrue);
      expect(container.disposers.single, isNull);
    });

    test('registers a new grant for each install', () async {
      final first = _RecordingContainer();
      final second = _RecordingContainer();
      const installer = DataGatewaySearchGrantInstaller();

      await installer.install(first, _Server(), 'user-1');
      (first.registered.single as DataGatewaySearchGrant).refuse('no');
      await installer.install(second, _Server(), 'user-1');

      expect(first.registered.single, isNot(same(second.registered.single)));
      expect(
        (second.registered.single as DataGatewaySearchGrant).mayAsk,
        isTrue,
      );
    });
  });
}
