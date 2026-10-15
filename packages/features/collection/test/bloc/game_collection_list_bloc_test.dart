import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/list_items.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

void main() {
  late _MockGameCollectionRepository repository;
  late StreamController<List<GameCollectionListItem>> items;
  late GameCollectionHydrationStatus status;

  setUp(() {
    repository = _MockGameCollectionRepository();
    items = StreamController<List<GameCollectionListItem>>();
    status = GameCollectionHydrationStatus();
    when(repository.watchCollectionListItems).thenAnswer((_) => items.stream);
  });

  tearDown(() {
    // Not awaited: closing a single-subscription controller completes when
    // its done event is delivered, so a test whose bloc never listened to
    // `items` would hang here.
    unawaited(items.close());
    unawaited(status.close());
  });

  GameCollectionListBloc build({
    bool withHydration = true,
    Future<void> Function()? onRetry,
  }) => GameCollectionListBloc(
    repository: repository,
    hydration: withHydration ? status.watch() : null,
    onRetry: onRetry,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('starts loading, before the cache has said anything', () {
    final bloc = build();
    addTearDown(bloc.close);

    expect(bloc.state, isA<GameCollectionListLoading>());
  });

  test('shows rows as soon as the cache has them', () async {
    final bloc = build();
    addTearDown(bloc.close);

    status.started();
    items.add([listItem('e-1')]);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<GameCollectionListReady>()
            .having((s) => s.items, 'items', hasLength(1))
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      ),
    );
  });

  test('an empty cache mid-hydrate is loading, not empty', () async {
    // The first sign-in case: the cache is empty because the hydrate has
    // not filled it yet, and the stream cannot say so.
    final bloc = build();
    addTearDown(bloc.close);

    status.started();
    items.add(const []);
    await settle();

    expect(bloc.state, isA<GameCollectionListLoading>());
  });

  test('an empty cache is empty once the hydrate settles', () async {
    final bloc = build();
    addTearDown(bloc.close);

    status.started();
    items.add(const []);
    await settle();
    status.finished(CollectionHydrateOutcome.complete);

    await expectLater(
      bloc.stream,
      emits(
        isA<GameCollectionListReady>().having((s) => s.items, 'items', isEmpty),
      ),
    );
  });

  test('an empty cache with no hydrate at all is empty, not loading', () async {
    // An absent status reads as idle. A spinner there would never resolve.
    final bloc = build(withHydration: false);
    addTearDown(bloc.close);

    items.add(const []);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<GameCollectionListReady>().having((s) => s.items, 'items', isEmpty),
      ),
    );
  });

  test('a failed hydrate marks the rows as possibly stale', () async {
    final bloc = build();
    addTearDown(bloc.close);

    items.add([listItem('e-1')]);
    await settle();
    status.finished(CollectionHydrateOutcome.failed);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<GameCollectionListReady>().having(
          (s) => s.refreshFailed,
          'refreshFailed',
          isTrue,
        ),
      ),
    );
  });

  group('when the cache read fails', () {
    test('surfaces an error state', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.addError(StateError('no authenticated user'));

      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListError>()),
      );
    });

    test('the next rows recover the screen', () async {
      // Drift keeps a stream open after a failed query, so real rows can
      // follow an error on the same subscription.
      final bloc = build();
      addTearDown(bloc.close);

      items.addError(StateError('transient read failure'));
      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListError>()),
      );

      items.add([listItem('e-1')]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<GameCollectionListReady>().having(
            (s) => s.items,
            'items',
            hasLength(1),
          ),
        ),
      );
    });

    test('a hydrate result does not lift the error', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.addError(StateError('no authenticated user'));
      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListError>()),
      );

      status.finished(CollectionHydrateOutcome.complete);
      await settle();

      expect(bloc.state, isA<GameCollectionListError>());
    });
  });

  group('when the session scope tears down', () {
    // Teardown closes the stream rather than erroring it.

    test('a cache that ends before saying anything is an error', () async {
      final bloc = build();
      addTearDown(bloc.close);

      await items.close();

      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListError>()),
      );
    });

    test('a hydrate result does not lift an ended cache\'s error', () async {
      // Nothing will answer on a closed stream, so a pass completing later
      // must not put the spinner back.
      final bloc = build();
      addTearDown(bloc.close);

      await items.close();
      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListError>()),
      );

      status.finished(CollectionHydrateOutcome.complete);
      await settle();

      expect(bloc.state, isA<GameCollectionListError>());
    });

    test('a cache that ends after emitting leaves the rows up', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.add([listItem('e-1')]);
      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListReady>()),
      );

      await items.close();
      await settle();

      expect(bloc.state, isA<GameCollectionListReady>());
    });
  });

  test('closing stops listening to both sources', () async {
    final bloc = build();
    await bloc.close();

    items.add([listItem('e-1')]);
    status.finished(CollectionHydrateOutcome.complete);
    await settle();

    expect(bloc.state, isA<GameCollectionListLoading>());
  });

  group('a re-check of a confirmed answer', () {
    // Entering the list runs a stale re-hydrate (#44), so a pass over a
    // list that is already known is routine.

    test('a confirmed-empty list stays empty under the next pass', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.add(const []);
      status.finished(CollectionHydrateOutcome.complete);
      await settle();

      status.started();
      await settle();

      expect(
        bloc.state,
        isA<GameCollectionListReady>()
            .having((s) => s.items, 'items', isEmpty)
            .having((s) => s.refreshing, 'refreshing', isFalse),
      );
    });

    test('an empty list only a failure has seen is still unknown', () async {
      // A failure confirms nothing, so a pass over that emptiness is still
      // the first fill.
      final bloc = build();
      addTearDown(bloc.close);

      items.add(const []);
      status.finished(CollectionHydrateOutcome.failed);
      await settle();

      status.started();
      await settle();

      expect(bloc.state, isA<GameCollectionListLoading>());
    });
  });

  group('a list opened while a pass is running', () {
    // Entry, resume, reconnect and the sign-in drain all start passes, so
    // the list often subscribes mid-pass and is replayed only `running`.

    test('knows an earlier pass confirmed the empty list', () async {
      status
        ..started()
        ..finished(CollectionHydrateOutcome.complete)
        ..started();
      final bloc = build();
      addTearDown(bloc.close);

      items.add(const []);
      await settle();

      expect(
        bloc.state,
        isA<GameCollectionListReady>().having((s) => s.items, 'items', isEmpty),
      );
    });

    test('knows an earlier pass failed', () async {
      status
        ..started()
        ..finished(CollectionHydrateOutcome.failed)
        ..started();
      final bloc = build();
      addTearDown(bloc.close);

      items.add([listItem('e-1')]);
      await settle();

      expect(
        bloc.state,
        isA<GameCollectionListReady>().having(
          (s) => s.refreshFailed,
          'refreshFailed',
          isTrue,
        ),
      );
    });
  });

  group('a retry the user asked for', () {
    late Completer<void> pass;
    late int calls;

    setUp(() {
      pass = Completer<void>();
      calls = 0;
    });

    GameCollectionListBloc buildWithRetry() => build(
      onRetry: () {
        calls++;
        return pass.future;
      },
    );

    Future<void> settleOnAFailedRefresh() async {
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await settle();
    }

    test('runs the pass and says a refresh is happening', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const GameCollectionListRetryRequested());
      status.started();
      await settle();

      expect(calls, 1);
      // Still failed underneath: the rows are no fresher until the pass
      // lands. The screen shows the refreshing copy over it.
      expect(
        bloc.state,
        isA<GameCollectionListReady>()
            .having((s) => s.refreshing, 'refreshing', isTrue)
            .having((s) => s.refreshFailed, 'refreshFailed', isTrue),
      );

      pass.complete();
    });

    test('a pass nobody asked for is not narrated', () async {
      // Entry, reconnect and resume all start passes. Announcing them would
      // be noise on a screen that otherwise says nothing.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      status.started();
      await settle();

      expect(calls, isZero);
      expect(
        bloc.state,
        isA<GameCollectionListReady>().having(
          (s) => s.refreshing,
          'refreshing',
          isFalse,
        ),
      );
    });

    test(
      'a pass nobody asked for leaves the warning up until it lands',
      () async {
        // The rows are no fresher while it runs, and a banner that vanished
        // on start would take keyboard focus with it.
        final bloc = buildWithRetry();
        addTearDown(bloc.close);
        await settleOnAFailedRefresh();

        status.started();
        await settle();

        expect(
          bloc.state,
          isA<GameCollectionListReady>().having(
            (s) => s.refreshFailed,
            'refreshFailed',
            isTrue,
          ),
        );

        status.finished(CollectionHydrateOutcome.complete);
        await settle();

        expect(
          bloc.state,
          isA<GameCollectionListReady>().having(
            (s) => s.refreshFailed,
            'refreshFailed',
            isFalse,
          ),
        );
      },
    );

    test('a retry that fails again puts the banner back', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const GameCollectionListRetryRequested());
      status.started();
      await settle();
      status.finished(CollectionHydrateOutcome.failed);
      pass.complete();
      await settle();

      expect(
        bloc.state,
        isA<GameCollectionListReady>()
            .having((s) => s.refreshing, 'refreshing', isFalse)
            .having((s) => s.refreshFailed, 'refreshFailed', isTrue),
      );
    });

    test('a second press while one is running starts nothing', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const GameCollectionListRetryRequested());
      await settle();
      bloc.add(const GameCollectionListRetryRequested());
      await settle();

      expect(calls, 1);

      pass.complete();
    });

    test(
      'a retry over an unconfirmed empty list goes back to loading',
      () async {
        // An empty cache with a pass running is unknown, not empty, so the
        // screen must not put "no games yet" under a refreshing banner.
        final bloc = buildWithRetry();
        addTearDown(bloc.close);
        items.add(const []);
        status.finished(CollectionHydrateOutcome.failed);
        await settle();

        bloc.add(const GameCollectionListRetryRequested());
        status.started();
        await settle();

        expect(bloc.state, isA<GameCollectionListLoading>());

        pass.complete();
      },
    );

    test('is a no-op where no pass was supplied', () async {
      final bloc = build();
      addTearDown(bloc.close);
      items.add([listItem('e-1')]);
      await expectLater(
        bloc.stream,
        emitsThrough(isA<GameCollectionListReady>()),
      );

      bloc.add(const GameCollectionListRetryRequested());
      await settle();

      expect(
        bloc.state,
        isA<GameCollectionListReady>().having(
          (s) => s.refreshing,
          'refreshing',
          isFalse,
        ),
      );
    });
  });
}
