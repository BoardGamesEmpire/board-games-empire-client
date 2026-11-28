import 'package:app_shell/src/notifications/shell_notifications_bell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/notifications.dart';
import 'package:ui/ui.dart' show BgeNavigationMenu, BgePage, BgeTopLevelRoute;

/// A server whose unread count is [unread]. Nothing here reads a page.
class _Notifications implements NotificationRemoteDataSource {
  _Notifications(this.unread);

  final int unread;

  @override
  Future<int> fetchUnreadCount() async => unread;

  @override
  Future<NotificationPage> fetchPage({
    String? cursor,
    int limit = NotificationRemoteDataSource.defaultPageSize,
  }) => throw UnimplementedError();

  @override
  Future<List<UnreadNotification>> fetchUnread() => throw UnimplementedError();

  @override
  Future<void> markAllRead() => throw UnimplementedError();

  @override
  Future<void> markRead(List<String> ids) => throw UnimplementedError();
}

Future<void> _openNothing(BuildContext context, NotificationTarget target) =>
    Future.value();

final Finder _bell = find.byKey(NotificationsBell.buttonKey);

Finder _badge(String text) =>
    find.descendant(of: _bell, matching: find.text(text));

/// The app shell's bell (#475): which pages show it, and whose count.
void main() {
  /// A session's count, read once from a server holding [unread].
  Future<NotificationCountCubit> countOf(int unread) async {
    final cubit = NotificationCountCubit(_Notifications(unread));
    addTearDown(cubit.close);
    await cubit.refresh();
    return cubit;
  }

  const bell = ShellNotificationsBell(
    remote: _NoRemote(),
    onOpen: _openNothing,
  );

  /// The page the bell's header is on. Under a global key, as the shell's
  /// navigator is, so a host that comes, goes or changes moves the page
  /// rather than building it again.
  final page = GlobalKey();

  /// The app with the bell's page under [count]'s host, keyed by the count
  /// as `BgeApp` keys its host by the session, or under no host at all.
  Widget app({NotificationCountCubit? count}) {
    final content = KeyedSubtree(
      key: page,
      child: Scaffold(appBar: AppBar(actions: const [bell])),
    );
    return MaterialApp(
      localizationsDelegates: NotificationsLocalizations.localizationsDelegates,
      supportedLocales: NotificationsLocalizations.supportedLocales,
      home: count == null
          ? Center(child: content)
          : BlocProvider<NotificationCountCubit>.value(
              key: ObjectKey(count),
              value: count,
              child: content,
            ),
    );
  }

  testWidgets("shows the session's count", (tester) async {
    final count = await countOf(3);
    await tester.pumpWidget(app(count: count));

    expect(_bell, findsOneWidget);
    expect(_badge('3'), findsOneWidget);
  });

  testWidgets('with no count above it, as while one session hands over to '
      'the next, draws nothing', (tester) async {
    await tester.pumpWidget(app());

    expect(find.byType(ShellNotificationsBell), findsOneWidget);
    expect(_bell, findsNothing);
  });

  testWidgets("a page carried to the next session's host shows that "
      "session's count", (tester) async {
    final first = await countOf(3);
    final second = await countOf(7);
    await tester.pumpWidget(app(count: first));
    expect(_badge('3'), findsOneWidget);
    final element = tester.element(find.byType(ShellNotificationsBell));

    await tester.pumpWidget(app(count: second));

    // The same page, moved, not built again.
    expect(tester.element(find.byType(ShellNotificationsBell)), same(element));
    expect(_badge('7'), findsOneWidget);
    expect(_badge('3'), findsNothing);
  });

  testWidgets('a page carried out from under its host takes the bell away, '
      'and back under one brings it again', (tester) async {
    final first = await countOf(3);
    final second = await countOf(7);
    await tester.pumpWidget(app(count: first));

    await tester.pumpWidget(app());
    expect(tester.takeException(), isNull);
    expect(_bell, findsNothing);

    await tester.pumpWidget(app(count: second));
    expect(_badge('7'), findsOneWidget);
  });

  /// A section-top screen with the bell last in its header, as Games is.
  Widget games({bool topLevel = true}) {
    const page = BgePage(
      title: Text('Games'),
      actions: [bell],
      child: SizedBox.shrink(),
    );
    return topLevel ? const BgeTopLevelRoute(child: page) : page;
  }

  /// Boots [count]'s session at home, under a shell whose menu says whether
  /// [browserOwnsBack], and pushes [pushed] over home.
  Future<NavigatorState> pushOverHome(
    WidgetTester tester,
    NotificationCountCubit count, {
    required bool browserOwnsBack,
    required Widget pushed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates:
            NotificationsLocalizations.localizationsDelegates,
        supportedLocales: NotificationsLocalizations.supportedLocales,
        builder: (context, child) => BlocProvider.value(
          value: count,
          child: BgeNavigationMenu(
            onOpen: () {},
            browserOwnsBack: browserOwnsBack,
            child: child!,
          ),
        ),
        home: games(),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator))
      ..push(MaterialPageRoute<void>(builder: (_) => pushed));
    await tester.pumpAndSettle();
    return navigator;
  }

  testWidgets('a section-top screen pushed over another page has a back '
      'button and no bell; the page beneath, first on its navigator, has '
      'both its menu button and the bell', (tester) async {
    final count = await countOf(3);
    final navigator = await pushOverHome(
      tester,
      count,
      browserOwnsBack: false,
      pushed: games(),
    );

    expect(find.byType(BackButton), findsOneWidget);
    expect(_bell, findsNothing);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(BgePage.menuButtonKey), findsOneWidget);
    expect(_badge('3'), findsOneWidget);
  });

  testWidgets('where the browser owns Back, a section-top screen pushed over '
      'another page keeps its menu button and the bell', (tester) async {
    final count = await countOf(3);
    await pushOverHome(
      tester,
      count,
      browserOwnsBack: true,
      pushed: games(),
    );

    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(BgePage.menuButtonKey), findsOneWidget);
    expect(_badge('3'), findsOneWidget);
  });

  testWidgets('where the browser owns Back, a page under a section shows no '
      'bell', (tester) async {
    final count = await countOf(3);
    await pushOverHome(
      tester,
      count,
      browserOwnsBack: true,
      pushed: games(topLevel: false),
    );

    expect(find.byKey(BgePage.menuButtonKey), findsNothing);
    expect(_bell, findsNothing);
  });
}

/// A remote nothing reads from: the preview is not opened here.
class _NoRemote implements NotificationRemoteDataSource {
  const _NoRemote();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
