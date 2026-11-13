import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

/// Answers every list read with [read], every row read with a DataGateway named
/// after its id, and every read of a row's language links with none; nothing
/// else is called here.
class _ListingRemote implements DataGatewayRemoteDataSource {
  _ListingRemote(this.read);

  Future<PaginatedResult<DataGateway>> Function() read;

  /// Thrown by every read of a row or of its language links, when set: a user
  /// who may not read a DataGateway may not read its links either.
  Exception? fetchOneError;

  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) => read();

  @override
  Future<DataGateway> fetchOne(String id) async {
    if (fetchOneError case final error?) throw error;
    return _named(id);
  }

  @override
  Future<PaginatedResult<LanguageLink>> fetchLanguageLinks(
    String id, {
    Set<LanguageLinkStatus>? statuses,
    int page = 1,
    int limit = DataGatewayRemoteDataSource.languageLinkPageSize,
  }) async {
    if (fetchOneError case final error?) throw error;
    return PaginatedResult(
      items: const [],
      meta: PaginationMeta(
        page: page,
        limit: limit,
        total: 0,
        totalPages: 0,
        hasMore: false,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

DataGateway _named(String id) => DataGateway(
  id: id,
  name: 'Named $id',
  connectionUrl: 'bgg.internal',
  connectionPort: 50051,
  enabled: true,
  authType: DataGatewayAuthType.none,
);

PaginatedResult<DataGateway> _empty() => const PaginatedResult(
  items: [],
  meta: PaginationMeta(
    page: 1,
    limit: 100,
    total: 0,
    totalPages: 0,
    hasMore: false,
  ),
);

PaginatedResult<DataGateway> _listing(List<DataGateway> rows) =>
    PaginatedResult(
      items: rows,
      meta: PaginationMeta(
        page: 1,
        limit: 100,
        total: rows.length,
        totalPages: 1,
        hasMore: false,
      ),
    );

const _forbidden = DataGatewayForbiddenException('refused', statusCode: 403);

/// The Admin entry in the home drawer, and the deep link past it (#41).
///
/// With only the DataGateway section to show, the entry shows while the
/// session's access reads every DataGateway (#456, #684), and opens the admin
/// dashboard. While the answer is unknown, and where it says less, there is no
/// entry; a deep link still reaches the screen, which then says they have no
/// access.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _ListingRemote remote;
  late FakeCallerAccessRepository access;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    remote = _ListingRemote(() async => _empty());
    access = FakeCallerAccessRepository();
  });

  Future<void> pumpHome(WidgetTester tester, {bool withAccess = true}) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: testAuthResponse()),
          dataGatewayRemoteDataSource: remote,
          callerAccess: withAccess ? access : null,
        ),
      ),
    );
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  final adminEntry = find.byKey(MenuDrawer.entryKey('admin'));

  group('the Admin entry (#41, #456)', () {
    testWidgets('shows on read, labelled Admin', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsOneWidget);
      expect(
        find.descendant(of: adminEntry, matching: find.text('Admin')),
        findsOneWidget,
      );
    });

    testWidgets('stays hidden while access is unknown', (tester) async {
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);
      expect(find.byKey(MenuDrawer.entryKey('settings')), findsOneWidget);
    });

    testWidgets('stays hidden while read is none, whatever else is allowed', (
      tester,
    ) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
        update: AccessExtent.all,
        delete: AccessExtent.all,
      );
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);
      expect(find.byKey(MenuDrawer.entryKey('settings')), findsOneWidget);
    });

    testWidgets('appears when access arrives', (tester) async {
      // A sign-up: home is up before the first answer lands.
      await pumpHome(tester);
      await openDrawer(tester);
      expect(adminEntry, findsNothing);

      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(adminEntry, findsOneWidget);
    });

    testWidgets('stays hidden in a session with no access to ask', (
      tester,
    ) async {
      await pumpHome(tester, withAccess: false);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);
    });

    group('focus when read falls with the drawer open', () {
      void focusEntry(WidgetTester tester, String id) {
        final label = find.descendant(
          of: find.byKey(MenuDrawer.entryKey(id)),
          matching: find.byType(Text),
        );
        Focus.of(tester.element(label.first)).requestFocus();
      }

      bool inEntry(String id) {
        var found = false;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          element,
        ) {
          found = element.widget.key == MenuDrawer.entryKey(id);
          return !found;
        });
        return found;
      }

      testWidgets('focus on the Admin entry goes to Settings, which takes its '
          'place', (tester) async {
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
        await pumpHome(tester);
        await openDrawer(tester);
        focusEntry(tester, 'admin');
        await tester.pump();
        expect(inEntry('admin'), isTrue);

        access.current = FakeCallerAccessRepository.dataGateway();
        await tester.pumpAndSettle();

        expect(adminEntry, findsNothing);
        expect(
          FocusManager.instance.primaryFocus,
          isNot(isA<FocusScopeNode>()),
        );
        expect(inEntry('settings'), isTrue);
      });

      testWidgets('focus on another entry is left alone', (tester) async {
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
        );
        await pumpHome(tester);
        await openDrawer(tester);
        focusEntry(tester, 'send_feedback');
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus;

        access.current = FakeCallerAccessRepository.dataGateway();
        await tester.pumpAndSettle();

        expect(adminEntry, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(focused));
      });
    });

    testWidgets('stays hidden while DataGateway read is some', (tester) async {
      // Read on some DataGateways is not the whole server's (#274, #684).
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.some,
      );
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);
      expect(find.byKey(MenuDrawer.entryKey('settings')), findsOneWidget);
    });

    testWidgets('opens the admin dashboard, whose DataGateway entry opens the '
        'list', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await pumpHome(tester);
      await openDrawer(tester);

      await tester.tap(adminEntry);
      await tester.pumpAndSettle();

      expect(find.byType(AdminDashboardScreen), findsOneWidget);
      final entry = find.byKey(AdminDashboardScreen.entryKey('data_gateways'));
      expect(
        find.descendant(of: entry, matching: find.text('Data gateways')),
        findsOneWidget,
      );

      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byType(DataGatewayListScreen), findsOneWidget);
      expect(find.text('No data gateways yet'), findsOneWidget);

      // Leaving the list is a pop back to the dashboard.
      GoRouter.of(tester.element(find.byType(DataGatewayListScreen))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(DataGatewayListScreen), findsNothing);
      expect(entry, findsOneWidget);
    });
  });

  testWidgets('a deep link by a user who may not read shows access-denied, '
      "and asks the session's access again (#41, #456)", (tester) async {
    remote.read = () async => throw _forbidden;
    // Known, so the admin dashboard the link builds beneath the list (#684)
    // has nothing to ask: the one ask is the list's.
    access.current = FakeCallerAccessRepository.dataGateway();
    await pumpHome(tester);

    GoRouter.of(tester.element(find.byType(HomeScreen)))
        .go(AppRoutes.adminDataGateways);
    await tester.pumpAndSettle();

    expect(find.text("You don't have access to data gateways"), findsOneWidget);
    expect(access.refreshCount, 1);
  });

  testWidgets('the list beneath a deep-linked form reads itself again when '
      'the form is left (#41)', (tester) async {
    var reads = 0;
    remote.read = () async {
      reads++;
      return _empty();
    };
    access.current = FakeCallerAccessRepository.dataGateway(
      read: AccessExtent.all,
    );
    await pumpHome(tester);

    GoRouter.of(tester.element(find.byType(HomeScreen)))
        .go(AppRoutes.dataGatewayAdd);
    await tester.pumpAndSettle();
    expect(find.byType(DataGatewayFormScreen), findsOneWidget);
    final readsBeneathTheForm = reads;

    GoRouter.of(tester.element(find.byType(DataGatewayFormScreen))).pop();
    await tester.pumpAndSettle();

    expect(find.text('No data gateways yet'), findsOneWidget);
    expect(reads, readsBeneathTheForm + 1);
  });

  testWidgets('going from one edit form straight to another edits the second '
      '(#41)', (tester) async {
    access.current = FakeCallerAccessRepository.dataGateway(
      read: AccessExtent.all,
    );
    await pumpHome(tester);
    final router = GoRouter.of(tester.element(find.byType(HomeScreen)))
      ..go(AppRoutes.dataGatewayEditOf('dg_a'));
    await tester.pumpAndSettle();
    expect(find.text('Named dg_a'), findsOneWidget);

    // go_router keys a page by its path pattern, so this reuses the screen.
    router.go(AppRoutes.dataGatewayEditOf('dg_b'));
    await tester.pumpAndSettle();

    expect(find.text('Named dg_b'), findsOneWidget);
    expect(find.text('Named dg_a'), findsNothing);
  });

  group('one DataGateway at its own location (#457)', () {
    testWidgets('tapping a list row reaches the detail screen for that id', (
      tester,
    ) async {
      remote.read = () async => _listing([_named('dg_a'), _named('dg_b')]);
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await pumpHome(tester);
      GoRouter.of(tester.element(find.byType(HomeScreen)))
          .go(AppRoutes.adminDataGateways);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Named dg_b'));
      await tester.pumpAndSettle();

      final screen = find.byType(DataGatewayDetailScreen);
      expect(tester.widget<DataGatewayDetailScreen>(screen).id, 'dg_b');
      // The name heads the page as well as its app bar.
      expect(
        tester.widget<Text>(find.byKey(DataGatewayDetailScreen.nameKey)).data,
        'Named dg_b',
      );
    });

    testWidgets('leaving the detail is a pop back to the list, which reads '
        'itself again', (tester) async {
      var reads = 0;
      remote.read = () async {
        reads++;
        return _listing([_named('dg_a')]);
      };
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await pumpHome(tester);
      GoRouter.of(tester.element(find.byType(HomeScreen)))
          .go(AppRoutes.dataGatewayDetailOf('dg_a'));
      await tester.pumpAndSettle();
      expect(find.byType(DataGatewayDetailScreen), findsOneWidget);
      final readsBeneathTheDetail = reads;

      GoRouter.of(tester.element(find.byType(DataGatewayDetailScreen))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(DataGatewayDetailScreen), findsNothing);
      expect(find.byType(DataGatewayListScreen), findsOneWidget);
      expect(reads, readsBeneathTheDetail + 1);
    });

    testWidgets('going from one detail straight to another shows the second', (
      tester,
    ) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await pumpHome(tester);
      final router = GoRouter.of(tester.element(find.byType(HomeScreen)));

      String? heading() =>
          tester.widget<Text>(find.byKey(DataGatewayDetailScreen.nameKey)).data;

      router.go(AppRoutes.dataGatewayDetailOf('dg_a'));
      await tester.pumpAndSettle();
      expect(heading(), 'Named dg_a');

      // go_router keys a page by its path pattern, so this reuses the screen.
      router.go(AppRoutes.dataGatewayDetailOf('dg_b'));
      await tester.pumpAndSettle();

      expect(heading(), 'Named dg_b');
      expect(find.text('Named dg_a'), findsNothing);
    });

    testWidgets('a deep link by a user who may not read shows access-denied, '
        "and asks the session's access again (#456)", (tester) async {
      remote
        ..read = (() async => throw _forbidden)
        ..fetchOneError = _forbidden;
      await pumpHome(tester);

      GoRouter.of(tester.element(find.byType(HomeScreen)))
          .go(AppRoutes.dataGatewayDetailOf('dg_a'));
      await tester.pumpAndSettle();

      final detail = find.byType(DataGatewayDetailScreen);
      expect(find.byKey(DataGatewayDetailScreen.deniedKey), findsOneWidget);
      // The page asks the session's own access. How many refusals ask it
      // again depends on what the route builds beneath the page as well.
      expect(
        tester.widget<DataGatewayDetailScreen>(detail).access,
        same(access),
      );
      expect(access.refreshCount, isPositive);
    });

    testWidgets('a session with no DataGateway client falls back', (
      tester,
    ) async {
      when(() => cubit.activeServerScope).thenReturn(
        FakeActiveServerScope(
          buildActiveServer(
            FakeAuthRepository(initialSession: testAuthResponse()),
          ),
        ),
      );
      whenListen(
        cubit,
        const Stream<AppBootstrapState>.empty(),
        initialState: const AppBootstrapReady(),
      );
      await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
      await tester.pumpAndSettle();

      GoRouter.of(tester.element(find.byType(HomeScreen)))
          .go(AppRoutes.dataGatewayDetailOf('dg_a'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });
}
