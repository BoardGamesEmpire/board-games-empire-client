import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../bloc/server_onboarding_bloc.dart';
import '../bloc/server_onboarding_event.dart';
import '../bloc/server_onboarding_state.dart';
import '../../l10n/server_onboarding_localizations.dart';
import '../url/server_url_input.dart';

/// The add-server form (#36): one URL field, one optional alias field,
/// one submit button.
///
/// Accessibility:
/// - both fields carry visible labels (never hint-only);
/// - failure messages and the in-flight progress indicator render in
///   `liveRegion` semantics so screen readers announce them;
/// - the submit control is disabled (not hidden) while a request is in
///   flight;
/// - everything is reachable and operable by keyboard — the URL field
///   advances to the alias field, and the alias field submits on the
///   keyboard's done action, in addition to the submit button;
/// - a rejected submit moves focus to the field that was rejected, so the
///   message is somewhere the user is rather than somewhere they must go
///   looking.
///
/// Bad input is reported on the field, not in the banner: every way
/// [normalizeServerUrl] can reject an address is a validator here, leaving
/// the banner to carry what only the network can tell us. The bloc still
/// validates and remains the authority; this changes where the user is
/// told, not whether it is checked.
///
/// The `FormGroup` is owned and disposed by [ReactiveFormBuilder], which
/// builds it once from the `form` factory and retains it across rebuilds
/// — so the widget can stay `const` without risking a per-build group
/// that discards typed input.
class ServerAddForm extends StatelessWidget {
  const ServerAddForm({super.key});

  static const urlControlName = 'url';
  static const aliasControlName = 'alias';

  /// Stable finder keys for widget tests.
  static const Key urlFieldKey = Key('server_add.url');
  static const Key aliasFieldKey = Key('server_add.alias');
  static const Key submitButtonKey = Key('server_add.submit');

  void _submit(BuildContext context, FormGroup form) {
    final bloc = context.read<ServerOnboardingBloc>();

    // Guarded here rather than at the call sites, so a submit path added
    // later cannot forget it.
    if (bloc.state is ServerOnboardingInProgress) return;

    // Marking touched is what renders the message: the control starts
    // untouched, so validity alone shows nothing.
    if (!form.valid) {
      form.markAllAsTouched();

      // Focus follows the error, or a keyboard user is left holding the
      // submit button with the message somewhere above it.
      final url = form.control(urlControlName);
      if (url.invalid) url.focus();

      // Retire an earlier banner, which would otherwise sit above the new
      // inline error contradicting it.
      bloc.add(const ServerOnboardingFailureCleared());
      return;
    }

    // Non-null by the guard above: `Validators.required` fails on null.
    final url = form.control(urlControlName).value as String;
    final alias = form.control(aliasControlName).value as String?;
    bloc.add(ServerOnboardingSubmitted(url: url, alias: alias));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ServerOnboardingLocalizations.of(context);

    return ReactiveFormBuilder(
      form: () => FormGroup({
        // Together these make field validity mean "the bloc will accept
        // this". `Validators.required` needs no trimming help: it already
        // does `.trim().isEmpty` on Strings, so the hand-rolled delegate
        // household and feedback carry (#196) would add nothing.
        urlControlName: FormControl<String>(
          validators: [
            Validators.required,
            Validators.delegate(serverUrlValidator),
          ],
        ),
        aliasControlName: FormControl<String>(),
      }),
      builder: (context, form, _) {
        return BlocBuilder<ServerOnboardingBloc, ServerOnboardingState>(
          builder: (context, state) {
            final inProgress = state is ServerOnboardingInProgress;
            final failure = state is ServerOnboardingFailure ? state : null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                BgeTextField(
                  key: urlFieldKey,
                  formControlName: urlControlName,
                  label: l10n.serverAddUrlLabel,
                  hint: l10n.serverAddUrlHint,
                  helper: l10n.serverAddUrlHelper,
                  readOnly: inProgress,
                  keyboardType: TextInputType.url,
                  // The strings the banner already used for these kinds.
                  validationMessages: {
                    ValidationMessage.required: (_) =>
                        l10n.serverAddUrlRequired,
                    serverUrlMalformedError: (_) =>
                        l10n.serverAddErrorUrlMalformed,
                    serverUrlSchemeError: (_) => l10n.serverAddErrorUrlScheme,
                    serverUrlInsecureError: (_) =>
                        l10n.serverAddErrorUrlInsecure,
                  },
                  // A hostname is not prose: an autocorrected address fails
                  // in a way the user cannot see, since the field still shows
                  // what they believe they typed.
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const BgeGap.md(),
                BgeTextField(
                  key: aliasFieldKey,
                  formControlName: aliasControlName,
                  label: l10n.serverAddAliasLabel,
                  hint: l10n.serverAddAliasHint,
                  readOnly: inProgress,
                  textInputAction: TextInputAction.done,
                  onSubmitted: () => _submit(context, form),
                ),
                _RetireFailureOnEdit(control: form.control(urlControlName)),
                const BgeGap.lg(),
                if (failure != null) ...[
                  BgeInlineBanner(
                    tone: BgeBannerTone.error,
                    title: l10n.serverAddErrorTitle,
                    message: _failureMessage(l10n, failure),
                  ),
                  const BgeGap.md(),
                ],
                BgeSubmitButton(
                  key: submitButtonKey,
                  label: l10n.serverAddSubmit,
                  progressLabel: l10n.serverAddInProgress,
                  submitting: inProgress,
                  onPressed: () => _submit(context, form),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

String _failureMessage(
  ServerOnboardingLocalizations l10n,
  ServerOnboardingFailure failure,
) => switch (failure) {
  ServerOnboardingInvalidUrl(:final error) => switch (error) {
    ServerUrlError.malformed => l10n.serverAddErrorUrlMalformed,
    ServerUrlError.unsupportedScheme => l10n.serverAddErrorUrlScheme,
    ServerUrlError.insecureHttp => l10n.serverAddErrorUrlInsecure,
  },
  ServerOnboardingOffline() => l10n.serverAddErrorOffline,
  ServerOnboardingUnreachable() => l10n.serverAddErrorUnreachable,
  ServerOnboardingNotBgeServer() => l10n.serverAddErrorNotBge,
  ServerOnboardingInvalidResponse() => l10n.serverAddErrorInvalidResponse,
  ServerOnboardingClientTooOld(:final clientVersion, :final requiredMinimum) =>
    l10n.serverAddErrorClientTooOld(requiredMinimum, clientVersion),
  ServerOnboardingClientTooNew(:final clientVersion, :final supportedMaximum) =>
    l10n.serverAddErrorClientTooNew(supportedMaximum, clientVersion),
  ServerOnboardingSchemaTooNew() => l10n.serverAddErrorSchemaTooNew,
  ServerOnboardingDuplicate() => l10n.serverAddErrorDuplicate,
  ServerOnboardingCapacityExceeded() => l10n.serverAddErrorCapacity,
  ServerOnboardingUnexpectedFailure() => l10n.serverAddErrorUnexpected,
};

/// Retires a failure banner as soon as the address it describes is edited.
///
/// The submit path clears one too, but only on another rejected submit —
/// so a user correcting the address kept reading a complaint about the
/// value they had just replaced.
///
/// A listener rather than an `onChanged` on the field: `BgeTextField`
/// exposes none, and the control is the thing that actually changes.
class _RetireFailureOnEdit extends StatefulWidget {
  const _RetireFailureOnEdit({required this.control});

  final AbstractControl<dynamic> control;

  @override
  State<_RetireFailureOnEdit> createState() => _RetireFailureOnEditState();
}

class _RetireFailureOnEditState extends State<_RetireFailureOnEdit> {
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.control.valueChanges.listen(_onChanged);
  }

  @override
  void didUpdateWidget(_RetireFailureOnEdit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.control, widget.control)) {
      _sub?.cancel();
      _sub = widget.control.valueChanges.listen(_onChanged);
    }
  }

  void _onChanged(Object? _) {
    if (!mounted) return;
    final bloc = context.read<ServerOnboardingBloc>();
    // Only a failure is retired; the bloc rejects the rest, but not asking
    // keeps an event off the bus on every keystroke of a normal edit.
    if (bloc.state is ServerOnboardingFailure) {
      bloc.add(const ServerOnboardingFailureCleared());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
