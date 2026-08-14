import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_onboarding/server_onboarding.dart';

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

  Widget harness() => MaterialApp(
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
  });
}
