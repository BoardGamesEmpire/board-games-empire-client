import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';

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
                ReactiveTextField<String>(
                  formControlName: urlControlName,
                  readOnly: inProgress,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.serverAddUrlLabel,
                    hintText: l10n.serverAddUrlHint,
                    helperText: l10n.serverAddUrlHelper,
                  ),
                ),
                const SizedBox(height: 16),
                ReactiveTextField<String>(
                  formControlName: aliasControlName,
                  readOnly: inProgress,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!inProgress) _submit(context, form);
                  },
                  decoration: InputDecoration(
                    labelText: l10n.serverAddAliasLabel,
                    hintText: l10n.serverAddAliasHint,
                  ),
                ),
                const SizedBox(height: 24),
                if (failure != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: _FailureBanner(
                      title: l10n.serverAddErrorTitle,
                      message: _failureMessage(l10n, failure),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                FilledButton(
                  onPressed: inProgress ? null : () => _submit(context, form),
                  child: inProgress
                      ? Semantics(
                          liveRegion: true,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(l10n.serverAddInProgress),
                            ],
                          ),
                        )
                      : Text(l10n.serverAddSubmit),
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

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: colors.onErrorContainer),
          ),
          const SizedBox(height: 4),
          Text(message, style: TextStyle(color: colors.onErrorContainer)),
        ],
      ),
    );
  }
}
