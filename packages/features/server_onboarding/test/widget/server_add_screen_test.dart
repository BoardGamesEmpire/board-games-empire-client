import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_onboarding/server_onboarding.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/server_onboarding_bloc_double.dart';

/// Covers what [ServerAddScreen] itself contributes — the heading, the
/// introduction, and hosting the form.
///
/// The form's behaviour is [ServerAddForm]'s, and lives in
/// `server_add_form_test.dart`. This suite used to assert it too, through
/// the screen: field labels, submit dispatch, the keyboard done action, the
/// in-flight button and the failure banner. Two suites pinning one
/// behaviour is not two safety nets — it is one behaviour that costs two
/// edits to change, and a green screen suite that says nothing about
/// whether the screen is doing its own job.
void main() {
  late MockServerOnboardingBloc bloc;

  setUpAll(registerServerOnboardingFallbacks);

  setUp(() {
    bloc = MockServerOnboardingBloc();
    stubState(bloc, const ServerOnboardingIdle());
  });

  Widget harness({ThemeData? theme, TransitionBuilder? builder}) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    builder: builder,
    localizationsDelegates:
        ServerOnboardingLocalizations.localizationsDelegates,
    supportedLocales: ServerOnboardingLocalizations.supportedLocales,
    home: BlocProvider<ServerOnboardingBloc>.value(
      value: bloc,
      child: const ServerAddScreen(),
    ),
  );

  group('ServerAddScreen', () {
    testWidgets('presents the title as a semantic header', (tester) async {
      // The binding reports semantics already enabled without this, so the
      // assertion below does run — but it would then depend on a default
      // this test never asked for, and a change to it reads as a failure
      // here rather than as a missing handle.
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(harness());

      expect(find.text('Add a Server'), findsOneWidget);
      // A heading, not merely large text: it is what lets a screen reader
      // user jump to the top of this screen by heading navigation.
      expect(
        tester.getSemantics(find.text('Add a Server')),
        isSemantics(isHeader: true),
      );

      handle.dispose();
    });

    testWidgets('explains what the address is for before asking for it', (
      tester,
    ) async {
      await tester.pumpWidget(harness());

      expect(
        find.text(
          'Enter the address of your Board Games Empire server to get '
          'started.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('hosts the add-server form', (tester) async {
      await tester.pumpWidget(harness());

      expect(find.byType(ServerAddForm), findsOneWidget);
    });

    testWidgets('a failure banner whose slot is below the fold is scrolled up '
        'into view', (tester) async {
      // Server-add is the screen where this direction is reachable (#209): the
      // banner sits between the fields and the submit button, and the alias
      // field submits on the keyboard's done action
      // (`server_add_form.dart:141`), so a user can submit without ever
      // scrolling to the button — leaving the banner's slot entirely BELOW the
      // viewport. That is the direction a `keepVisibleAtStart` reveal would
      // silently ignore.
      //
      // That submit path is [ServerAddForm]'s and is pinned in
      // `server_add_form_test.dart`; driving it here would put one behaviour
      // in two suites, which is what this file's header rejects. So the
      // failure state is injected and the assertion is the geometry — the part
      // the screen contributes.
      useViewSize(tester, const Size(320, 400));

      // A controller so the failure lands after the form is submitted, rather
      // than being the state the screen was born in.
      final states = StreamController<ServerOnboardingState>();
      addTearDown(states.close);
      whenListen(
        bloc,
        states.stream,
        initialState: const ServerOnboardingIdle(),
      );

      await tester.pumpWidget(
        MediaQuery(
          // Above MaterialApp: `MediaQuery.fromView` comes from `View`, higher
          // still, so the nearest one below it wins.
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: harness(),
        ),
      );
      await tester.pumpAndSettle();

      // `.first` is the page's own scroll view: each BgeTextField brings its
      // own Scrollable, so a bare byType matches several.
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(
        scroll.position.pixels,
        0,
        reason:
            'sanity: the user has not scrolled, so the banner slot below '
            'the fields is off the bottom of the viewport',
      );

      states.add(const ServerOnboardingNotBgeServer());
      await tester.pumpAndSettle();

      expect(
        scroll.position.pixels,
        greaterThan(0),
        reason: 'the reveal has to scroll FORWARD to bring the banner up',
      );

      final top = topInViewport(tester, find.byType(BgeInlineBanner));

      expect(
        top,
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason:
            'the banner has to come UP into the viewport, not be left '
            'below it because the reveal only ever scrolls backwards',
      );
    });

    group('under the selection region (#338)', () {
      Future<void> pumpUnderRegion(WidgetTester tester) async {
        useViewSize(tester, const Size(1280, 800));
        await tester.pumpWidget(
          harness(theme: pointerPlatformTheme(), builder: underSelectionRegion),
        );
        await tester.pumpAndSettle();
      }

      /// Whether the field under [key] holds focus.
      bool hasFocus(WidgetTester tester, Key key) {
        final editable = find.descendant(
          of: find.byKey(key),
          matching: find.byType(EditableText),
        );
        return tester.widget<EditableText>(editable).focusNode.hasFocus;
      }

      testWidgets('the region is installed', (tester) async {
        await pumpUnderRegion(tester);

        expect(find.byType(SelectableRegion), findsOneWidget);
      });

      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        testWidgets(
          'a ${kind.name} tap reaches each field and the submit, and typing '
          'works',
          (tester) async {
            await pumpUnderRegion(tester);

            // enterText focuses without a pointer event, so the tap is what
            // shows the region lets a click through to the field.
            for (final (key, text) in [
              (ServerAddForm.urlFieldKey, 'bge.example.com'),
              (ServerAddForm.aliasFieldKey, 'Home'),
            ]) {
              await tester.tap(find.byKey(key), kind: kind);
              await tester.pump();
              expect(
                hasFocus(tester, key),
                isTrue,
                reason: 'a ${kind.name} tap on $key should focus it',
              );

              await tester.enterText(find.byKey(key), text);
              // reactive_forms delivers control changes asynchronously.
              await tester.pumpAndSettle();
            }

            final submit = find.byKey(ServerAddForm.submitButtonKey);
            await tester.ensureVisible(submit);
            await tester.pumpAndSettle();
            await tester.tap(submit, kind: kind);
            await tester.pumpAndSettle();

            verify(
              () => bloc.add(
                const ServerOnboardingSubmitted(
                  url: 'bge.example.com',
                  alias: 'Home',
                ),
              ),
            ).called(1);
          },
        );
      }
    });

    group('accessibility audit', () {
      /// The screen with the bloc parked in [state].
      Widget Function(ThemeData) screenIn(ServerOnboardingState state) =>
          (theme) {
            stubState(bloc, state);
            return harness(theme: theme);
          };

      /// Scrolls the page to its end, for what a state leaves below the fold
      /// at 320dp × 2.0, which the audit can't see from the top.
      Future<void> scrollToEnd(WidgetTester tester) async {
        final position = pageScrollOf(tester).position;
        position.jumpTo(position.maxScrollExtent);
      }

      auditScreen('ready', build: screenIn(const ServerOnboardingIdle()));

      auditScreen(
        'ready, scrolled to the end',
        build: screenIn(const ServerOnboardingIdle()),
        arrange: scrollToEnd,
      );

      // Bringing the rejected field into view leaves the page at its end, so
      // there is no scrolled call.
      auditScreen(
        'rejected submit',
        build: screenIn(const ServerOnboardingIdle()),
        arrange: (tester) async {
          // Empty: the address is required.
          final submit = find.byKey(ServerAddForm.submitButtonKey);
          await tester.ensureVisible(submit);
          await tester.pumpAndSettle();
          await tester.tap(submit);
        },
      );

      // The submit's spinner never settles.
      auditScreen(
        'connecting',
        settle: false,
        build: screenIn(const ServerOnboardingInProgress()),
      );

      auditScreen(
        'connecting, scrolled to the end',
        settle: false,
        build: screenIn(const ServerOnboardingInProgress()),
        arrange: scrollToEnd,
      );

      // The banner reveals itself, which leaves the page at its end, so
      // there is no scrolled call.
      auditScreen(
        'failure',
        build: screenIn(const ServerOnboardingNotBgeServer()),
      );
    });
  });
}
