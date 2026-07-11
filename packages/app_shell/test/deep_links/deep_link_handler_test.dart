import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// #10 red phase: `DeepLinkHandler` — the whole of #10's live pipeline:
/// receive → normalize → hold. Rejected links are dropped (and logged
/// redacted); draining the holder is #82/#83 scope.
final class _FakeDeepLinkSource implements DeepLinkSource {
  _FakeDeepLinkSource(this.uris);

  @override
  final Stream<Uri> uris;
}

void main() {
  late StreamController<Uri> controller;
  late PendingDeepLinkHolder holder;
  late DeepLinkHandler handler;

  setUp(() {
    controller = StreamController<Uri>();
    holder = PendingDeepLinkHolder();
    handler = DeepLinkHandler(
      source: _FakeDeepLinkSource(controller.stream),
      holder: holder,
    );
  });

  tearDown(() async {
    await handler.dispose();
    await controller.close();
  });

  group('DeepLinkHandler', () {
    test('holds a valid link, normalized', () async {
      handler.start();

      controller.add(Uri.parse('bge://server/s1/game/42'));
      await pumpEventQueue();

      expect(
        holder.peek,
        const NormalizedDeepLink(
          serverId: 's1',
          location: '/server/s1/game/42',
        ),
      );
    });

    test('drops an invalid link without touching the holder', () async {
      handler.start();

      controller.add(Uri.parse('https://evil.example/phish'));
      await pumpEventQueue();

      expect(holder.peek, isNull);
    });

    test('latest valid link wins', () async {
      handler.start();

      controller
        ..add(Uri.parse('bge://server/s1/game/1'))
        ..add(Uri.parse('bge://server/s2/event/9'));
      await pumpEventQueue();

      expect(
        holder.peek,
        const NormalizedDeepLink(
          serverId: 's2',
          location: '/server/s2/event/9',
        ),
      );
    });

    test(
      'a rejected link does not clear a previously held valid one',
      () async {
        handler.start();

        controller
          ..add(Uri.parse('bge://server/s1/game/1'))
          ..add(Uri.parse('bge://evil/s1/game/1'));
        await pumpEventQueue();

        expect(
          holder.peek,
          const NormalizedDeepLink(
            serverId: 's1',
            location: '/server/s1/game/1',
          ),
        );
      },
    );

    test('survives a source stream error and keeps receiving', () async {
      handler.start();

      controller.addError(StateError('transport hiccup'));
      await pumpEventQueue();
      controller.add(Uri.parse('bge://server/s1/game/7'));
      await pumpEventQueue();

      expect(
        holder.peek,
        const NormalizedDeepLink(serverId: 's1', location: '/server/s1/game/7'),
      );
    });

    test('ignores links emitted after dispose', () async {
      handler.start();
      await handler.dispose();

      controller.add(Uri.parse('bge://server/s1/game/1'));
      await pumpEventQueue();

      expect(holder.peek, isNull);
    });

    test('start twice is a programmer error', () async {
      handler.start();

      expect(handler.start, throwsStateError);
    });

    test('dispose without start is safe, and dispose is idempotent', () async {
      // Dispose before start: no subscription yet, must be a safe no-op.
      await handler.dispose();
      await handler.dispose();

      // Then start (subscribes to the shared controller, so tearDown's
      // close completes) and dispose repeatedly.
      handler.start();
      await handler.dispose();
      await handler.dispose();
    });
  });
}
