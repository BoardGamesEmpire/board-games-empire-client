import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

const _pageSize = DataGatewayRemoteDataSource.languageLinkPageSize;

/// A link whose value names it, so a banner's value says which.
LanguageLink _link(
  String id, {
  LanguageLinkStatus status = LanguageLinkStatus.unresolved,
  LanguageTagRef? tag,
}) => LanguageLink(id: id, value: 'Value of $id', status: status, tag: tag);

/// The id of the [n]th of a [_Server]'s links, counting from 1.
String _nth(int n) => 'r${n.toString().padLeft(3, '0')}';

/// The statuses a read that names none lists.
const _waitingStatuses = {
  LanguageLinkStatus.pending,
  LanguageLinkStatus.unresolved,
};

/// Waiting links, held as the server holds them: a read pages the ones under
/// the statuses it names, in order, and an ignore takes one off the waiting
/// list.
final class _Server {
  _Server(int count)
    : links = [for (var n = 1; n <= count; n++) _link(_nth(n))];

  final List<LanguageLink> links;

  /// The limit each read asked for.
  final List<int> limits = [];

  Future<PaginatedResult<LanguageLink>> read(
    Set<LanguageLinkStatus>? statuses,
    int page,
    int limit,
  ) async {
    limits.add(limit);
    final listed = [
      for (final link in links)
        if ((statuses ?? _waitingStatuses).contains(link.status)) link,
    ];
    final start = (page - 1) * limit;
    final items = listed.skip(start).take(limit).toList();
    return PaginatedResult(
      items: items,
      meta: PaginationMeta(
        page: page,
        limit: limit,
        total: listed.length,
        totalPages: (listed.length + limit - 1) ~/ limit,
        hasMore: start + items.length < listed.length,
      ),
    );
  }

  Future<LanguageLink> ignore(String id) async {
    final at = links.indexWhere((link) => link.id == id);
    return links[at] = links[at].copyWith(status: LanguageLinkStatus.ignored);
  }
}

void main() {
  late FakeDataGatewayRemote remote;
  late FakeCallerAccessRepository access;

  /// A caller who may read and update DataGateways: everything the worklist
  /// offers.
  final updating = FakeCallerAccessRepository.dataGateway(
    read: AccessExtent.all,
    update: AccessExtent.all,
  );

  /// A caller who may do anything to a DataGateway but update it.
  final allButUpdate = FakeCallerAccessRepository.dataGateway(
    create: AccessExtent.all,
    read: AccessExtent.all,
    delete: AccessExtent.all,
  );

  final a = _link('a');
  final b = _link('b');
  final c = _link('c');
  final d = _link('d');
  final pendingA = _link('a', status: LanguageLinkStatus.pending);
  final x = _link('x', status: LanguageLinkStatus.ignored);

  const czech = LanguageTagRef(id: 'tag_cs', tag: 'cs', name: 'Czech');
  const slovak = LanguageTagRef(id: 'tag_sk', tag: 'sk', name: 'Slovak');

  LanguageLink ignoredOf(LanguageLink link) =>
      link.copyWith(status: LanguageLinkStatus.ignored, tag: null);
  LanguageLink linkedOf(LanguageLink link, LanguageTagRef tag) =>
      link.copyWith(status: LanguageLinkStatus.resolved, tag: tag);

  const load = LanguageLinkListLoadRequested();
  const more = LanguageLinkListMoreRequested();
  const dismiss = LanguageLinkListOutcomeDismissed();
  LanguageLinkListEvent show(LanguageLinkFilter filter) =>
      LanguageLinkListFilterChanged(filter);
  LanguageLinkListEvent ignore(String id) =>
      LanguageLinkListActionRequested(LanguageLinkAction.ignore, id);
  LanguageLinkListEvent accept(String id) =>
      LanguageLinkListActionRequested(LanguageLinkAction.accept, id);
  LanguageLinkListEvent linkTo(String id, LanguageTagRef tag) =>
      LanguageLinkListActionRequested(
        LanguageLinkAction.link,
        id,
        tagId: tag.id,
      );

  String fetchCall({LanguageLinkStatus? status, int page = 1}) =>
      'fetchLanguageLinks(dg_1, '
      '${status == null ? null : <LanguageLinkStatus>{status}}, $page)';
  String ignoreCall(String id) => 'ignoreLanguageLink(dg_1, $id)';
  String acceptCall(String id) => 'acceptLanguageLink(dg_1, $id)';
  String linkCall(String id, LanguageTagRef tag) =>
      'linkLanguageLink(dg_1, $id, ${tag.id})';

  const settledFirst = DataGatewayConflictException(
    'not pending',
    statusCode: 409,
  );
  const notFound = DataGatewayNotFoundException('gone', statusCode: 404);
  const noSuchTag = DataGatewayPermanentException(
    'no such tag',
    statusCode: 400,
  );
  const unreadable = DataGatewayPermanentException(
    'Failed to parse the linkLanguageLink response',
    statusCode: 200,
  );

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = FakeCallerAccessRepository(updating);
  });

  LanguageLinkListBloc build() =>
      LanguageLinkListBloc(remote: remote, gatewayId: 'dg_1', access: access);

  PaginatedResult<LanguageLink> linksPage(
    List<LanguageLink> links, {
    bool hasMore = false,
  }) => PaginatedResult(
    items: links,
    meta: PaginationMeta(
      page: 1,
      limit: _pageSize,
      total: hasMore ? links.length + 1 : links.length,
      totalPages: hasMore ? 2 : 1,
      hasMore: hasMore,
    ),
  );

  /// Answers each read with the next of [answers], and goes on answering with
  /// the last. A page is the answer, a future is waited on, and anything else
  /// is thrown.
  void reads(List<Object> answers) {
    var read = 0;
    remote.onFetchLanguageLinks = (_, _, _, _) {
      final answer = answers[read < answers.length ? read : answers.length - 1];
      read++;
      return switch (answer) {
        final PaginatedResult<LanguageLink> page => Future.value(page),
        final Future<PaginatedResult<LanguageLink>> pending => pending,
        _ => Future.error(answer),
      };
    };
  }

  /// Answers each read with what [byStatus] holds for the status it names:
  /// null for a read that names none.
  void listing(Map<LanguageLinkStatus?, List<LanguageLink>> byStatus) =>
      remote.onFetchLanguageLinks = (_, statuses, _, _) async =>
          linksPage(byStatus[statuses?.single] ?? const []);

  /// Reads and ignores through [server].
  void serving(_Server server) {
    remote.onFetchLanguageLinks = (_, statuses, page, limit) =>
        server.read(statuses, page, limit);
    remote.onIgnoreLanguageLink = (_, id) => server.ignore(id);
  }

  LanguageLinkListReady ready(
    List<LanguageLink> links, {
    LanguageLinkFilter filter = LanguageLinkFilter.waiting,
    bool hasMore = false,
    bool loadingMore = false,
    bool moreFailed = false,
    bool mayUpdate = true,
    Set<String> busy = const {},
    LanguageLinkOutcome? outcome,
  }) => LanguageLinkListReady(
    filter: filter,
    links: links,
    hasMore: hasMore,
    loadingMore: loadingMore,
    moreFailed: moreFailed,
    mayUpdate: mayUpdate,
    busy: busy,
    outcome: outcome,
  );

  LanguageLinkOutcome told(LanguageLinkOutcomeKind kind, LanguageLink link) =>
      LanguageLinkOutcome(kind: kind, value: link.value);

  /// The ids of the rows [state] shows.
  List<String> idsOf(LanguageLinkListState state) => [
    for (final link in (state as LanguageLinkListReady).links) link.id,
  ];

  Future<void> send(
    LanguageLinkListBloc bloc,
    LanguageLinkListEvent event,
  ) async {
    bloc.add(event);
    await pumpEventQueue();
  }

  group('the filter', () {
    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'waiting sends no status',
      setUp: () => reads([
        linksPage([a, b]),
      ]),
      build: build,
      act: (bloc) => bloc.add(load),
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a, b]),
      ],
      verify: (_) {
        expect(remote.calls, ['fetchLanguageLinks(dg_1, null, 1)']);
        expect(access.refreshCount, 0);
      },
    );

    final ignoredA = ignoredOf(a);
    final linkedB = linkedOf(b, czech);

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'ignored and resolved each ask for that status',
      setUp: () => listing({
        null: [a, b],
        LanguageLinkStatus.ignored: [ignoredA],
        LanguageLinkStatus.resolved: [linkedB],
      }),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, show(LanguageLinkFilter.ignored));
        await send(bloc, show(LanguageLinkFilter.resolved));
      },
      skip: 2,
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready([ignoredA], filter: LanguageLinkFilter.ignored),
        const LanguageLinkListLoading(LanguageLinkFilter.resolved),
        ready([linkedB], filter: LanguageLinkFilter.resolved),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        'fetchLanguageLinks(dg_1, {LanguageLinkStatus.ignored}, 1)',
        'fetchLanguageLinks(dg_1, {LanguageLinkStatus.resolved}, 1)',
      ]),
    );

    late Completer<PaginatedResult<LanguageLink>> waitingRead;
    late Completer<PaginatedResult<LanguageLink>> ignoredRead;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'changing the filter drops a read still in flight',
      setUp: () {
        waitingRead = Completer();
        ignoredRead = Completer();
        remote.onFetchLanguageLinks = (_, statuses, _, _) =>
            statuses == null ? waitingRead.future : ignoredRead.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, show(LanguageLinkFilter.ignored));
        // The old read answers late, ahead of the new one.
        waitingRead.complete(linksPage([a, b]));
        await pumpEventQueue();
        ignoredRead.complete(linksPage([x]));
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready([x], filter: LanguageLinkFilter.ignored),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'choosing the filter already shown does nothing',
      setUp: () => listing({
        null: [a, b],
        LanguageLinkStatus.ignored: [x],
      }),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, show(LanguageLinkFilter.waiting));
        await send(bloc, show(LanguageLinkFilter.ignored));
        await send(bloc, show(LanguageLinkFilter.ignored));
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a, b]),
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready([x], filter: LanguageLinkFilter.ignored),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        fetchCall(status: LanguageLinkStatus.ignored),
      ]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a filter change clears the outcome, which described the rows left',
      setUp: () {
        listing({
          null: [a, b],
          LanguageLinkStatus.ignored: [ignoredA],
        });
        remote.onIgnoreLanguageLink = (_, _) async => ignoredA;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, show(LanguageLinkFilter.ignored));
      },
      skip: 4,
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready([ignoredA], filter: LanguageLinkFilter.ignored),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a retry after a failed read asks for the filter shown again',
      setUp: () {
        var ignoredReads = 0;
        remote.onFetchLanguageLinks = (_, statuses, _, _) async {
          if (statuses == null) return linksPage([a]);
          if (ignoredReads++ == 0) throw unreachable();
          return linksPage([x]);
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, show(LanguageLinkFilter.ignored));
        await send(bloc, load);
      },
      skip: 2,
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        const LanguageLinkListFailed(LanguageLinkFilter.ignored),
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready([x], filter: LanguageLinkFilter.ignored),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        fetchCall(status: LanguageLinkStatus.ignored),
        fetchCall(status: LanguageLinkStatus.ignored),
      ]),
    );
  });

  group('reading', () {
    group('a refused read is denied; a 404 is gone; another failure is '
        'failed', () {
      for (final (name, error, down, asks)
          in <(String, Object, LanguageLinkListState, int)>[
            (
              'a refused read asks access again',
              forbidden(),
              const LanguageLinkListDenied(LanguageLinkFilter.waiting),
              1,
            ),
            (
              'a 404 is gone',
              notFound,
              const LanguageLinkListGone(LanguageLinkFilter.waiting),
              0,
            ),
            (
              'another failure is failed',
              unreachable(),
              const LanguageLinkListFailed(LanguageLinkFilter.waiting),
              0,
            ),
          ]) {
        blocTest<LanguageLinkListBloc, LanguageLinkListState>(
          name,
          setUp: () => reads([error]),
          build: build,
          act: (bloc) => bloc.add(load),
          expect: () => [
            const LanguageLinkListLoading(LanguageLinkFilter.waiting),
            down,
          ],
          verify: (_) => expect(access.refreshCount, asks),
        );
      }
    });

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a refused read reads again once a changed answer allows read',
      setUp: () {
        access = FakeCallerAccessRepository();
        reads([
          forbidden(),
          linksPage([a]),
        ]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        access.current = updating;
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        const LanguageLinkListDenied(LanguageLinkFilter.waiting),
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a]),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a refused read stays denied while a changed answer still refuses read',
      setUp: () {
        access = FakeCallerAccessRepository();
        reads([forbidden()]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        access.current = FakeCallerAccessRepository.dataGateway(
          update: AccessExtent.all,
        );
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        const LanguageLinkListDenied(LanguageLinkFilter.waiting),
      ],
      verify: (_) => expect(remote.calls, [fetchCall()]),
    );

    late Completer<PaginatedResult<LanguageLink>> refusal;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a refused read reads again when an answer that allows read landed '
      'while it was out',
      setUp: () {
        access = FakeCallerAccessRepository();
        refusal = Completer();
        reads([
          refusal.future,
          linksPage([a]),
        ]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        // The ask the refusal sets off finds this same answer, so it never
        // says anything changed.
        access.current = updating;
        await pumpEventQueue();
        refusal.completeError(forbidden());
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        const LanguageLinkListDenied(LanguageLinkFilter.waiting),
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a]),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a refused read reads again only once for the answer that landed while '
      'it was out',
      setUp: () {
        access = FakeCallerAccessRepository();
        refusal = Completer();
        reads([refusal.future, forbidden()]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        access.current = updating;
        await pumpEventQueue();
        refusal.completeError(forbidden());
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        const LanguageLinkListDenied(LanguageLinkFilter.waiting),
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        const LanguageLinkListDenied(LanguageLinkFilter.waiting),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), fetchCall()]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a refused more reads again when an answer that allows read landed '
      'while it was out',
      setUp: () {
        refusal = Completer();
        reads([
          linksPage([a], hasMore: true),
          refusal.future,
          linksPage([a, b]),
        ]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, more);
        // A changed answer that still allows read.
        access.current = allButUpdate;
        await pumpEventQueue();
        refusal.completeError(forbidden());
        await pumpEventQueue();
      },
      skip: 4,
      expect: () => [
        const LanguageLinkListDenied(LanguageLinkFilter.waiting),
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a, b], mayUpdate: false),
      ],
      // The read, the More on the same short page, and the read again.
      verify: (_) =>
          expect(remote.calls, [fetchCall(), fetchCall(), fetchCall()]),
    );

    late Completer<PaginatedResult<LanguageLink>> pendingRead;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a read over rows on screen keeps them, with no Loading, until its '
      'answer replaces them',
      setUp: () {
        pendingRead = Completer();
        reads([
          linksPage([a, b], hasMore: true),
          pendingRead.future,
        ]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, load);
        expect(bloc.state, ready([a, b], hasMore: true));
        pendingRead.complete(linksPage([c]));
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a, b], hasMore: true),
        ready([c]),
      ],
    );

    late _Server server;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a read shows the first page alone, however many were shown, clears a '
      'failed more, and more goes on from that page',
      setUp: () {
        server = _Server(120);
        var failures = 1;
        remote.onFetchLanguageLinks = (_, statuses, page, limit) async {
          if (page == 3 && failures-- > 0) throw unreachable();
          return server.read(statuses, page, limit);
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, more);
        await send(bloc, more);
        expect(
          bloc.state,
          ready(server.links.sublist(0, 100), hasMore: true, moreFailed: true),
        );
        await send(bloc, load);
        expect(bloc.state, ready(server.links.sublist(0, 50), hasMore: true));
        await send(bloc, more);
      },
      verify: (bloc) {
        expect(bloc.state, ready(server.links.sublist(0, 100), hasMore: true));
        expect(remote.calls, [
          fetchCall(),
          fetchCall(page: 2),
          fetchCall(page: 3),
          fetchCall(),
          fetchCall(page: 2),
        ]);
      },
    );
  });

  late Completer<LanguageLink> ignoringFirst;

  group('more', () {
    late _Server server;
    late List<LanguageLink> first;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'more appends, and a failed more keeps the rows',
      setUp: () {
        server = _Server(60);
        var failures = 1;
        remote.onFetchLanguageLinks = (_, statuses, page, limit) async {
          if (page == 2 && failures-- > 0) throw unreachable();
          return server.read(statuses, page, limit);
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, more);
        await send(bloc, more);
      },
      skip: 2,
      expect: () {
        final shown = server.links.sublist(0, 50);
        return [
          ready(shown, hasMore: true, loadingMore: true),
          ready(shown, hasMore: true, moreFailed: true),
          ready(shown, hasMore: true, loadingMore: true),
          ready(server.links),
        ];
      },
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        fetchCall(page: 2),
        fetchCall(page: 2),
      ]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'more after a full page asks for page 2, at the page size',
      setUp: () => serving(server = _Server(60)),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, more);
      },
      verify: (bloc) {
        expect(remote.calls, [fetchCall(), fetchCall(page: 2)]);
        expect(server.limits, [_pageSize, _pageSize]);
        expect(bloc.state, ready(server.links));
      },
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'more after a row left the filter skips nothing and repeats nothing',
      setUp: () => serving(server = _Server(60)),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore(_nth(1)));
        await send(bloc, more);
      },
      verify: (bloc) {
        // The ignore moved the server's later links up a place, so 49 of its
        // places are read: more asks for page 49 ~/ 50 + 1 = 1, which now
        // starts at the second link.
        expect(remote.calls, [fetchCall(), ignoreCall(_nth(1)), fetchCall()]);
        expect(idsOf(bloc.state), [for (var n = 2; n <= 51; n++) _nth(n)]);
        expect((bloc.state as LanguageLinkListReady).hasMore, isTrue);
      },
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a link added ahead of the rows shown does not stall more: each more '
      'asks for the page after the last one read, and adds rows',
      setUp: () => serving(server = _Server(150)),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        // A language job, run after an interview, adds a link that sorts
        // first, and pushes every row shown down a place.
        server.links.insert(0, _link(_nth(0)));
        await send(bloc, more);
        // Page 2 starts with the 50th link, already shown, so it adds 49.
        expect(idsOf(bloc.state), [for (var n = 1; n <= 99; n++) _nth(n)]);
        await send(bloc, more);
      },
      verify: (bloc) {
        // 100 places are read, though 99 rows show, so page 3 is next, not
        // page 2 again.
        expect(remote.calls, [
          fetchCall(),
          fetchCall(page: 2),
          fetchCall(page: 3),
        ]);
        expect(idsOf(bloc.state), [for (var n = 1; n <= 149; n++) _nth(n)]);
      },
    );

    group('after a lost answer', () {
      // The server makes the change, and its answer is lost on the way back.
      for (final (what, event, LanguageLink Function(LanguageLink) made)
          in <
            (String, LanguageLinkListEvent, LanguageLink Function(LanguageLink))
          >[
            (
              'an ignore',
              ignore(_nth(1)),
              (link) => link.copyWith(status: LanguageLinkStatus.ignored),
            ),
            ('a link', linkTo(_nth(1), czech), (link) => linkedOf(link, czech)),
            (
              'an accept',
              accept(_nth(1)),
              (link) => link.copyWith(status: LanguageLinkStatus.resolved),
            ),
          ]) {
        blocTest<LanguageLinkListBloc, LanguageLinkListState>(
          '$what the server made: the next more shows the link that moved up',
          setUp: () {
            serving(server = _Server(60));
            // Accept is offered on a pending link.
            server.links[0] = server.links[0].copyWith(
              status: LanguageLinkStatus.pending,
            );
            Future<LanguageLink> lost(String id) async {
              final at = server.links.indexWhere((link) => link.id == id);
              server.links[at] = made(server.links[at]);
              throw unreachable();
            }

            remote.onIgnoreLanguageLink = (_, id) => lost(id);
            remote.onLinkLanguageLink = (_, id, _) => lost(id);
            remote.onAcceptLanguageLink = (_, id) => lost(id);
          },
          build: build,
          act: (bloc) async {
            await send(bloc, load);
            await send(bloc, event);
            await send(bloc, more);
          },
          verify: (bloc) {
            // The row stays: nothing said it left. But more starts a place
            // early, at the first page again, which now ends with the 51st
            // link.
            expect(remote.calls.last, fetchCall());
            expect(idsOf(bloc.state), [for (var n = 1; n <= 51; n++) _nth(n)]);
            expect((bloc.state as LanguageLinkListReady).hasMore, isTrue);
          },
        );
      }

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'an ignore the server did not make: more repeats nothing and skips '
        'nothing',
        setUp: () {
          serving(server = _Server(60));
          remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, ignore(_nth(1)));
          // A place early: page 1 again, all of it shown already.
          await send(bloc, more);
          await send(bloc, more);
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall(),
            ignoreCall(_nth(1)),
            fetchCall(),
            fetchCall(page: 2),
          ]);
          expect(idsOf(bloc.state), [for (var n = 1; n <= 60; n++) _nth(n)]);
          expect((bloc.state as LanguageLinkListReady).hasMore, isFalse);
        },
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'a link that would stay under the filter takes no place off: more '
        'asks for the next page',
        setUp: () {
          server = _Server(60);
          for (var at = 0; at < server.links.length; at++) {
            server.links[at] = linkedOf(server.links[at], czech);
          }
          serving(server);
          remote.onLinkLanguageLink = (_, _, _) async => throw unreachable();
        },
        build: build,
        act: (bloc) async {
          await send(bloc, show(LanguageLinkFilter.resolved));
          await send(bloc, linkTo(_nth(1), slovak));
          await send(bloc, more);
        },
        verify: (bloc) {
          expect(
            remote.calls.last,
            fetchCall(status: LanguageLinkStatus.resolved, page: 2),
          );
          expect(idsOf(bloc.state), [for (var n = 1; n <= 60; n++) _nth(n)]);
        },
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'a page of ignores lost and then made again: more still asks for the '
        'first page',
        setUp: () {
          serving(server = _Server(60));
          final tried = <String>{};
          remote.onIgnoreLanguageLink = (_, id) async {
            if (tried.add(id)) throw unreachable();
            return server.ignore(id);
          };
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          for (var round = 0; round < 2; round++) {
            for (var n = 1; n <= 50; n++) {
              await send(bloc, ignore(_nth(n)));
            }
          }
          await send(bloc, more);
        },
        verify: (bloc) {
          // Each lost answer counts a place short, and each ignore made again
          // takes its row off as well. The count stops at none, where page 0
          // is one the server refuses.
          expect(remote.calls.last, fetchCall());
          expect(idsOf(bloc.state), [for (var n = 51; n <= 60; n++) _nth(n)]);
          expect((bloc.state as LanguageLinkListReady).hasMore, isFalse);
        },
      );
    });

    group('more waits', () {
      late Completer<PaginatedResult<LanguageLink>> pendingRead;

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'for a read in flight, which is about to replace the rows, showing as '
        'loading, and starts when it answers',
        setUp: () {
          server = _Server(60);
          pendingRead = Completer();
          var firstPages = 0;
          remote.onFetchLanguageLinks = (_, statuses, page, limit) =>
              page == 1 && firstPages++ == 1
              ? pendingRead.future
              : server.read(statuses, page, limit);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, load);
          await send(bloc, more);
          expect(remote.calls, [fetchCall(), fetchCall()]);
          expect((bloc.state as LanguageLinkListReady).loadingMore, isTrue);
          pendingRead.complete(await server.read(null, 1, _pageSize));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [fetchCall(), fetchCall(), fetchCall(page: 2)]);
          expect((bloc.state as LanguageLinkListReady).loadingMore, isFalse);
          expect(idsOf(bloc.state), hasLength(60));
        },
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'for a read, which ends the wait when it says there is no more',
        setUp: () {
          pendingRead = Completer();
          reads([
            linksPage([a, b], hasMore: true),
            pendingRead.future,
          ]);
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, load);
          await send(bloc, more);
          pendingRead.complete(linksPage([a, b]));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [fetchCall(), fetchCall()]);
          expect(bloc.state, ready([a, b]));
        },
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'for an action, showing as loading, and starts when the last one ends',
        setUp: () {
          server = _Server(60);
          final ignoring = Completer<LanguageLink>();
          ignoringFirst = ignoring;
          remote.onFetchLanguageLinks = (_, statuses, page, limit) =>
              server.read(statuses, page, limit);
          remote.onIgnoreLanguageLink = (_, id) => ignoring.future;
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, ignore(_nth(1)));
          await send(bloc, more);
          expect(remote.calls, [fetchCall(), ignoreCall(_nth(1))]);
          expect((bloc.state as LanguageLinkListReady).loadingMore, isTrue);
          ignoringFirst.complete(await server.ignore(_nth(1)));
          await pumpEventQueue();
        },
        verify: (bloc) {
          // The page holding the first link not read, now the action took a
          // row off: none skipped, and none twice.
          expect(remote.calls, [
            fetchCall(),
            ignoreCall(_nth(1)),
            fetchCall(page: 1),
          ]);
          expect((bloc.state as LanguageLinkListReady).loadingMore, isFalse);
          expect(idsOf(bloc.state), [
            for (var n = 2; n <= 50; n++) _nth(n),
            _nth(51),
          ]);
        },
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'until a filter change, which ends it',
        setUp: () {
          ignoringFirst = Completer<LanguageLink>();
          reads([
            linksPage([a, b], hasMore: true),
          ]);
          remote.onIgnoreLanguageLink = (_, _) => ignoringFirst.future;
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, ignore('a'));
          await send(bloc, more);
          await send(bloc, show(LanguageLinkFilter.ignored));
        },
        verify: (bloc) {
          expect((bloc.state as LanguageLinkListReady).loadingMore, isFalse);
          expect(remote.calls.where((call) => call.endsWith(', 2)')), isEmpty);
        },
      );
    });

    group('more is dropped', () {
      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'while another is out',
        setUp: () {
          server = _Server(60);
          remote.onFetchLanguageLinks = (_, statuses, page, limit) => page == 1
              ? server.read(statuses, page, limit)
              : Completer<PaginatedResult<LanguageLink>>().future;
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          bloc
            ..add(more)
            ..add(more);
          await pumpEventQueue();
          await send(bloc, more);
        },
        verify: (_) => expect(remote.calls, [fetchCall(), fetchCall(page: 2)]),
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'when the server has said there is no more',
        setUp: () => reads([
          linksPage([a, b]),
        ]),
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, more);
        },
        skip: 2,
        expect: () => <LanguageLinkListState>[],
        verify: (_) => expect(remote.calls, [fetchCall()]),
      );
    });

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'more during an action is dropped',
      setUp: () {
        serving(server = _Server(60));
        remote.onIgnoreLanguageLink = (_, _) =>
            Completer<LanguageLink>().future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore(_nth(1)));
        await send(bloc, more);
      },
      verify: (_) => expect(remote.calls, [fetchCall(), ignoreCall(_nth(1))]),
    );

    late Completer<PaginatedResult<LanguageLink>> pendingMore;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a newer read drops a more still out, which stops showing at once',
      setUp: () {
        server = _Server(60);
        first = server.links.sublist(0, 50);
        pendingMore = Completer();
        var firstPages = 0;
        remote.onFetchLanguageLinks = (_, statuses, page, limit) async {
          if (page == 2) return pendingMore.future;
          // By the second read, someone else has ignored the first link.
          if (firstPages++ == 1) await server.ignore(_nth(1));
          return server.read(statuses, page, limit);
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, more);
        await send(bloc, load);
        pendingMore.complete(linksPage(server.links.sublist(50)));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready(first, hasMore: true, loadingMore: true),
        ready(first, hasMore: true),
        ready(server.links.sublist(1, 51), hasMore: true),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a filter change drops a more still out',
      setUp: () {
        server = _Server(60);
        first = server.links.sublist(0, 50);
        pendingMore = Completer();
        remote.onFetchLanguageLinks = (_, statuses, page, limit) async {
          if (statuses != null) return linksPage([x]);
          if (page == 2) return pendingMore.future;
          return server.read(statuses, page, limit);
        };
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, more);
        await send(bloc, show(LanguageLinkFilter.ignored));
        pendingMore.complete(linksPage(server.links.sublist(50)));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready(first, hasMore: true, loadingMore: true),
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready([x], filter: LanguageLinkFilter.ignored),
      ],
    );

    group('a refused more is denied, and a 404 more is gone', () {
      for (final (name, error, down, asks)
          in <(String, Object, LanguageLinkListState, int)>[
            (
              'refused, and asks access again',
              forbidden(),
              const LanguageLinkListDenied(LanguageLinkFilter.waiting),
              1,
            ),
            (
              '404',
              notFound,
              const LanguageLinkListGone(LanguageLinkFilter.waiting),
              0,
            ),
          ]) {
        blocTest<LanguageLinkListBloc, LanguageLinkListState>(
          name,
          setUp: () {
            server = _Server(60);
            remote.onFetchLanguageLinks = (_, statuses, page, limit) async {
              if (page == 2) throw error;
              return server.read(statuses, page, limit);
            };
          },
          build: build,
          act: (bloc) async {
            await send(bloc, load);
            await send(bloc, more);
          },
          skip: 3,
          expect: () => [down],
          verify: (_) => expect(access.refreshCount, asks),
        );
      }
    });
  });

  group('actions', () {
    test('languageLinkActions per status', () {
      const link = LanguageLinkAction.link;
      const ignore = LanguageLinkAction.ignore;
      const accept = LanguageLinkAction.accept;

      expect(
        {
          for (final status in LanguageLinkStatus.values)
            status: languageLinkActions(status),
        },
        {
          LanguageLinkStatus.pending: [accept, link, ignore],
          LanguageLinkStatus.unresolved: [link, ignore],
          LanguageLinkStatus.ignored: [link],
          LanguageLinkStatus.resolved: [link, ignore],
          LanguageLinkStatus.unknown: [link, ignore],
        },
      );
    });

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'ignore in the waiting filter drops the row',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(a);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        ready([b], outcome: told(LanguageLinkOutcomeKind.ignored, a)),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), ignoreCall('a')]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'link in the waiting filter drops the row',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onLinkLanguageLink = (_, _, _) async => linkedOf(a, czech);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, linkTo('a', czech));
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        ready([b], outcome: told(LanguageLinkOutcomeKind.linked, a)),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), linkCall('a', czech)]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'link in the resolved filter replaces the row',
      setUp: () {
        listing({
          null: [a],
          LanguageLinkStatus.resolved: [linkedOf(a, czech), linkedOf(b, czech)],
        });
        remote.onLinkLanguageLink = (_, _, _) async => linkedOf(a, slovak);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, show(LanguageLinkFilter.resolved));
        await send(bloc, linkTo('a', slovak));
      },
      skip: 4,
      expect: () => [
        ready(
          [linkedOf(a, czech), linkedOf(b, czech)],
          filter: LanguageLinkFilter.resolved,
          busy: {'a'},
        ),
        ready(
          [linkedOf(a, slovak), linkedOf(b, czech)],
          filter: LanguageLinkFilter.resolved,
          outcome: told(LanguageLinkOutcomeKind.linked, a),
        ),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'ignore in the ignored filter keeps the row',
      setUp: () {
        listing({
          null: [a],
          LanguageLinkStatus.ignored: [ignoredOf(b)],
        });
        remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(b);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, show(LanguageLinkFilter.ignored));
        await send(bloc, ignore('b'));
      },
      skip: 4,
      expect: () => [
        ready([ignoredOf(b)], filter: LanguageLinkFilter.ignored, busy: {'b'}),
        ready(
          [ignoredOf(b)],
          filter: LanguageLinkFilter.ignored,
          outcome: told(LanguageLinkOutcomeKind.ignored, b),
        ),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'accept in the waiting filter drops the row',
      setUp: () {
        reads([
          linksPage([pendingA, b]),
        ]);
        remote.onAcceptLanguageLink = (_, _) async => linkedOf(pendingA, czech);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, accept('a'));
      },
      skip: 2,
      expect: () => [
        ready([pendingA, b], busy: {'a'}),
        ready([b], outcome: told(LanguageLinkOutcomeKind.accepted, pendingA)),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), acceptCall('a')]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a conflict reports it and reads the list again',
      setUp: () {
        reads([
          linksPage([pendingA, b]),
          linksPage([b]),
        ]);
        remote.onAcceptLanguageLink = (_, _) async => throw settledFirst;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, accept('a'));
      },
      skip: 2,
      expect: () {
        final conflict = told(LanguageLinkOutcomeKind.conflict, pendingA);
        return [
          ready([pendingA, b], busy: {'a'}),
          // The row stays until the read says where it stands.
          ready([pendingA, b], outcome: conflict),
          ready([b], outcome: conflict),
        ];
      },
      verify: (_) =>
          expect(remote.calls, [fetchCall(), acceptCall('a'), fetchCall()]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a permanent failure on link says the tag is unknown',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onLinkLanguageLink = (_, _, _) async => throw noSuchTag;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, linkTo('a', czech));
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        ready([a, b], outcome: told(LanguageLinkOutcomeKind.unknownTag, a)),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), linkCall('a', czech)]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      "a link whose answer can't be read reports no answer, not an unknown "
      'tag',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onLinkLanguageLink = (_, _, _) async => throw unreadable;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, linkTo('a', czech));
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        ready([a, b], outcome: told(LanguageLinkOutcomeKind.noAnswer, a)),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), linkCall('a', czech)]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a 404 on an action reads again, and its 404 means gone',
      setUp: () {
        reads([
          linksPage([a, b]),
          notFound,
        ]);
        remote.onIgnoreLanguageLink = (_, _) async => throw notFound;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        // The row comes off at once.
        ready([b], outcome: told(LanguageLinkOutcomeKind.gone, a)),
        const LanguageLinkListGone(LanguageLinkFilter.waiting),
      ],
      verify: (_) =>
          expect(remote.calls, [fetchCall(), ignoreCall('a'), fetchCall()]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a refused link asks access again, and the actions go once it answers '
      'that they may not',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onLinkLanguageLink = (_, _, _) async => throw forbidden();
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, linkTo('a', czech));
        expect(access.refreshCount, 1);
        // What the ask found.
        access.current = allButUpdate;
        await pumpEventQueue();
        await send(bloc, ignore('b'));
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        // The refusal alone takes nothing away: access does.
        ready([a, b], outcome: told(LanguageLinkOutcomeKind.refused, a)),
        ready(
          [a, b],
          mayUpdate: false,
          outcome: told(LanguageLinkOutcomeKind.refused, a),
        ),
      ],
      verify: (_) => expect(remote.calls, [fetchCall(), linkCall('a', czech)]),
    );

    group('no answer keeps the row', () {
      for (final (cause, event, call, script)
          in <(String, LanguageLinkListEvent, String, void Function())>[
            (
              'a dropped connection, and reads nothing more',
              ignore('a'),
              ignoreCall('a'),
              () =>
                  remote.onIgnoreLanguageLink = (_, _) async =>
                      throw unreachable(),
            ),
            (
              'a 400 to an accept, which names no tag',
              accept('a'),
              acceptCall('a'),
              () =>
                  remote.onAcceptLanguageLink = (_, _) async => throw noSuchTag,
            ),
            (
              'a 409 to a link, since only accept answers one',
              linkTo('a', czech),
              linkCall('a', czech),
              () =>
                  remote.onLinkLanguageLink = (_, _, _) async =>
                      throw settledFirst,
            ),
          ]) {
        blocTest<LanguageLinkListBloc, LanguageLinkListState>(
          cause,
          setUp: () {
            reads([
              linksPage([a, b]),
            ]);
            script();
          },
          build: build,
          act: (bloc) async {
            await send(bloc, load);
            await send(bloc, event);
          },
          skip: 2,
          expect: () => [
            ready([a, b], busy: {'a'}),
            ready([a, b], outcome: told(LanguageLinkOutcomeKind.noAnswer, a)),
          ],
          verify: (_) => expect(remote.calls, [fetchCall(), call]),
        );
      }
    });

    group('an action on a busy row is dropped', () {
      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'on a busy row',
        setUp: () {
          reads([
            linksPage([a, b]),
          ]);
          remote.onIgnoreLanguageLink = (_, _) =>
              Completer<LanguageLink>().future;
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          // A double press, and a press once the first is under way.
          bloc
            ..add(ignore('a'))
            ..add(linkTo('a', czech));
          await pumpEventQueue();
          await send(bloc, accept('a'));
        },
        skip: 2,
        expect: () => [
          ready([a, b], busy: {'a'}),
        ],
        verify: (_) => expect(remote.calls, [fetchCall(), ignoreCall('a')]),
      );
    });

    group('an action during more', () {
      late _Server server;
      late Completer<PaginatedResult<LanguageLink>> firstMore;

      /// Holds the first More, and answers the rest.
      void holdingTheFirstMore() {
        server = _Server(60);
        firstMore = Completer();
        var mores = 0;
        remote.onFetchLanguageLinks = (_, statuses, page, limit) =>
            page == 2 && mores++ == 0
            ? firstMore.future
            : server.read(statuses, page, limit);
        remote.onIgnoreLanguageLink = (_, id) => server.ignore(id);
      }

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'starts at once, and More is asked for again afterwards, so no link '
        'the action moved up is skipped',
        setUp: holdingTheFirstMore,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, more);
          await send(bloc, ignore(_nth(1)));
          // A page read before the action reached the server, landing late.
          firstMore.complete(await server.read(null, 2, _pageSize));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [
            fetchCall(),
            fetchCall(page: 2),
            ignoreCall(_nth(1)),
            fetchCall(),
          ]);
          final state = bloc.state as LanguageLinkListReady;
          expect(state.loadingMore, isFalse);
          expect(idsOf(state), [for (var n = 2; n <= 51; n++) _nth(n)]);
          expect(state.outcome?.kind, LanguageLinkOutcomeKind.ignored);
        },
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'shows as loading all the while',
        setUp: () {
          holdingTheFirstMore();
          remote.onIgnoreLanguageLink = (_, _) =>
              Completer<LanguageLink>().future;
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, more);
          await send(bloc, ignore(_nth(1)));
        },
        verify: (bloc) {
          final state = bloc.state as LanguageLinkListReady;
          expect(state.loadingMore, isTrue);
          expect(state.busy, {_nth(1)});
        },
      );
    });

    late Completer<LanguageLink> ignoringA;
    late Completer<LanguageLink> ignoringB;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'actions on two rows run side by side',
      setUp: () {
        reads([
          linksPage([a, b, c]),
        ]);
        ignoringA = Completer();
        ignoringB = Completer();
        remote.onIgnoreLanguageLink = (_, id) =>
            id == 'a' ? ignoringA.future : ignoringB.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, ignore('b'));
        ignoringA.complete(ignoredOf(a));
        await pumpEventQueue();
        ignoringB.complete(ignoredOf(b));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready([a, b, c], busy: {'a'}),
        ready([a, b, c], busy: {'a', 'b'}),
        ready(
          [b, c],
          busy: {'b'},
          outcome: told(LanguageLinkOutcomeKind.ignored, a),
        ),
        ready([c], outcome: told(LanguageLinkOutcomeKind.ignored, b)),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a link that names no tag is dropped, and sends nothing',
      setUp: () => reads([
        linksPage([a, b]),
      ]),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(
          bloc,
          const LanguageLinkListActionRequested(LanguageLinkAction.link, 'a'),
        );
      },
      skip: 2,
      expect: () => <LanguageLinkListState>[],
      verify: (_) => expect(remote.calls, [fetchCall()]),
    );
  });

  group('reads and actions overlap', () {
    late Completer<LanguageLink> pendingIgnore;
    late Completer<PaginatedResult<LanguageLink>> pendingRead;

    /// The ignore of `a` waits for [pendingIgnore], and the second read for
    /// [pendingRead].
    void holdingTheIgnoreAndTheSecondRead() {
      pendingIgnore = Completer();
      pendingRead = Completer();
      reads([
        linksPage([a, b]),
        pendingRead.future,
        linksPage([b, c]),
      ]);
      remote.onIgnoreLanguageLink = (_, _) => pendingIgnore.future;
    }

    // Read before the ignore was made, so it still has `a` waiting.
    final old = linksPage([a, b]);

    for (final (ordering, act, calls)
        in <
          (String, Future<void> Function(LanguageLinkListBloc), List<String>)
        >[
          (
            'the read answers after',
            (bloc) async {
              await send(bloc, load);
              await send(bloc, ignore('a'));
              await send(bloc, load);
              pendingIgnore.complete(ignoredOf(a));
              await pumpEventQueue();
              pendingRead.complete(old);
              await pumpEventQueue();
            },
            [fetchCall(), ignoreCall('a'), fetchCall(), fetchCall()],
          ),
          (
            // Nothing but the read sequence can stop it: the old read lands
            // after busy has cleared and before the read asked for starts.
            'the read answers in the same turn, before the next read starts',
            (bloc) async {
              await send(bloc, load);
              await send(bloc, ignore('a'));
              await send(bloc, load);
              pendingIgnore.complete(ignoredOf(a));
              pendingRead.complete(old);
              await pumpEventQueue();
            },
            [fetchCall(), ignoreCall('a'), fetchCall(), fetchCall()],
          ),
          (
            'the read was sent before the action',
            (bloc) async {
              await send(bloc, load);
              await send(bloc, load);
              await send(bloc, ignore('a'));
              pendingIgnore.complete(ignoredOf(a));
              await pumpEventQueue();
              pendingRead.complete(old);
              await pumpEventQueue();
            },
            [fetchCall(), fetchCall(), ignoreCall('a'), fetchCall()],
          ),
        ]) {
      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'an action ending with a read in flight drops that read and reads '
        'again: $ordering',
        setUp: holdingTheIgnoreAndTheSecondRead,
        build: build,
        act: act,
        skip: 2,
        expect: () => [
          ready([a, b], busy: {'a'}),
          ready([b], outcome: told(LanguageLinkOutcomeKind.ignored, a)),
          ready([b, c], outcome: told(LanguageLinkOutcomeKind.ignored, a)),
        ],
        verify: (_) => expect(remote.calls, calls),
      );
    }

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'an action ending after a read landed during it reads again',
      setUp: () {
        pendingIgnore = Completer();
        reads([
          linksPage([a, b]),
          linksPage([a, b, d]),
          linksPage([b, c, d]),
        ]);
        remote.onIgnoreLanguageLink = (_, _) => pendingIgnore.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, load);
        pendingIgnore.complete(ignoredOf(a));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        // The read that landed shows, and the action settles over it.
        ready([a, b, d], busy: {'a'}),
        ready([b, d], outcome: told(LanguageLinkOutcomeKind.ignored, a)),
        ready([b, c, d], outcome: told(LanguageLinkOutcomeKind.ignored, a)),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        ignoreCall('a'),
        fetchCall(),
        fetchCall(),
      ]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a filter change during an action reads the new filter again when the '
      'action ends, and its outcome shows',
      setUp: () {
        pendingIgnore = Completer();
        var ignoredReads = 0;
        remote
          ..onFetchLanguageLinks = (_, statuses, _, _) async {
            if (statuses == null) return linksPage([a, b]);
            // The first ignored read is answered before the ignore is made.
            return ignoredReads++ == 0
                ? linksPage([x])
                : linksPage([ignoredOf(a), x]);
          }
          ..onIgnoreLanguageLink = (_, _) => pendingIgnore.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, show(LanguageLinkFilter.ignored));
        pendingIgnore.complete(ignoredOf(a));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () {
        const ignored = LanguageLinkFilter.ignored;
        final outcome = told(LanguageLinkOutcomeKind.ignored, a);
        return [
          ready([a, b], busy: {'a'}),
          const LanguageLinkListLoading(ignored),
          ready([x], filter: ignored, busy: {'a'}),
          // `a` isn't among the rows shown, so it is left for the read.
          ready([x], filter: ignored, outcome: outcome),
          ready([ignoredOf(a), x], filter: ignored, outcome: outcome),
        ];
      },
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        ignoreCall('a'),
        fetchCall(status: LanguageLinkStatus.ignored),
        fetchCall(status: LanguageLinkStatus.ignored),
      ]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      "a filter change whose read is still out when an action ends reads "
      'again, and the outcome shows',
      setUp: () {
        pendingIgnore = Completer();
        pendingRead = Completer();
        var ignoredReads = 0;
        remote
          ..onFetchLanguageLinks = (_, statuses, _, _) {
            if (statuses == null) return Future.value(linksPage([a, b]));
            return ignoredReads++ == 0
                ? pendingRead.future
                : Future.value(linksPage([ignoredOf(a), x]));
          }
          ..onIgnoreLanguageLink = (_, _) => pendingIgnore.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, show(LanguageLinkFilter.ignored));
        pendingIgnore.complete(ignoredOf(a));
        await pumpEventQueue();
        pendingRead.complete(linksPage([x]));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready([a, b], busy: {'a'}),
        const LanguageLinkListLoading(LanguageLinkFilter.ignored),
        ready(
          [ignoredOf(a), x],
          filter: LanguageLinkFilter.ignored,
          outcome: told(LanguageLinkOutcomeKind.ignored, a),
        ),
      ],
      verify: (_) => expect(remote.calls, [
        fetchCall(),
        ignoreCall('a'),
        fetchCall(status: LanguageLinkStatus.ignored),
        fetchCall(status: LanguageLinkStatus.ignored),
      ]),
    );

    for (final (ends, answer, kind)
        in <(String, Object, LanguageLinkOutcomeKind)>[
          ('succeeds', ignoredOf(a), LanguageLinkOutcomeKind.ignored),
          ('finds the link gone', notFound, LanguageLinkOutcomeKind.gone),
        ]) {
      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'a read that fails during an action takes the rows down, and an '
        'action that then $ends reads nothing: the outcome waits for the '
        'retry',
        setUp: () {
          pendingIgnore = Completer();
          reads([
            linksPage([a, b]),
            unreachable(),
            linksPage([b]),
          ]);
          remote.onIgnoreLanguageLink = (_, _) => pendingIgnore.future;
        },
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, ignore('a'));
          await send(bloc, load);
          switch (answer) {
            case final LanguageLink link:
              pendingIgnore.complete(link);
            case final Object error:
              pendingIgnore.completeError(error);
          }
          await pumpEventQueue();
          expect(remote.calls, [fetchCall(), ignoreCall('a'), fetchCall()]);
          await send(bloc, load);
        },
        skip: 2,
        expect: () => [
          ready([a, b], busy: {'a'}),
          const LanguageLinkListFailed(LanguageLinkFilter.waiting),
          const LanguageLinkListLoading(LanguageLinkFilter.waiting),
          ready([b], outcome: told(kind, a)),
        ],
      );
    }
  });

  group('closing during an action does not throw', () {
    late Completer<LanguageLink> pending;

    // Run as each blocTest's own setUp, inside its zone. A future's error
    // does not cross into another error zone, so one made in a group setUp
    // never reaches the handler.
    void holdingTheAccept() {
      pending = Completer<LanguageLink>();
      reads([
        linksPage([pendingA, b]),
      ]);
      remote.onAcceptLanguageLink = (_, _) => pending.future;
    }

    // A conflict and a 404 each want a read after the action.
    for (final (ends, end) in <(String, void Function())>[
      ('it succeeds', () => pending.complete(linkedOf(pendingA, czech))),
      ('it conflicts', () => pending.completeError(settledFirst)),
      ('it finds the link gone', () => pending.completeError(notFound)),
    ]) {
      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'when $ends after the close',
        setUp: holdingTheAccept,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, accept('a'));
          await bloc.close();
          end();
          await pumpEventQueue();
        },
        verify: (_) => expect(remote.calls, [fetchCall(), acceptCall('a')]),
      );

      blocTest<LanguageLinkListBloc, LanguageLinkListState>(
        'when $ends in the same turn as the close',
        setUp: holdingTheAccept,
        build: build,
        act: (bloc) async {
          await send(bloc, load);
          await send(bloc, accept('a'));
          final closing = bloc.close();
          end();
          await closing;
          await pumpEventQueue();
        },
        verify: (_) => expect(remote.calls, [fetchCall(), acceptCall('a')]),
      );
    }

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'when a read landed during it, which wants one more read after',
      setUp: holdingTheAccept,
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, accept('a'));
        await send(bloc, load);
        final closing = bloc.close();
        pending.complete(linkedOf(pendingA, czech));
        await closing;
        await pumpEventQueue();
      },
      verify: (_) =>
          expect(remote.calls, [fetchCall(), acceptCall('a'), fetchCall()]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'when a read is still in flight, which wants one more read after',
      setUp: () {
        holdingTheAccept();
        reads([
          linksPage([pendingA, b]),
          Completer<PaginatedResult<LanguageLink>>().future,
        ]);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, accept('a'));
        await send(bloc, load);
        final closing = bloc.close();
        pending.complete(linkedOf(pendingA, czech));
        await closing;
        await pumpEventQueue();
      },
      verify: (_) =>
          expect(remote.calls, [fetchCall(), acceptCall('a'), fetchCall()]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'and a refusal that lands after the close still asks access again',
      setUp: holdingTheAccept,
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, accept('a'));
        await bloc.close();
        pending.completeError(forbidden());
        await pumpEventQueue();
      },
      verify: (_) => expect(access.refreshCount, 1),
    );
  });

  group('what the caller may do (#456)', () {
    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a read that succeeds while access is unknown asks access again',
      // The first ask failed with the server up, and nothing else would ask
      // again until a rehydrate trigger.
      setUp: () {
        reads([
          linksPage([b]),
        ]);
        access.current = const CallerAccess.unknown();
      },
      build: build,
      act: (bloc) => bloc.add(load),
      skip: 1,
      expect: () => [
        ready([b], mayUpdate: false),
      ],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'a read that succeeds while access is known asks nothing',
      setUp: () => reads([
        linksPage([b]),
      ]),
      build: build,
      act: (bloc) => bloc.add(load),
      skip: 1,
      expect: () => [
        ready([b]),
      ],
      verify: (_) => expect(access.refreshCount, 0),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'link, ignore and accept follow update',
      setUp: () {
        reads([
          linksPage([pendingA, b]),
        ]);
        access.current = const CallerAccess.unknown();
        remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(b);
      },
      build: build,
      act: (bloc) async {
        Future<void> askEach() async {
          await send(bloc, accept('a'));
          await send(bloc, linkTo('a', czech));
          await send(bloc, ignore('b'));
        }

        await send(bloc, load);
        await askEach();
        access.current = allButUpdate;
        await pumpEventQueue();
        await askEach();
        expect(remote.calls, [fetchCall()]);

        access.current = FakeCallerAccessRepository.dataGateway(
          update: AccessExtent.some,
        );
        await pumpEventQueue();
        await send(bloc, ignore('b'));

        access.current = allButUpdate;
        await pumpEventQueue();
        await askEach();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        // Unknown, then known without update: the same, and nothing sent.
        ready([pendingA, b], mayUpdate: false),
        ready([pendingA, b]),
        ready([pendingA, b], busy: {'b'}),
        ready([pendingA], outcome: told(LanguageLinkOutcomeKind.ignored, b)),
        ready(
          [pendingA],
          mayUpdate: false,
          outcome: told(LanguageLinkOutcomeKind.ignored, b),
        ),
      ],
      // Without reading the list again as access changes.
      verify: (_) => expect(remote.calls, [fetchCall(), ignoreCall('b')]),
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'offers nothing without a session to ask',
      setUp: () => reads([
        linksPage([a, b]),
      ]),
      build: () => LanguageLinkListBloc(remote: remote, gatewayId: 'dg_1'),
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
      },
      skip: 1,
      expect: () => [
        ready([a, b], mayUpdate: false),
      ],
      verify: (_) => expect(remote.calls, [fetchCall()]),
    );

    late Completer<LanguageLink> held;

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'update falling during an action lets it answer',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        held = Completer();
        remote.onIgnoreLanguageLink = (_, _) => held.future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        access.current = allButUpdate;
        await pumpEventQueue();
        held.complete(ignoredOf(a));
        await pumpEventQueue();
      },
      skip: 3,
      expect: () => [
        ready([a, b], mayUpdate: false, busy: {'a'}),
        ready(
          [b],
          mayUpdate: false,
          outcome: told(LanguageLinkOutcomeKind.ignored, a),
        ),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'stops listening on close',
      setUp: () => reads([
        linksPage([a, b]),
      ]),
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await bloc.close();
        access.current = allButUpdate;
        await pumpEventQueue();
      },
      expect: () => [
        const LanguageLinkListLoading(LanguageLinkFilter.waiting),
        ready([a, b]),
      ],
    );
  });

  group('the outcome', () {
    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'dismissing the outcome clears it',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(a);
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, dismiss);
      },
      skip: 4,
      expect: () => [
        ready([b]),
      ],
    );

    blocTest<LanguageLinkListBloc, LanguageLinkListState>(
      'an action keeps the last outcome until it answers',
      setUp: () {
        reads([
          linksPage([a, b]),
        ]);
        remote.onIgnoreLanguageLink = (_, id) => id == 'a'
            ? Future.value(ignoredOf(a))
            : Completer<LanguageLink>().future;
      },
      build: build,
      act: (bloc) async {
        await send(bloc, load);
        await send(bloc, ignore('a'));
        await send(bloc, ignore('b'));
      },
      skip: 4,
      expect: () => [
        ready(
          [b],
          busy: {'b'},
          outcome: LanguageLinkOutcome(
            kind: LanguageLinkOutcomeKind.ignored,
            value: a.value,
            format: a.format,
          ),
        ),
      ],
    );
  });
}
