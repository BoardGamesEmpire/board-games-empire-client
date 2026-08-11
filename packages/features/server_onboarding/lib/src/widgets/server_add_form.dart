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
///   keyboard's done action, in addition to the submit button.
///
/// The `FormGroup` is owned and disposed by [ReactiveFormBuilder], which
/// builds it once from the `form` factory and retains it across rebuilds
/// — so the widget can stay `const` without risking a per-build group
/// that discards typed input.
class ServerAddForm extends StatelessWidget {
  const ServerAddForm({super.key});

  static const urlControlName = 'url';
  static const aliasControlName = 'alias';

  void _submit(BuildContext context, FormGroup form) {
    final url = form.control(urlControlName).value as String? ?? '';
    final alias = form.control(aliasControlName).value as String?;
    context.read<ServerOnboardingBloc>().add(
      ServerOnboardingSubmitted(url: url, alias: alias),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ServerOnboardingLocalizations.of(context);

    return ReactiveFormBuilder(
      form: () => FormGroup({
        urlControlName: FormControl<String>(validators: [Validators.required]),
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
                  formControlName: urlControlName,
                  label: l10n.serverAddUrlLabel,
                  hint: l10n.serverAddUrlHint,
                  helper: l10n.serverAddUrlHelper,
                  readOnly: inProgress,
                  keyboardType: TextInputType.url,
                  // A hostname is not prose. An autocorrected server address
                  // fails in a way the user cannot diagnose, because the field
                  // still shows what they believe they typed.
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const BgeGap.md(),
                BgeTextField(
                  formControlName: aliasControlName,
                  label: l10n.serverAddAliasLabel,
                  hint: l10n.serverAddAliasHint,
                  readOnly: inProgress,
                  textInputAction: TextInputAction.done,
                  onSubmitted: () {
                    if (!inProgress) _submit(context, form);
                  },
                ),
                const BgeGap.lg(),
                if (failure != null) ...[
                  // The live region now lives inside the banner, so it can no
                  // longer be forgotten at a call site.
                  BgeInlineBanner(
                    tone: BgeBannerTone.error,
                    title: l10n.serverAddErrorTitle,
                    message: _failureMessage(l10n, failure),
                  ),
                  const BgeGap.md(),
                ],
                BgeSubmitButton(
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
