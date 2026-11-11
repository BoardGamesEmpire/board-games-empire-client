import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// `BgeApp._selectable` checks the platform gate before it checks whether
/// the region may mount yet. So on a platform with no region, the slot
/// above the router holds the same widget on frame one and frame two, and
/// the frame that would have mounted the region remounts nothing.
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
  });
}
