import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;

  final czech = languageTag('t1', name: 'Czech', tag: 'cs');
  final slovak = languageTag('t2', name: 'Slovak', tag: 'sk');
  final polish = languageTag('t3', name: 'Polish', tag: 'pl');
  final polishPoland = languageTag('t4', name: 'Polish (Poland)', tag: 'pl-PL');

  /// Short, so a test that waits for a debounce waits for little.
  const shortDebounce = Duration(milliseconds: 10);

  /// Long enough for [shortDebounce] to end and the read it starts to answer,
  /// with room to spare.
  const pastDebounce = Duration(milliseconds: 30);

  setUp(() => remote = FakeDataGatewayRemote());

  LanguageTagSearchCubit build({Duration debounce = shortDebounce}) =>
      LanguageTagSearchCubit(remote: remote, debounce: debounce);

  const loading = LanguageTagSearchState();
  const failed = LanguageTagSearchState(loading: false, failed: true);

  LanguageTagSearchState ready(
    List<LanguageTagRef> tags, {
    bool hasMore = false,
    bool loadingMore = false,
    bool moreFailed = false,
  }) => LanguageTagSearchState(
    tags: tags,
    loading: false,
    loadingMore: loadingMore,
    moreFailed: moreFailed,
    hasMore: hasMore,
  );

  /// Answers every read with the page [pageFor] makes of the name and page it
  /// asked for.
  void answering(
    PaginatedResult<LanguageTagRef> Function(String? name, int page) pageFor,
  ) =>
      remote.onFetchLanguageTags = (name, page, _) async => pageFor(name, page);

  /// Holds every read until the test completes the one it wants.
  Completer<PaginatedResult<LanguageTagRef>> hold() {
    final held = Completer<PaginatedResult<LanguageTagRef>>();
    remote.onFetchLanguageTags = (_, _, _) => held.future;
    return held;
  }

  group('the first page', () {
    test('a new cubit is loading, with nothing to show yet', () async {
      hold();
      final cubit = build();
      addTearDown(cubit.close);

      expect(cubit.state, const LanguageTagSearchState());
      expect(cubit.state.loading, isTrue);
      expect(cubit.state.tags, isEmpty);
      expect(cubit.state.loadingMore, isFalse);
      expect(cubit.state.failed, isFalse);
      expect(cubit.state.moreFailed, isFalse);
      expect(cubit.state.hasMore, isFalse);
      expect(remote.calls, ['fetchLanguageTags(null, 1)']);
    });

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'loads the first page with no name, undelayed',
      setUp: () => answering((_, _) => tagPageOf([czech, slovak])),
      // An hour of debounce: the first page must not wait for it.
      build: () => build(debounce: const Duration(hours: 1)),
      expect: () => [
        ready([czech, slovak]),
      ],
      verify: (_) => expect(remote.calls, ['fetchLanguageTags(null, 1)']),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a failed first read says so, and the tags stay empty',
      setUp: () =>
          remote.onFetchLanguageTags = (_, _, _) async => throw unreachable(),
      build: build,
      expect: () => [failed],
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a first page can be no tags at all, with more behind it',
      setUp: () => answering((_, _) => tagPageOf([], hasMore: true)),
      build: build,
      expect: () => [ready([], hasMore: true)],
    );
  });

  group('search', () {
    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'search waits for the debounce, and only the last one is sent',
      setUp: () =>
          answering((name, _) => tagPageOf(name == null ? [czech] : [polish])),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit
          ..search('p')
          ..search('po');
        expect(remote.calls, [
          'fetchLanguageTags(null, 1)',
        ], reason: 'nothing is sent before the debounce ends');
      },
      wait: pastDebounce,
      expect: () => [
        ready([czech]),
        loading,
        ready([polish]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(po, 1)',
      ]),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'search waits as long as the debounce it was given',
      setUp: () =>
          answering((name, _) => tagPageOf(name == null ? [czech] : [polish])),
      build: () => build(debounce: const Duration(hours: 1)),
      act: (cubit) async {
        await pumpEventQueue();
        cubit.search('po');
        // Long past the short debounce the other tests use.
        await Future<void>.delayed(pastDebounce);
      },
      expect: () => [
        ready([czech]),
      ],
      verify: (_) => expect(remote.calls, ['fetchLanguageTags(null, 1)']),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'search trims the name, and the name asked for last sends nothing again',
      setUp: () =>
          answering((name, _) => tagPageOf(name == null ? [czech] : [polish])),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        // Blank is the name the first page was asked for.
        cubit.search('   ');
        await Future<void>.delayed(pastDebounce);
        cubit.search('  po  ');
        await Future<void>.delayed(pastDebounce);
        // Trimmed, the name just asked for.
        cubit
          ..search('po')
          ..search(' po');
        await Future<void>.delayed(pastDebounce);
      },
      expect: () => [
        ready([czech]),
        loading,
        ready([polish]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(po, 1)',
      ]),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'typing back to the name already shown sends nothing',
      setUp: () => answering((_, _) => tagPageOf([czech])),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit
          ..search('p')
          ..search('');
        await Future<void>.delayed(pastDebounce);
      },
      expect: () => [
        ready([czech]),
      ],
      verify: (_) => expect(remote.calls, ['fetchLanguageTags(null, 1)']),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'erasing the name asks for the first page with no name',
      setUp: () =>
          answering((name, _) => tagPageOf(name == null ? [czech] : [polish])),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.search('po');
        await Future<void>.delayed(pastDebounce);
        cubit.search('');
        await Future<void>.delayed(pastDebounce);
      },
      expect: () => [
        ready([czech]),
        loading,
        ready([polish]),
        loading,
        ready([czech]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(po, 1)',
        'fetchLanguageTags(null, 1)',
      ]),
    );

    late Completer<PaginatedResult<LanguageTagRef>> firstRead;

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'an older answer arriving late is dropped',
      setUp: () {
        firstRead = Completer<PaginatedResult<LanguageTagRef>>();
        remote.onFetchLanguageTags = (name, _, _) =>
            name == null ? firstRead.future : Future.value(tagPageOf([polish]));
      },
      build: build,
      act: (cubit) async {
        cubit.search('po');
        await Future<void>.delayed(pastDebounce);
        // The first page was asked for before this search, and answers after
        // its answer.
        firstRead.complete(tagPageOf([czech]));
        await pumpEventQueue();
      },
      expect: () => [
        ready([polish]),
      ],
      verify: (cubit) => expect(cubit.state, ready([polish])),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a failure of an older read arriving late is dropped',
      setUp: () {
        firstRead = Completer<PaginatedResult<LanguageTagRef>>();
        remote.onFetchLanguageTags = (name, _, _) =>
            name == null ? firstRead.future : Future.value(tagPageOf([polish]));
      },
      build: build,
      act: (cubit) async {
        cubit.search('po');
        await Future<void>.delayed(pastDebounce);
        firstRead.completeError(unreachable());
        await pumpEventQueue();
      },
      expect: () => [
        ready([polish]),
      ],
    );
  });

  group('more', () {
    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'search resets to page one; more appends the next page',
      setUp: () => answering(
        (name, page) => switch ((name, page)) {
          (null, 1) => tagPageOf([czech, slovak], hasMore: true),
          (null, _) => tagPageOf([polish], page: 2),
          _ => tagPageOf([polishPoland]),
        },
      ),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.more();
        await pumpEventQueue();
        cubit.search('po');
        await Future<void>.delayed(pastDebounce);
      },
      expect: () => [
        ready([czech, slovak], hasMore: true),
        ready([czech, slovak], hasMore: true, loadingMore: true),
        ready([czech, slovak, polish]),
        loading,
        ready([polishPoland]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
        'fetchLanguageTags(po, 1)',
      ]),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a page of languages with no tags adds nothing and has more behind it; '
      'the next page is the one after the last answer, not counted from the '
      'tags',
      setUp: () => answering(
        (_, page) => switch (page) {
          // Three tags from one page of languages.
          1 => tagPageOf([czech, slovak, polish], hasMore: true),
          // A page of languages with no tags: no items, and more to come.
          2 => tagPageOf([], page: 2, hasMore: true),
          _ => tagPageOf([polishPoland], page: 3),
        },
      ),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.more();
        await pumpEventQueue();
        cubit.more();
      },
      expect: () => [
        ready([czech, slovak, polish], hasMore: true),
        ready([czech, slovak, polish], hasMore: true, loadingMore: true),
        ready([czech, slovak, polish], hasMore: true),
        ready([czech, slovak, polish], hasMore: true, loadingMore: true),
        ready([czech, slovak, polish, polishPoland]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
        'fetchLanguageTags(null, 3)',
      ]),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'more after a first page with no tags asks for page two',
      setUp: () => answering(
        (_, page) => page == 1
            ? tagPageOf([], hasMore: true)
            : tagPageOf([czech], page: 2),
      ),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.more();
      },
      expect: () => [
        ready([], hasMore: true),
        ready([], hasMore: true, loadingMore: true),
        ready([czech]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
      ]),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a tag a later page repeats is shown once',
      setUp: () => answering(
        (_, page) => page == 1
            ? tagPageOf([czech, slovak], hasMore: true)
            // The list shifted between the two reads, so the last language of
            // the first page is the first of the second.
            : tagPageOf([slovak, polish], page: 2),
      ),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.more();
      },
      skip: 2,
      expect: () => [
        ready([czech, slovak, polish]),
      ],
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a failed first read can retry',
      setUp: () {
        var reads = 0;
        remote.onFetchLanguageTags = (_, _, _) async =>
            ++reads == 1 ? throw unreachable() : tagPageOf([czech]);
      },
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.retry();
      },
      expect: () => [
        failed,
        loading,
        ready([czech]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 1)',
      ]),
    );

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a failed more keeps the tags, and the next more asks for the same page',
      setUp: () {
        var mores = 0;
        remote.onFetchLanguageTags = (_, page, _) async {
          if (page == 1) return tagPageOf([czech], hasMore: true);
          if (++mores == 1) throw unreachable();
          return tagPageOf([slovak], page: 2);
        };
      },
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.more();
        await pumpEventQueue();
        cubit.more();
      },
      expect: () => [
        ready([czech], hasMore: true),
        ready([czech], hasMore: true, loadingMore: true),
        ready([czech], hasMore: true, moreFailed: true),
        // The failure is cleared as the next more starts.
        ready([czech], hasMore: true, loadingMore: true),
        ready([czech, slovak]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
        'fetchLanguageTags(null, 2)',
      ]),
    );

    group('is dropped', () {
      test('while the first page is loading', () async {
        hold();
        final cubit = build();
        addTearDown(cubit.close);

        cubit.more();

        expect(remote.calls, ['fetchLanguageTags(null, 1)']);
        expect(cubit.state, loading);
      });

      test('while a more is out', () async {
        final held = Completer<PaginatedResult<LanguageTagRef>>();
        remote.onFetchLanguageTags = (_, page, _) => page == 1
            ? Future.value(tagPageOf([czech], hasMore: true))
            : held.future;
        final cubit = build();
        addTearDown(cubit.close);
        await pumpEventQueue();

        cubit
          ..more()
          ..more();
        await pumpEventQueue();

        expect(remote.calls, [
          'fetchLanguageTags(null, 1)',
          'fetchLanguageTags(null, 2)',
        ]);
      });

      test('after the first page failed', () async {
        remote.onFetchLanguageTags = (_, _, _) async => throw unreachable();
        final cubit = build();
        addTearDown(cubit.close);
        await pumpEventQueue();
        expect(cubit.state, failed);

        cubit.more();
        await pumpEventQueue();

        expect(remote.calls, ['fetchLanguageTags(null, 1)']);
        expect(cubit.state, failed);
      });

      test('when the server has said there is no more', () async {
        answering((_, _) => tagPageOf([czech]));
        final cubit = build();
        addTearDown(cubit.close);
        await pumpEventQueue();

        cubit.more();
        await pumpEventQueue();

        expect(remote.calls, ['fetchLanguageTags(null, 1)']);
        expect(cubit.state, ready([czech]));
      });
    });

    group('still out when', () {
      late Completer<PaginatedResult<LanguageTagRef>> moreRead;

      /// A first page with more behind it, a More that waits for [moreRead],
      /// and a search that finds Polish.
      ///
      /// Run from each test's own `setUp:`, not the group's, so the completer
      /// belongs to the zone `blocTest` guards. An error completed across the
      /// edge of that zone is not delivered to the read awaiting it: it is
      /// reported as uncaught, in the test.
      void serving() {
        moreRead = Completer<PaginatedResult<LanguageTagRef>>();
        remote.onFetchLanguageTags = (name, page, _) {
          if (name != null) return Future.value(tagPageOf([polish]));
          return page == 1
              ? Future.value(tagPageOf([czech], hasMore: true))
              : moreRead.future;
        };
      }

      blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
        'a search starts it is dropped when it lands, and stops showing at '
        'once',
        setUp: serving,
        build: build,
        act: (cubit) async {
          await pumpEventQueue();
          cubit
            ..more()
            ..search('po');
          await Future<void>.delayed(pastDebounce);
          moreRead.complete(tagPageOf([slovak], page: 2));
          await pumpEventQueue();
        },
        expect: () => [
          ready([czech], hasMore: true),
          ready([czech], hasMore: true, loadingMore: true),
          loading,
          ready([polish]),
        ],
        verify: (cubit) => expect(cubit.state, ready([polish])),
      );

      blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
        'a retry starts it is dropped when it lands, and stops showing at '
        'once',
        setUp: serving,
        build: build,
        act: (cubit) async {
          await pumpEventQueue();
          cubit
            ..more()
            ..retry();
          await pumpEventQueue();
          moreRead.complete(tagPageOf([slovak], page: 2));
          await pumpEventQueue();
        },
        expect: () => [
          ready([czech], hasMore: true),
          ready([czech], hasMore: true, loadingMore: true),
          loading,
          ready([czech], hasMore: true),
        ],
        verify: (cubit) => expect(cubit.state, ready([czech], hasMore: true)),
      );

      blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
        'a failure of the dropped more is not shown either',
        setUp: serving,
        build: build,
        act: (cubit) async {
          await pumpEventQueue();
          cubit
            ..more()
            ..retry();
          await pumpEventQueue();
          moreRead.completeError(unreachable());
          await pumpEventQueue();
        },
        expect: () => [
          ready([czech], hasMore: true),
          ready([czech], hasMore: true, loadingMore: true),
          loading,
          ready([czech], hasMore: true),
        ],
      );
    });

    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      'a search clears a failed more, which belonged to the tags it replaces',
      setUp: () => answering(
        (name, page) => switch ((name, page)) {
          (null, 1) => tagPageOf([czech], hasMore: true),
          (null, _) => throw unreachable(),
          _ => tagPageOf([polish], hasMore: true),
        },
      ),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.more();
        await pumpEventQueue();
        cubit.search('po');
        await Future<void>.delayed(pastDebounce);
      },
      expect: () => [
        ready([czech], hasMore: true),
        ready([czech], hasMore: true, loadingMore: true),
        ready([czech], hasMore: true, moreFailed: true),
        loading,
        ready([polish], hasMore: true),
      ],
    );
  });

  group('retry', () {
    blocTest<LanguageTagSearchCubit, LanguageTagSearchState>(
      "reads the current name's first page again",
      setUp: () =>
          answering((name, _) => tagPageOf(name == null ? [czech] : [polish])),
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.search('po');
        await Future<void>.delayed(pastDebounce);
        cubit.retry();
      },
      expect: () => [
        ready([czech]),
        loading,
        ready([polish]),
        loading,
        ready([polish]),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(po, 1)',
        'fetchLanguageTags(po, 1)',
      ]),
    );
  });

  group('closing', () {
    test('with a debounce pending sends nothing', () async {
      answering((_, _) => tagPageOf([czech]));
      final cubit = build();
      await pumpEventQueue();

      cubit.search('po');
      await cubit.close();
      await Future<void>.delayed(pastDebounce);

      expect(remote.calls, ['fetchLanguageTags(null, 1)']);
    });

    test('with the first page out, its answer lands without a throw', () async {
      final held = hold();
      final cubit = build();
      await cubit.close();

      held.complete(tagPageOf([czech]));
      await pumpEventQueue();

      expect(cubit.state, loading);
    });

    test(
      'with the first page out, its failure lands without a throw',
      () async {
        final held = hold();
        final cubit = build();
        await cubit.close();

        held.completeError(unreachable());
        await pumpEventQueue();

        expect(cubit.state, loading);
      },
    );

    test('with a more out, its answer lands without a throw', () async {
      final held = Completer<PaginatedResult<LanguageTagRef>>();
      remote.onFetchLanguageTags = (_, page, _) => page == 1
          ? Future.value(tagPageOf([czech], hasMore: true))
          : held.future;
      final cubit = build();
      await pumpEventQueue();
      cubit.more();
      await cubit.close();

      held.complete(tagPageOf([slovak], page: 2));
      await pumpEventQueue();

      expect(cubit.state, ready([czech], hasMore: true, loadingMore: true));
    });

    test('with a more out, its failure lands without a throw', () async {
      final held = Completer<PaginatedResult<LanguageTagRef>>();
      remote.onFetchLanguageTags = (_, page, _) => page == 1
          ? Future.value(tagPageOf([czech], hasMore: true))
          : held.future;
      final cubit = build();
      await pumpEventQueue();
      cubit.more();
      await cubit.close();

      held.completeError(unreachable());
      await pumpEventQueue();

      expect(cubit.state, ready([czech], hasMore: true, loadingMore: true));
    });

    test('a closed cubit sends nothing for more, retry or search', () async {
      answering((_, _) => tagPageOf([czech], hasMore: true));
      final cubit = build();
      await pumpEventQueue();
      await cubit.close();

      cubit
        ..more()
        ..retry()
        ..search('po');
      await Future<void>.delayed(pastDebounce);

      expect(remote.calls, ['fetchLanguageTags(null, 1)']);
    });
  });
}
