import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_onboarding/server_onboarding.dart';

import '../support/server_onboarding_bloc_double.dart';

/// Pins [ServerAddForm]'s own wiring (#171) — the form #132 copied its
/// in-flight treatment from, and the only one of the pair with no suite.
///
/// Scoped to what this form decides. `BgeSubmitButton` and
/// `BgeInlineBanner` carry the #163 overflow, live-region and
/// accessible-name assertions in their own suites (#169); `ServerAddScreen`
/// covers the screen. Left here: read-only in flight, which rejections are
/// answered at the field, where focus lands, the keyboard submit path, and
/// the failure-message mapping.
///
/// The bloc is mocked, so states are set directly and each failure branch
/// is reachable without standing up its cause.
void main() {
  late MockServerOnboardingBloc bloc;

  setUpAll(registerServerOnboardingFallbacks);

  setUp(() {
    bloc = MockServerOnboardingBloc();
  });

  Widget wrap({ServerOnboardingState state = const ServerOnboardingIdle()}) {
    stubState(bloc, state);
    return MaterialApp(
      localizationsDelegates:
          ServerOnboardingLocalizations.localizationsDelegates,
      supportedLocales: ServerOnboardingLocalizations.supportedLocales,
      home: BlocProvider<ServerOnboardingBloc>.value(
        value: bloc,
        child: const Scaffold(
          body: SingleChildScrollView(child: ServerAddForm()),
        ),
      ),
    );
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(ServerAddForm.submitButtonKey));
    await tester.tap(find.byKey(ServerAddForm.submitButtonKey));
    await tester.pump();
  }

  /// The `EditableText` under a field key — the widget that owns the focus
  /// node and the platform input connection.
  Finder editableOf(Key fieldKey) => find.descendant(
    of: find.byKey(fieldKey),
    matching: find.byType(EditableText),
  );

  bool hasFocus(WidgetTester tester, Key fieldKey) =>
      tester.widget<EditableText>(editableOf(fieldKey)).focusNode.hasFocus;

  /// The [TextField] the reactive field actually builds, so decoration and
  /// read-only state are asserted against what the framework receives.
  TextField textFieldOf(WidgetTester tester, Key fieldKey) =>
      tester.widget<TextField>(
        find.descendant(
          of: find.byKey(fieldKey),
          matching: find.byType(TextField),
        ),
      );

  group('ServerAddForm', () {
    testWidgets('renders labelled URL and alias fields and a submit button '
        '(labels, never hint-only)', (tester) async {
      await tester.pumpWidget(wrap());

      expect(find.text('Server address'), findsOneWidget);
      expect(find.text('Nickname (optional)'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    });

    testWidgets('a valid submit dispatches the raw field values', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'bge.example.com',
      );
      await tester.enterText(find.byKey(ServerAddForm.aliasFieldKey), 'Home');
      await submit(tester);

      // Raw, deliberately: scheme inference and the http/https policy are
      // `normalizeServerUrl`'s, exercised by its own tests and the bloc's.
      verify(
        () => bloc.add(
          const ServerOnboardingSubmitted(
            url: 'bge.example.com',
            alias: 'Home',
          ),
        ),
      ).called(1);
    });
  });

  group('ServerAddForm URL validation (#171)', () {
    testWidgets('a blank URL surfaces the localized required error and '
        'dispatches nothing', (tester) async {
      await tester.pumpWidget(wrap());

      await submit(tester);

      // Before #171 the validator was never consulted, so this dispatched an
      // empty URL and came back as a banner instead of a field error.
      verifyNever(
        () => bloc.add(
          any<ServerOnboardingEvent>(that: isA<ServerOnboardingSubmitted>()),
        ),
      );
      expect(find.text('Enter the address of your server.'), findsOneWidget);
    });

    testWidgets('a whitespace-only URL is rejected the same way', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      await tester.enterText(find.byKey(ServerAddForm.urlFieldKey), '   ');
      await submit(tester);

      // Rejected here rather than by `normalizeServerUrl`, which would call
      // it malformed and answer with a banner. `Validators.required` trims.
      verifyNever(
        () => bloc.add(
          any<ServerOnboardingEvent>(that: isA<ServerOnboardingSubmitted>()),
        ),
      );
      expect(find.text('Enter the address of your server.'), findsOneWidget);
    });

    testWidgets('the keyboard "done" path is validated too, not just the '
        'button', (tester) async {
      await tester.pumpWidget(wrap());

      await tester.enterText(find.byKey(ServerAddForm.aliasFieldKey), 'Home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      verifyNever(
        () => bloc.add(
          any<ServerOnboardingEvent>(that: isA<ServerOnboardingSubmitted>()),
        ),
      );
      expect(find.text('Enter the address of your server.'), findsOneWidget);
    });

    testWidgets('a blank alias is left alone — only the URL is required', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'bge.example.com',
      );
      await submit(tester);

      // The alias is optional and its blank-handling belongs to the bloc,
      // which falls back to the server's advertised name.
      verify(
        () => bloc.add(const ServerOnboardingSubmitted(url: 'bge.example.com')),
      ).called(1);
    });

    testWidgets('the error clears once a valid address is typed', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      await submit(tester);
      expect(find.text('Enter the address of your server.'), findsOneWidget);

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'bge.example.com',
      );
      await tester.pump();

      // Without this the suite stays green on a field stuck showing the
      // error forever. Strict is fine; stuck is what feels broken.
      expect(find.text('Enter the address of your server.'), findsNothing);
    });

    // Every ServerUrlError, at the field. Before this the three below were
    // dispatched, rejected by the bloc, and returned as a banner across the
    // top of the form — a report from a server that was never contacted.
    for (final (name, input, message) in <(String, String, String)>[
      (
        'an unsupported scheme',
        'ftp://bge.example.com',
        'Only http and https addresses are supported.',
      ),
      (
        'plain http toward a public host',
        'http://bge.example.com',
        'Plain http is only allowed for local and private network addresses. '
            'Use https for this server.',
      ),
      (
        'an unparseable address',
        'ht tp://%%%',
        "That doesn't look like a valid server address. Check it and try "
            'again.',
      ),
    ]) {
      testWidgets('$name is rejected at the field, not by round trip', (
        tester,
      ) async {
        await tester.pumpWidget(wrap());

        await tester.enterText(find.byKey(ServerAddForm.urlFieldKey), input);
        await submit(tester);

        verifyNever(
          () => bloc.add(
            any<ServerOnboardingEvent>(that: isA<ServerOnboardingSubmitted>()),
          ),
        );
        expect(find.text(message), findsOneWidget);
      });
    }

    testWidgets('a private-network http address is accepted — the policy is '
        'the bloc\'s, not a stricter copy', (tester) async {
      await tester.pumpWidget(wrap());

      // The validator runs `normalizeServerUrl` rather than reimplementing
      // it, so the LAN carve-out comes free. A copy is what would lose it.
      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'http://192.168.1.10',
      );
      await submit(tester);

      verify(
        () => bloc.add(
          const ServerOnboardingSubmitted(url: 'http://192.168.1.10'),
        ),
      ).called(1);
    });

    testWidgets('editing the address retires the banner about the old one', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(state: const ServerOnboardingUnreachable()));

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'bge.example.com',
      );
      await tester.pump();

      // Without this the complaint stayed up while the user typed the
      // replacement for the value it was complaining about.
      verify(() => bloc.add(const ServerOnboardingFailureCleared())).called(1);
    });

    testWidgets('editing with no failure showing dispatches nothing', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      await tester.enterText(find.byKey(ServerAddForm.urlFieldKey), 'bge');
      await tester.pump();

      verifyNever(() => bloc.add(const ServerOnboardingFailureCleared()));
    });

    testWidgets('a rejected submit retires the banner from the previous '
        'attempt', (tester) async {
      await tester.pumpWidget(wrap(state: const ServerOnboardingUnreachable()));
      expect(
        find.text(
          "Couldn't reach the server. Check the address and your connection.",
        ),
        findsOneWidget,
      );

      await submit(tester);

      // Nothing else would take it down: the bloc only re-renders on an
      // event, so the old banner would sit above the new inline error.
      verify(() => bloc.add(const ServerOnboardingFailureCleared())).called(1);
      verifyNever(
        () => bloc.add(
          any<ServerOnboardingEvent>(that: isA<ServerOnboardingSubmitted>()),
        ),
      );
    });
  });

  group('ServerAddForm failure messages (#171)', () {
    // Every leaf of the sealed ServerOnboardingFailure, plus every
    // ServerUrlError the invalid-URL case carries.
    //
    // The table is hand-maintained — nothing reads the hierarchy at run
    // time, so a new kind cannot add its own row. `_exhaustiveness` above
    // is what makes forgetting loud: adding a kind stops this file
    // compiling until someone comes here, and the row is the reason they
    // were sent.
    const cases = <(String, ServerOnboardingFailure, String)>[
      (
        'malformed URL',
        ServerOnboardingInvalidUrl(ServerUrlError.malformed),
        "That doesn't look like a valid server address. Check it and try "
            'again.',
      ),
      (
        'unsupported scheme',
        ServerOnboardingInvalidUrl(ServerUrlError.unsupportedScheme),
        'Only http and https addresses are supported.',
      ),
      (
        'insecure http',
        ServerOnboardingInvalidUrl(ServerUrlError.insecureHttp),
        'Plain http is only allowed for local and private network '
            'addresses. Use https for this server.',
      ),
      (
        'offline',
        ServerOnboardingOffline(),
        "You're offline. Connect to a network and try again.",
      ),
      (
        'unreachable',
        ServerOnboardingUnreachable(),
        "Couldn't reach the server. Check the address and your connection.",
      ),
      (
        'not a BGE server',
        ServerOnboardingNotBgeServer(),
        'No Board Games Empire server was found at that address.',
      ),
      (
        'invalid response',
        ServerOnboardingInvalidResponse(),
        'The server sent an unexpected response. It may be misconfigured '
            'or an incompatible version.',
      ),
      (
        'client too old',
        ServerOnboardingClientTooOld(
          clientVersion: '1.0.0',
          requiredMinimum: '2.0.0',
        ),
        'This server requires app version 2.0.0 or newer (you have 1.0.0). '
            'Please update the app.',
      ),
      (
        'client too new',
        ServerOnboardingClientTooNew(
          clientVersion: '2.1.0',
          supportedMaximum: '2.0.0',
        ),
        'This server supports app versions up to 2.0.0 (you have 2.1.0). '
            'The server needs to be updated.',
      ),
      (
        'schema too new',
        ServerOnboardingSchemaTooNew(),
        'This server speaks a newer protocol than this app understands. '
            'Please update the app.',
      ),
      (
        'duplicate',
        ServerOnboardingDuplicate(),
        'That server is already registered on this device.',
      ),
      (
        'capacity exceeded',
        ServerOnboardingCapacityExceeded(),
        "You've reached the maximum number of connected servers on this "
            'device.',
      ),
    ];

    for (final (name, state, message) in cases) {
      testWidgets('$name renders its localized message', (tester) async {
        await tester.pumpWidget(wrap(state: state));

        expect(find.text("Couldn't add server"), findsOneWidget);
        expect(find.text(message), findsOneWidget);
      });
    }

    testWidgets('an unexpected failure renders the fallback message', (
      tester,
    ) async {
      // Not in the table above: it carries a cause, so it cannot be const.
      await tester.pumpWidget(
        wrap(state: ServerOnboardingUnexpectedFailure(Exception('boom'))),
      );

      expect(
        find.text(
          'Something went wrong while adding the server. Please try '
          'again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the failure banner reaches the semantics tree as a live '
        'region', (tester) async {
      await tester.pumpWidget(wrap(state: const ServerOnboardingOffline()));

      // Asserted at the widget-tree level rather than on SemanticsNode
      // flags, to stay independent of that API across Flutter versions.
      expect(
        find.ancestor(
          of: find.text("Couldn't add server"),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.liveRegion ?? false),
          ),
        ),
        findsOneWidget,
        reason: 'a failure must be announced, not only exposed on next focus',
      );
    });
  });

  group('ServerAddForm accessibility (#171)', () {
    testWidgets('both fields are labelled through their decoration rather '
        'than leaning on a hint', (tester) async {
      await tester.pumpWidget(wrap());

      // Both fields DO carry hints here (example values). What must never
      // happen is a hint standing in for the label, so the label is what
      // is pinned.
      expect(
        textFieldOf(tester, ServerAddForm.urlFieldKey).decoration,
        isA<InputDecoration>()
            .having((d) => d.labelText, 'labelText', 'Server address')
            .having((d) => d.hintText, 'hintText', isNotNull),
      );
      expect(
        textFieldOf(tester, ServerAddForm.aliasFieldKey).decoration,
        isA<InputDecoration>().having(
          (d) => d.labelText,
          'labelText',
          'Nickname (optional)',
        ),
      );
    });

    testWidgets('both fields reach the semantics tree as labelled text '
        'fields', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(wrap());

      // Scoped to each field's own subtree so a label cannot be satisfied
      // by some unrelated node, and matched with a RegExp so the assertion
      // survives semantics merging (a merged node's label is the
      // concatenation of its children's).
      for (final (fieldKey, label) in <(Key, String)>[
        (ServerAddForm.urlFieldKey, 'Server address'),
        (ServerAddForm.aliasFieldKey, 'Nickname'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(fieldKey),
            matching: find.bySemanticsLabel(RegExp(label)),
          ),
          findsAtLeastNWidgets(1),
          reason: '$label must be exposed to assistive tech',
        );
        expect(
          tester.getSemantics(editableOf(fieldKey)),
          isSemantics(isTextField: true),
        );
      }

      // Dispose inline, not via addTearDown: flutter_test verifies that no
      // SemanticsHandle is outstanding at the end of the test body, which
      // runs before tearDown callbacks.
      handle.dispose();
    });

    testWidgets('the URL field does not autocorrect or suggest', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      // A hostname is not prose. An autocorrected server address fails in a
      // way the user cannot diagnose, because the field still shows what
      // they believe they typed.
      final url = textFieldOf(tester, ServerAddForm.urlFieldKey);
      expect(url.autocorrect, isFalse);
      expect(url.enableSuggestions, isFalse);

      // The alias IS prose — a nickname the user chose — so it keeps the
      // platform's help. Pinned so the two are not "fixed" into agreement.
      expect(
        textFieldOf(tester, ServerAddForm.aliasFieldKey).autocorrect,
        isTrue,
      );
    });

    testWidgets('the keyboard "next" action moves focus from the URL field '
        'to the alias field', (tester) async {
      await tester.pumpWidget(wrap());

      // enterText focuses the field and attaches the platform input
      // connection, which is what receiveAction dispatches to.
      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'bge.example.com',
      );
      expect(hasFocus(tester, ServerAddForm.urlFieldKey), isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();

      expect(
        hasFocus(tester, ServerAddForm.aliasFieldKey),
        isTrue,
        reason: 'focus order must be URL -> alias',
      );
      expect(hasFocus(tester, ServerAddForm.urlFieldKey), isFalse);
    });

    testWidgets('the keyboard "done" action on the alias submits with the '
        'same values as the button', (tester) async {
      await tester.pumpWidget(wrap());

      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'bge.example.com',
      );
      await tester.enterText(find.byKey(ServerAddForm.aliasFieldKey), 'Home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      verify(
        () => bloc.add(
          const ServerOnboardingSubmitted(
            url: 'bge.example.com',
            alias: 'Home',
          ),
        ),
      ).called(1);
    });

    testWidgets('a rejected submit moves focus to the field it rejected', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());

      await submit(tester);

      // markAllAsTouched renders the message but moves nothing, leaving a
      // keyboard user to shift-tab back past the alias field to find it.
      expect(hasFocus(tester, ServerAddForm.urlFieldKey), isTrue);
    });

    testWidgets('the field error is announced, not only rendered', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(wrap());
      await submit(tester);

      // Populating validationMessages switches BgeTextField's announcer on,
      // so this form only just gained the behaviour. Two nodes carry the
      // message by design: the field takes it as `hint` (read on arrival),
      // a 1×1 live region announces it on appearance. The stutter
      // BgeTextField warns about is two *labels* on the field.
      expect(
        find.descendant(
          of: find.byKey(ServerAddForm.urlFieldKey),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                (w.properties.liveRegion ?? false) &&
                w.properties.label == 'Enter the address of your server.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(editableOf(ServerAddForm.urlFieldKey)),
        isSemantics(
          label: 'Server address',
          hint: 'Enter the address of your server.',
          isTextField: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('while in flight both fields are read-only, closing the '
        'keyboard submit path', (tester) async {
      await tester.pumpWidget(wrap(state: const ServerOnboardingInProgress()));

      // Read-only rather than disabled, per `BgeTextField`: the control
      // stays in traversal instead of vanishing mid-form, and still tears
      // down the input connection, which closes the keyboard submit path.
      expect(textFieldOf(tester, ServerAddForm.urlFieldKey).readOnly, isTrue);
      expect(textFieldOf(tester, ServerAddForm.aliasFieldKey).readOnly, isTrue);
    });

    testWidgets('while in flight the submit control is disabled but still '
        'present and named', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(wrap(state: const ServerOnboardingInProgress()));

      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(ServerAddForm.submitButtonKey),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull, reason: 'disabled, but still present');

      // The regression this guards: a disabled button whose only child is a
      // spinner has no accessible name, so a screen reader announces
      // nothing at the moment the user most needs status.
      expect(
        tester.getSemantics(
          find.descendant(
            of: find.byKey(ServerAddForm.submitButtonKey),
            matching: find.byType(FilledButton),
          ),
        ),
        isSemantics(
          label: 'Contacting server…',
          isButton: true,
          isLiveRegion: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );

      handle.dispose();
    });

    testWidgets('a tap on the in-flight submit control dispatches nothing', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(state: const ServerOnboardingInProgress()));

      await submit(tester);

      verifyNever(
        () => bloc.add(
          any<ServerOnboardingEvent>(that: isA<ServerOnboardingSubmitted>()),
        ),
      );
    });
  });
}

/// Compile-time tripwire for the failure table below.
///
/// A `switch` statement over a sealed type must be exhaustive, so adding a
/// leaf to `ServerOnboardingFailure` breaks this file's compilation — which
/// is the point. `_failureMessage` in the widget breaks too, but that only
/// forces a message to exist; nothing there forces anyone to prove it
/// renders. This does, by making the test file the second place they have
/// to visit.
///
/// Never called: it exists for the analyzer, not the runtime.
// ignore: unused_element
void _exhaustiveness(ServerOnboardingFailure failure) {
  switch (failure) {
    case ServerOnboardingInvalidUrl():
    case ServerOnboardingOffline():
    case ServerOnboardingUnreachable():
    case ServerOnboardingNotBgeServer():
    case ServerOnboardingInvalidResponse():
    case ServerOnboardingClientTooOld():
    case ServerOnboardingClientTooNew():
    case ServerOnboardingSchemaTooNew():
    case ServerOnboardingDuplicate():
    case ServerOnboardingCapacityExceeded():
    case ServerOnboardingUnexpectedFailure():
      break;
  }
}
