import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

/// What happens to the `Router` on frame two, when `BgeApp._selectable`
/// may first mount the selection region.
///
/// On a platform with no region, nothing happens: the platform gate is
/// checked before readiness, so the slot above the router holds the same
/// widget on frame one and frame two.
///
/// On a platform with one, the region mounts above the router, and the
/// router's slot GlobalKey moves the router under it with its State. A new
/// State lost a bootstrap change made in that same frame, and the app stayed
/// on the splash screen; the desktop cases pin the State and that outcome.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapFailed(
        error: 'boom',
        attemptCount: 1,
        canOfferReset: false,
      ),
    );
  });

  /// All four themes, as `bge_app_selection_test.dart` does: `BgeApp`
  /// asserts they agree on `platform`.
  Future<void> pumpApp(WidgetTester tester, TargetPlatform platform) =>
      tester.pumpWidget(
        BgeApp(
          bootstrapCubit: cubit,
          theme: BgeTheme.light().copyWith(platform: platform),
          darkTheme: BgeTheme.dark().copyWith(platform: platform),
          highContrastTheme: BgeTheme.highContrastLight().copyWith(
            platform: platform,
          ),
          highContrastDarkTheme: BgeTheme.highContrastDark().copyWith(
            platform: platform,
          ),
          themeMode: ThemeMode.light,
        ),
      );

  /// The `Router`'s State, not the Navigator's. go_router gives its root
  /// Navigator a GlobalKey, so a remount above it reparents the Navigator
  /// and keeps its State; nothing keeps the Router's.
  State routerState(WidgetTester tester) =>
      tester.state(find.byWidgetPredicate((w) => w is Router));

  group('BgeApp selection gate (#322)', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      testWidgets('$platform keeps the router mounted through frame two', (
        tester,
      ) async {
        await pumpApp(tester, platform);
        final router = routerState(tester);

        // Frame two: the readiness flag flips and the builder runs again.
        await tester.pump();

        expect(routerState(tester), same(router));
        expect(find.byType(BgeSelectionRegion), findsNothing);
      });
    }

    // Where the region does mount on frame two, the router moves under it
    // and keeps its State. A new State would restore the location the old
    // one last reported, so a bootstrap move made in that same frame was
    // lost and the app stayed on the splash screen.
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('$platform keeps the router mounted as the region mounts', (
        tester,
      ) async {
        await pumpApp(tester, platform);
        final router = routerState(tester);
        expect(find.byType(BgeSelectionRegion), findsNothing);

        await tester.pump();

        expect(find.byType(BgeSelectionRegion), findsOneWidget);
        expect(routerState(tester), same(router));
      });

      testWidgets('$platform follows a bootstrap change made as the region '
          'mounts', (tester) async {
        // A controller, not `Stream.fromIterable`: the state has to change
        // in frame two, not before the first redirect.
        final states = StreamController<AppBootstrapState>();
        addTearDown(states.close);
        whenListen(
          cubit,
          states.stream,
          initialState: const AppBootstrapInitializing(),
        );
        await pumpApp(tester, platform);
        expect(find.byType(SplashScreen), findsOneWidget);

        // Delivered in the pump that mounts the region.
        states.add(
          const AppBootstrapFailed(
            error: 'boom',
            attemptCount: 1,
            canOfferReset: false,
          ),
        );
        await tester.pump();
        expect(find.byType(BgeSelectionRegion), findsOneWidget);
        // The splash has a spinner, so pump frames rather than settle.
        await tester.pump();
        await tester.pump();

        expect(find.byType(BootstrapErrorScreen), findsOneWidget);
        expect(find.byType(SplashScreen), findsNothing);
      });
    }
  });
}
