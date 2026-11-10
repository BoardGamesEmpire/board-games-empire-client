import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

/// Registered so the DataGateway section is offered; nothing here reads it.
class _DataGateways implements DataGatewayRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Answers every list read with [rows] on one page, and every detail read
/// with a household named after its id; restores are not made here.
class _AdminHouseholds implements AdminHouseholdRemoteDataSource {
  List<AdminHouseholdRow> rows = const [];

  /// Thrown by every read, when set.
  Object? error;

  /// The ids whose detail was read, in order.
  final List<String> detailsRead = [];

  @override
  Future<PaginatedResult<AdminHouseholdRow>> fetchPage({
    AdminHouseholdStatus status = AdminHouseholdStatus.live,
    String? query,
    AdminHouseholdSort sort = AdminHouseholdSort.name,
    int page = 1,
    int limit = AdminHouseholdRemoteDataSource.pageSize,
  }) async {
    if (error case final error?) throw error;
    return PaginatedResult(
      items: rows,
      meta: PaginationMeta(
        page: page,
        limit: limit,
        total: rows.length,
        totalPages: 1,
        hasMore: false,
      ),
    );
  }

  @override
  Future<AdminHouseholdDetail> fetchDetail(String id) async {
    if (error case final error?) throw error;
    detailsRead.add(id);
    return AdminHouseholdDetail(
      id: id,
      name: 'Detail of $id',
      reach: Reach.private,
      createdAt: DateTime.utc(2026),
      members: const [],
    );
  }

  @override
  Future<void> restore(String id) => throw UnimplementedError('restore');
}

AdminHouseholdRow _live(String id, String name) => AdminHouseholdRow(
  id: id,
  name: name,
  reach: Reach.private,
  createdAt: DateTime.utc(2026),
  memberCount: 2,
  owners: const [],
);

const _refused = AdminHouseholdForbiddenException('refused', statusCode: 403);

/// The admin dashboard as the composition builds it (#684): the drawer entry
/// shows when any section does, each section is offered where the active
/// server registers its client, and the staff households section (#685)
/// opens beneath it.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _AdminHouseholds households;
  late FakeCallerAccessRepository access;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    households = _AdminHouseholds();
    access = FakeCallerAccessRepository();
  });

  /// Home on a server whose access reads DataGateways and households as
  /// given, with both sections' clients unless one is left out.
  Future<void> pumpHome(
    WidgetTester tester, {
    AccessExtent gateways = AccessExtent.none,
    AccessExtent householdsRead = AccessExtent.none,
    bool withHouseholdsClient = true,
  }) async {
    access.current = FakeCallerAccessRepository.of({
      ResourceType.dataGateway: gateways,
      ResourceType.household: householdsRead,
    });
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          dataGatewayRemoteDataSource: _DataGateways(),
          adminHouseholdRemoteDataSource: withHouseholdsClient
              ? households
              : null,
          callerAccess: access,
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

  final adminEntry = find.byKey(HomeScreen.entryKey('admin'));
  final gatewaysSection = find.byKey(
    AdminDashboardScreen.entryKey('data_gateways'),
  );
  final householdsSection = find.byKey(
    AdminDashboardScreen.entryKey('households'),
  );

  Future<void> openDashboard(WidgetTester tester) async {
    await openDrawer(tester);
    await tester.tap(adminEntry);
    await tester.pumpAndSettle();
    expect(find.byType(AdminDashboardScreen), findsOneWidget);
  }

  testWidgets('households read all alone shows the entry, and the dashboard '
      'lists only Households', (tester) async {
    await pumpHome(tester, householdsRead: AccessExtent.all);

    await openDashboard(tester);

    expect(householdsSection, findsOneWidget);
    expect(
      find.descendant(of: householdsSection, matching: find.text('Households')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: householdsSection,
        matching: find.text('Every household on the server, deleted ones too'),
      ),
      findsOneWidget,
    );
    expect(gatewaysSection, findsNothing);
  });

  testWidgets('both all lists both, DataGateways first', (tester) async {
    await pumpHome(
      tester,
      gateways: AccessExtent.all,
      householdsRead: AccessExtent.all,
    );

    await openDashboard(tester);

    expect(gatewaysSection, findsOneWidget);
    expect(
      find.descendant(
        of: gatewaysSection,
        matching: find.text('Where the server finds its games'),
      ),
      findsOneWidget,
    );
    expect(householdsSection, findsOneWidget);
    expect(
      tester.getTopLeft(gatewaysSection).dy,
      lessThan(tester.getTopLeft(householdsSection).dy),
    );
  });

  testWidgets('households read some (a plain member) shows no entry', (
    tester,
  ) async {
    await pumpHome(tester, householdsRead: AccessExtent.some);
    await openDrawer(tester);

    expect(adminEntry, findsNothing);
    expect(find.byKey(HomeScreen.entryKey('settings')), findsOneWidget);
  });

  testWidgets('the households entry opens the list, and a live row opens its '
      'detail', (tester) async {
    households.rows = [_live('h_1', "Ada's table")];
    await pumpHome(tester, householdsRead: AccessExtent.all);
    await openDashboard(tester);

    await tester.tap(householdsSection);
    await tester.pumpAndSettle();

    expect(find.byType(AdminHouseholdListScreen), findsOneWidget);
    expect(find.byKey(AdminHouseholdListScreen.rowKey('h_1')), findsOneWidget);

    await tester.tap(find.text("Ada's table"));
    await tester.pumpAndSettle();

    final detail = find.byType(AdminHouseholdDetailScreen);
    expect(tester.widget<AdminHouseholdDetailScreen>(detail).id, 'h_1');
    expect(
      tester.widget<AdminHouseholdDetailScreen>(detail).access,
      same(access),
    );
    expect(households.detailsRead, ['h_1']);
    expect(find.text('Detail of h_1'), findsWidgets);

    // Leaving the detail is a pop back to the list.
    GoRouter.of(tester.element(detail)).pop();
    await tester.pumpAndSettle();

    expect(find.byType(AdminHouseholdDetailScreen), findsNothing);
    expect(find.byKey(AdminHouseholdListScreen.rowKey('h_1')), findsOneWidget);
  });

  testWidgets('a deep link to /admin/households by a user the server refuses '
      'shows the refused state and asks access again', (tester) async {
    households.error = _refused;
    // A plain member: no entry leads here, but the route isn't gated on the
    // answer, so the list says why.
    await pumpHome(tester, householdsRead: AccessExtent.some);

    GoRouter.of(tester.element(find.byType(HomeScreen)))
        .go(AppRoutes.adminHouseholds);
    await tester.pumpAndSettle();

    expect(find.byKey(AdminHouseholdListScreen.refusedKey), findsOneWidget);
    expect(
      tester
          .widget<AdminHouseholdListScreen>(
            find.byType(AdminHouseholdListScreen),
          )
          .access,
      same(access),
    );
    // The dashboard beneath has a known answer, so only the list asked.
    expect(access.refreshCount, 1);
  });

  testWidgets('a session with no admin households client leaves the section '
      'out', (tester) async {
    await pumpHome(
      tester,
      gateways: AccessExtent.all,
      householdsRead: AccessExtent.all,
      withHouseholdsClient: false,
    );

    await openDashboard(tester);

    expect(gatewaysSection, findsOneWidget);
    expect(householdsSection, findsNothing);

    // Nor is the section's own route built.
    GoRouter.of(tester.element(find.byType(AdminDashboardScreen)))
        .go(AppRoutes.adminHouseholds);
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });
}
