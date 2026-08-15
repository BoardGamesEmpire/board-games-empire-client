import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

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

    test('a rejected credential-bearing link is logged redacted', () async {
      // #178: rejection is logged at warn *with* the rendered link, so the
      // reject path is the leak path. Asserted here, not just on the
      // renderer, because this is what actually reaches the breadcrumbs.
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final messages = <String>[];
      final subscription = Logger.root.onRecord.listen(
        (record) => messages.add(record.message),
      );
      addTearDown(() async {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      });

      handler.start();

      controller
        ..add(Uri.parse('bge://alice:hunter2@server/s1/game/5'))
        ..add(Uri.parse('bge:alice:hunter2@server/s1/game/5'))
        ..add(Uri.parse('bge:alice:hunter2%40server/s1/game/5'))
        ..add(Uri.parse('bge:alice:hunter2%40server%0Aforged/s1/game/5'))
        ..add(Uri.parse('bge:///alice:hunter2@server/s1/game/5'));
      await pumpEventQueue();

      expect(messages, hasLength(5));
      expect(
        messages.every((message) => message.startsWith('Deep link rejected')),
        isTrue,
      );
      expect(messages.join('\n'), isNot(contains('hunter2')));
      // One breadcrumb per link: no rendered link may span log lines.
      expect(messages.every((message) => !message.contains('\n')), isTrue);
    });

    test('an ACCEPTED credential-shaped link is logged redacted', () async {
      // `alice:hunter2@evil` is a valid serverId as far as the normalizer
      // cares, so this link is held and logged at info — the accept path,
      // where "the reject path echoes the attacker's own text" offers no
      // comfort at all.
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final messages = <String>[];
      final subscription = Logger.root.onRecord.listen(
        (record) => messages.add(record.message),
      );
      addTearDown(() async {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      });

      handler.start();

      controller.add(Uri.parse('bge://server/alice:hunter2@evil/game/5'));
      await pumpEventQueue();

      expect(messages, hasLength(1));
      expect(messages.single, startsWith('Deep link received and held'));
      expect(messages.single, isNot(contains('hunter2')));
    });

    test(
      'a link with an undecodable escape is still logged, not dropped',
      () async {
        // `Uri.decodeComponent('%FF')` throws, and a throw out of `onData`
        // bypasses `onError` — so this used to leave the zone with an
        // uncaught error and no breadcrumb for the rejected link at all.
        // An uncaught zone error fails the test on its own; the assertions
        // below pin that the rejection was actually logged.
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final messages = <String>[];
        final subscription = Logger.root.onRecord.listen(
          (record) => messages.add(record.message),
        );
        addTearDown(() async {
          await subscription.cancel();
          Logger.root.level = previousLevel;
        });

        handler.start();

        // `evil` alone is rejected on the authority check, well before
        // anything decodes. `server` is the case that matters: it passes
        // every check and reaches the normalizer's own decode of the
        // serverId, which is the last thing standing between a hostile
        // link and an uncaught error.
        controller
          ..add(Uri.parse('bge://evil/%FF/game/5'))
          ..add(Uri.parse('bge://server/%FF/game/5'));
        await pumpEventQueue();

        expect(messages, hasLength(2));
        expect(
          messages.every((message) => message.startsWith('Deep link rejected')),
          isTrue,
        );
      },
    );

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
