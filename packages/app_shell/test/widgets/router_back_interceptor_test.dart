import 'package:app_shell/src/widgets/router_back_interceptor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;

  /// A root dispatcher with a stand-in for the Router's own registration:
  /// `deferTo` asserts `hasCallbacks`, which in the app is the Router.
  (RootBackButtonDispatcher, String) rootDispatcher(String name) {
    final dispatcher = RootBackButtonDispatcher();
    Future<bool> router() async {
      calls.add('router $name popped');
      return false;
    }

    dispatcher.addCallback(router);
    addTearDown(() => dispatcher.removeCallback(router));
    return (dispatcher, 'router $name popped');
  }

  Widget host(BackButtonDispatcher? dispatcher) => Directionality(
    textDirection: TextDirection.ltr,
    child: RouterBackInterceptor(
      dispatcher: dispatcher,
      onBack: () async {
        calls.add('onBack');
        return true;
      },
    ),
  );

  Future<bool> press(BackButtonDispatcher dispatcher) =>
      dispatcher.invokeCallback(Future.value(false));

  setUp(() => calls = []);

  testWidgets('a null dispatcher stays inert, and a swap to or from one '
      'attaches or detaches', (tester) async {
    final (a, routerA) = rootDispatcher('A');

    await tester.pumpWidget(host(null));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(host(a));
    final handled = await press(a);
    expect(handled, isTrue);
    expect(calls, ['onBack'], reason: 'the swap from null attached');

    await tester.pumpWidget(host(null));
    await press(a);
    expect(calls, [
      'onBack',
      routerA,
    ], reason: 'the swap to null detached, so onBack ran once');
  });

  testWidgets('swapping the dispatcher moves the interception to the new one', (
    tester,
  ) async {
    final (a, routerA) = rootDispatcher('A');
    final (b, routerB) = rootDispatcher('B');

    await tester.pumpWidget(host(a));
    await tester.pumpWidget(host(b));

    await press(a);
    expect(calls, [routerA], reason: 'a no longer intercepted');

    calls.clear();
    final handled = await press(b);
    expect(handled, isTrue);
    expect(calls, ['onBack']);
    expect(calls, isNot(contains(routerB)));
  });

  testWidgets('disposing detaches, so back reaches the router again', (
    tester,
  ) async {
    final (a, routerA) = rootDispatcher('A');

    await tester.pumpWidget(host(a));
    await tester.pumpWidget(const SizedBox());

    await press(a);
    expect(calls, [routerA]);
  });
}
