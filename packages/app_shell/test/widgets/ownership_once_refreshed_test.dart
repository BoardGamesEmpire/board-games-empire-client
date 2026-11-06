import 'dart:async';

import 'package:app_shell/src/widgets/ownership_once_refreshed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:models/domain.dart';

/// The detail page's ownership waits for the collection's first refresh
/// (#708): an empty cache while it runs is unknown, not "not owned".
void main() {
  late StreamController<List<GameCollection>> entries;
  late GameCollectionHydrationStatus status;
  late List<Object> events;
  late StreamSubscription<List<GameCollection>> subscription;

  final copy = GameCollection(
    id: 'gc_1',
    userId: 'u1',
    platformGameId: 'pg_1',
    medium: GameMedium.physical,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  setUp(() {
    entries = StreamController<List<GameCollection>>();
    status = GameCollectionHydrationStatus();
    events = [];
  });

  tearDown(() async {
    await subscription.cancel();
    await status.close();
  });

  /// Listens to the composed stream over [hydration], or [status]'s.
  void listen([Stream<Hydration>? hydration]) {
    subscription = ownershipOnceRefreshed(
      entries.stream,
      hydration ?? status.watch(),
    ).listen(events.add, onError: (Object error) => events.add(error));
  }

  test('while the first pass runs, the empty cache is held back, and the '
      'latest answer goes once the pass lands rows', () async {
    status.started();
    listen();
    entries
      ..add(const [])
      ..add([copy]);
    await pumpEventQueue();
    expect(events, isEmpty);

    status.finished(CollectionHydrateOutcome.complete);
    await pumpEventQueue();
    expect(events, [
      [copy],
    ]);

    // From then on, every answer goes through, a later pass's too.
    status.started();
    entries.add(const []);
    await pumpEventQueue();
    expect(events.last, isEmpty);
  });

  test('a status no pass has touched holds nothing back', () async {
    listen();
    entries.add([copy]);
    await pumpEventQueue();
    expect(events, [
      [copy],
    ]);
  });

  test('a status that has not spoken yet holds the answer back', () async {
    final hydration = StreamController<Hydration>();
    addTearDown(hydration.close);
    listen(hydration.stream);
    entries.add([copy]);
    await pumpEventQueue();
    expect(events, isEmpty);

    hydration.add(
      const Hydration(state: HydrationState.refreshed, everRefreshed: true),
    );
    await pumpEventQueue();
    expect(events, [
      [copy],
    ]);
  });

  test('a failed first pass is ownership unknown, and a pass that lands rows '
      'then releases the answer', () async {
    status.started();
    listen();
    entries.add(const []);
    await pumpEventQueue();

    status.finished(CollectionHydrateOutcome.failed);
    await pumpEventQueue();
    expect(events.single, isA<CollectionNotRefreshedException>());

    // A local write while unknown is held back with the rest.
    entries.add([copy]);
    status.started();
    await pumpEventQueue();
    expect(events, hasLength(1));

    status.finished(CollectionHydrateOutcome.complete);
    await pumpEventQueue();
    expect(events.last, [copy]);
  });

  test('a failed first pass already over when the page listens is unknown at '
      'once', () async {
    status
      ..started()
      ..finished(CollectionHydrateOutcome.failed);
    listen();
    await pumpEventQueue();
    expect(events.single, isA<CollectionNotRefreshedException>());
  });

  test('each failed pass before any landed rows says so once', () async {
    status
      ..started()
      ..finished(CollectionHydrateOutcome.failed);
    listen();
    await pumpEventQueue();
    status
      ..started()
      ..finished(CollectionHydrateOutcome.failed);
    await pumpEventQueue();
    expect(events, [
      isA<CollectionNotRefreshedException>(),
      isA<CollectionNotRefreshedException>(),
    ]);
  });

  test('a failed pass after one landed rows holds nothing back', () async {
    status
      ..started()
      ..finished(CollectionHydrateOutcome.complete)
      ..started()
      ..finished(CollectionHydrateOutcome.failed);
    listen();
    entries.add([copy]);
    await pumpEventQueue();
    expect(events, [
      [copy],
    ]);
  });

  test('a status stream that ends releases the answer', () async {
    status.started();
    listen();
    entries.add([copy]);
    await pumpEventQueue();
    expect(events, isEmpty);

    await status.close();
    await pumpEventQueue();
    expect(events, [
      [copy],
    ]);
  });

  test("the cache's errors go through, and its end ends the stream", () async {
    status.started();
    var done = false;
    subscription = ownershipOnceRefreshed(entries.stream, status.watch())
        .listen(
          events.add,
          onError: (Object error) => events.add(error),
          onDone: () => done = true,
        );
    entries.addError(StateError('the cache is gone'));
    await entries.close();
    await pumpEventQueue();
    expect(events.single, isA<StateError>());
    expect(done, isTrue);
  });

  test('cancelling stops listening to both', () async {
    final hydration = StreamController<Hydration>();
    addTearDown(hydration.close);
    listen(hydration.stream);
    await pumpEventQueue();
    expect(entries.hasListener, isTrue);
    expect(hydration.hasListener, isTrue);

    await subscription.cancel();
    expect(entries.hasListener, isFalse);
    expect(hydration.hasListener, isFalse);
  });
}
