import 'dart:async';

import 'package:app_shell/app_shell.dart';
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

/// Answers every list read with [read]; nothing else is called here.
class _ListingRemote implements DataGatewayRemoteDataSource {
  _ListingRemote(this.read);

  Future<PaginatedResult<DataGateway>> Function() read;

  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) => read();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

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

const _forbidden = DataGatewayForbiddenException('refused', statusCode: 403);

/// The Admin entry in the home drawer, and the deep link past it (#41).
///
/// The entry shows only once the session's one-row read of DataGateways has
/// succeeded. A user whose read was refused, or whose read has not answered
/// yet, sees no entry; a deep link still reaches the screen, which then says
/// they have no access.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _ListingRemote remote;
  late DataGatewayAccess access;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    remote = _ListingRemote(() async => _empty());
    access = DataGatewayAccess(remote: remote);
  });

  tearDown(() => access.dispose());

  Future<void> pumpHome(WidgetTester tester, {bool withAccess = true}) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          dataGatewayRemoteDataSource: remote,
          dataGatewayAccess: withAccess ? access : null,
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

  group('the Admin entry (#41)', () {
    testWidgets('shows once the read succeeded, labelled Admin', (
      tester,
    ) async {
      access.readGranted();
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsOneWidget);
      expect(
        find.descendant(of: adminEntry, matching: find.text('Admin')),
        findsOneWidget,
      );
    });

    testWidgets('stays hidden when the read was refused', (tester) async {
      access.readDenied();
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);
      expect(find.byKey(HomeScreen.entryKey('settings')), findsOneWidget);
    });

    testWidgets('stays hidden until the read answers, then appears', (
      tester,
    ) async {
      final pending = Completer<PaginatedResult<DataGateway>>();
      remote.read = () => pending.future;
      unawaited(access.check());
      await pumpHome(tester);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);

      pending.complete(_empty());
      await tester.pumpAndSettle();

      expect(adminEntry, findsOneWidget);
    });

    testWidgets('stays hidden in a session with no access check', (
      tester,
    ) async {
      await pumpHome(tester, withAccess: false);
      await openDrawer(tester);

      expect(adminEntry, findsNothing);
    });

    testWidgets('opens the DataGateway list', (tester) async {
      access.readGranted();
      await pumpHome(tester);
      await openDrawer(tester);

      await tester.tap(adminEntry);
      await tester.pumpAndSettle();

      expect(find.text('Data gateways'), findsOneWidget);
      expect(find.text('No data gateways yet'), findsOneWidget);
    });
  });

  testWidgets('a deep link by a user who may not read shows access-denied, '
      'and the entry stays hidden (#41)', (tester) async {
    remote.read = () async => throw _forbidden;
    await pumpHome(tester);

    GoRouter.of(tester.element(find.byType(HomeScreen)))
        .go(AppRoutes.adminDataGateways);
    await tester.pumpAndSettle();

    expect(find.text("You don't have access to data gateways"), findsOneWidget);
    expect(access.value.read, DataGatewayRead.denied);
  });
}
