import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/bloc/mail_test_bloc.dart';
import 'package:server_settings/src/bloc/mail_test_event.dart';
import 'package:server_settings/src/bloc/mail_test_state.dart';
import 'package:server_settings/src/bloc/server_settings_bloc.dart';
import 'package:server_settings/src/bloc/server_settings_event.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';
import 'package:server_settings/src/widgets/mail_settings_form.dart';
import 'package:server_settings/src/widgets/mail_test_panel.dart';
import 'package:server_settings/src/widgets/sign_in_settings_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The server's own settings, for staff (#807): the Mail group, with its
/// test email, and the Sign-in group, each saved on its own.
///
/// Decoupled from DI like the admin households list: the caller resolves the
/// per-server [SystemSettingsRemoteDataSource] and
/// [NotificationRemoteDataSource], and the session's
/// [CallerAccessRepository]. Nothing is cached: the settings are read when
/// the screen opens.
///
/// ## Access
///
/// The screen shows to a role that may read the settings. What it can
/// change follows update on system settings: without it every field is
/// read-only, with no Save and no test email, and once access has answered,
/// a banner at the top says why. While it has not, nothing is said about the
/// role. The banner is furniture rather than news, so it doesn't scroll
/// itself into view.
///
/// ## The test email
///
/// [MailTestBloc] reads the notifications until the test's outcome arrives.
/// It stops as the screen's route leaves the navigator, not when the screen
/// is disposed: the screen stays mounted while it animates away, or while
/// the page that replaced it animates in, and a read sent then would go to
/// the server for no one. A route leaves by a pop, or, under a router, by
/// its page being dropped (a `go` elsewhere); both complete
/// [Route.popped], where a [PopScope] hears only the pop.
///
/// An edit to the Mail group retires the outcome: it spoke of the saved
/// settings the edit is replacing. That holds for a test still out at the
/// edit too: its outcome is not shown when it lands.
///
/// ## Keeping keyboard focus
///
/// Retry goes as the read starts, and would take focus with it, so it hands
/// focus to the page's title, which is no Tab stop but is always there.
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({
    required this.remote,
    required this.notifications,
    this.access,
    super.key,
  });

  static const Key loadingKey = Key('server_settings.loading');
  static const Key errorKey = Key('server_settings.error');
  static const Key refusedKey = Key('server_settings.refused');
  static const Key readOnlyKey = Key('server_settings.read_only');

  final SystemSettingsRemoteDataSource remote;

  /// Where the test email's outcome arrives.
  final NotificationRemoteDataSource notifications;

  /// The session's access, asked again when the server refuses. Null for a
  /// composition without one, which opens the settings read-only.
  final CallerAccessRepository? access;

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final ServerSettingsBloc _settings;
  late final MailTestBloc _mailTest;

  /// Whether the test's polling was stopped. Kept here rather than read from
  /// the bloc: `isClosed` turns true only once its close has run, and a
  /// request sent meanwhile would throw.
  bool _mailTestStopped = false;

  /// The route the screen's polling stops with: see "The test email".
  ModalRoute<Object?>? _route;

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'server settings heading',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    _settings = ServerSettingsBloc(remote: widget.remote, access: widget.access)
      ..add(const ServerSettingsStarted());
    _mailTest = MailTestBloc(
      settings: widget.remote,
      notifications: widget.notifications,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    _route = route;
    unawaited(route.popped.then((_) => _stopMailTest()));
  }

  /// Stops the test's polling, once: see "The test email".
  void _stopMailTest() {
    if (_mailTestStopped) return;
    _mailTestStopped = true;
    unawaited(_mailTest.close());
  }

  void _sendTest() {
    if (!_mailTestStopped) _mailTest.add(const MailTestRequested());
  }

  void _mailEdited() {
    _settings.add(const ServerSettingsGroupEdited(SettingsGroup.mail));
    if (!_mailTestStopped) _mailTest.add(const MailTestCleared());
  }

  void _retry() {
    _heading.requestFocus();
    _settings.add(const ServerSettingsRetried());
  }

  @override
  void dispose() {
    _stopMailTest();
    unawaited(_settings.close());
    _heading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider<ServerSettingsBloc>.value(value: _settings),
      BlocProvider<MailTestBloc>.value(value: _mailTest),
    ],
    child: BlocBuilder<ServerSettingsBloc, ServerSettingsState>(
      builder: _buildState,
    ),
  );

  Widget _buildState(BuildContext context, ServerSettingsState state) {
    final l10n = ServerSettingsLocalizations.of(context);
    final title = Focus(
      focusNode: _heading,
      child: Text(l10n.serverSettingsTitle),
    );

    return switch (state) {
      ServerSettingsLoading() => BgePage(
        title: title,
        centerVertically: true,
        child: Center(
          child: BgeLoadingState(
            key: ServerSettingsScreen.loadingKey,
            label: l10n.serverSettingsLoading,
          ),
        ),
      ),
      ServerSettingsDenied() => BgePage(
        title: title,
        centerVertically: true,
        child: BgeEmptyState(
          key: ServerSettingsScreen.refusedKey,
          icon: Icons.lock_outline,
          title: l10n.serverSettingsRefused,
        ),
      ),
      ServerSettingsLoadFailed() => BgePage(
        title: title,
        centerVertically: true,
        child: BgeErrorState(
          key: ServerSettingsScreen.errorKey,
          icon: Icons.cloud_off_outlined,
          title: l10n.serverSettingsLoadFailed,
          body: l10n.serverSettingsLoadFailedBody,
          retryLabel: l10n.serverSettingsRetry,
          onRetry: _retry,
        ),
      ),
      final ServerSettingsLoaded loaded => BgePage(
        title: title,
        child: _loaded(context, l10n, loaded),
      ),
    };
  }

  Widget _loaded(
    BuildContext context,
    ServerSettingsLocalizations l10n,
    ServerSettingsLoaded state,
  ) {
    final settings = state.settings;
    final mayUpdate = state.mayUpdate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.accessKnown && !mayUpdate) ...[
          BgeInlineBanner(
            key: ServerSettingsScreen.readOnlyKey,
            message: l10n.serverSettingsReadOnly,
            reveal: false,
          ),
          const BgeGap.lg(),
        ],
        _GroupHeading(l10n.mailGroupTitle),
        const BgeGap.sm(),
        MailSettingsForm(
          settings: settings,
          revision: state.revision,
          maySave: mayUpdate,
          saving: state.saving == SettingsGroup.mail,
          otherGroupSaving: state.saving == SettingsGroup.signIn,
          failure: state.failures[SettingsGroup.mail],
          saved: state.savedGroup == SettingsGroup.mail,
          onSave: (patch) => _settings.add(
            ServerSettingsGroupSaved(SettingsGroup.mail, patch),
          ),
          onEdited: _mailEdited,
          testPanelBuilder: mayUpdate
              ? (context, {required hasUnsavedChanges}) =>
                    BlocBuilder<MailTestBloc, MailTestState>(
                      builder: (context, test) => MailTestPanel(
                        state: test,
                        hasUnsavedChanges: hasUnsavedChanges,
                        mailConfigured: settings.mailConfigured,
                        onSend: _sendTest,
                      ),
                    )
              : null,
        ),
        const BgeGap.xl(),
        _GroupHeading(l10n.signInGroupTitle),
        const BgeGap.sm(),
        SignInSettingsForm(
          settings: settings,
          revision: state.revision,
          maySave: mayUpdate,
          saving: state.saving == SettingsGroup.signIn,
          otherGroupSaving: state.saving == SettingsGroup.mail,
          failure: state.failures[SettingsGroup.signIn],
          saved: state.savedGroup == SettingsGroup.signIn,
          onSave: (patch) => _settings.add(
            ServerSettingsGroupSaved(SettingsGroup.signIn, patch),
          ),
          onEdited: () => _settings.add(
            const ServerSettingsGroupEdited(SettingsGroup.signIn),
          ),
        ),
      ],
    );
  }
}

/// A group's heading, read as a heading.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
