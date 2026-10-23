import 'dart:async';

import 'package:flutter/material.dart';
import 'package:models/domain.dart';

import '../../l10n/shell_localizations.dart';
import '../bootstrap/app_bootstrap_cubit.dart';
import '../bootstrap/app_bootstrap_state.dart';
import 'router_back_interceptor.dart';

/// Tells the user, once per boot, that the data saved on this device for a
/// server could not be opened and was rebuilt empty, so changes made on
/// this device that the server never received are gone (#428).
///
/// It sits above the router's Navigator, as the crash prompt in `BgeApp`
/// does, rather than pushing a dialog route. The first screens after boot
/// redirect (auth, then home once the session is restored), and a route
/// pushed on one of them would be removed with it before the user had read
/// it. The notice stays until the user acknowledges it.
///
/// While it is up, its barrier hides the app behind it from assistive
/// technology, and its [AlertDialog] carries the route semantics that make
/// screen readers announce it. System back acknowledges it, as it would
/// close a dialog. A back handler that took priority after the notice's,
/// as the crash flow's does when a crash arrives under it, must defer to
/// it while it is up; [onShown] and [onAcknowledged] say when that is.
///
/// A dialog route would also own keyboard focus, and above the Navigator
/// nothing does, so the notice does it itself. The app behind it can't take
/// focus while it is up, so a field there that asked for focus can't take
/// what is typed. The notice's button takes focus instead, and Tab stays
/// on it. Acknowledging gives focus back to wherever it was before, or to
/// [fallbackFocus] when a redirect has taken that away.
///
/// [child] is always the first child of the same [Stack], so showing or
/// closing the notice never remounts the app beneath it.
class DatabaseRecoveryNotice extends StatefulWidget {
  const DatabaseRecoveryNotice({
    required this.bootstrapCubit,
    required this.backButtonDispatcher,
    required this.child,
    this.onShown,
    this.onAcknowledged,
    this.fallbackFocus,
    super.key,
  });

  static const acknowledgeButtonKey = Key(
    'database_recovery_notice_acknowledge_button',
  );

  /// Source of the servers to name: the [AppBootstrapNeedsAuth] a
  /// successful bootstrap emits carries them.
  final AppBootstrapCubit bootstrapCubit;

  /// The router's dispatcher, so system back reaches the notice first.
  final BackButtonDispatcher? backButtonDispatcher;

  /// Called when the notice comes up, including from its first build.
  final VoidCallback? onShown;

  /// Called once the user acknowledges the notice, after it has scheduled
  /// giving focus back, so a caller can move focus on from there.
  final VoidCallback? onAcknowledged;

  /// Where acknowledging gives focus when where it was before is gone, as
  /// it is once a redirect has replaced the screen behind the notice.
  final FocusNode? Function()? fallbackFocus;

  final Widget child;

  @override
  State<DatabaseRecoveryNotice> createState() => _DatabaseRecoveryNoticeState();
}

class _DatabaseRecoveryNoticeState extends State<DatabaseRecoveryNotice> {
  List<ServerConfig> _servers = const [];
  StreamSubscription<AppBootstrapState>? _subscription;

  final _acknowledgeFocus = FocusNode(
    debugLabel: 'DatabaseRecoveryNotice acknowledge',
  );

  /// Where focus was when the notice took it, given back on acknowledge.
  FocusNode? _focusBefore;

  @override
  void initState() {
    super.initState();
    _servers = _recoveredServersOf(widget.bootstrapCubit.state);
    if (_servers.isNotEmpty) _show();
    _subscription = widget.bootstrapCubit.stream.listen((state) {
      final servers = _recoveredServersOf(state);
      if (servers.isEmpty || !mounted) return;
      final wasHidden = _servers.isEmpty;
      setState(() => _servers = [..._servers, ...servers]);
      if (wasHidden) _show();
    });
  }

  void _show() {
    _takeFocus();
    widget.onShown?.call();
  }

  static List<ServerConfig> _recoveredServersOf(AppBootstrapState state) =>
      state is AppBootstrapNeedsAuth ? state.recoveredServers : const [];

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _acknowledgeFocus.dispose();
    super.dispose();
  }

  void _takeFocus() {
    _focusBefore = FocusManager.instance.primaryFocus;
    // After the frame that builds the button and shuts the app out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _servers.isNotEmpty) _acknowledgeFocus.requestFocus();
    });
  }

  void _acknowledge() {
    setState(() => _servers = const []);
    final before = _focusBefore;
    _focusBefore = null;
    // After the frame that lets the app take focus again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A node keeps its context after its widget is gone, and focus given
      // back to it leaves Tab nothing to move through.
      final canReturn =
          before != null &&
          (before.context?.mounted ?? false) &&
          before.canRequestFocus;
      (canReturn ? before : widget.fallbackFocus?.call())?.requestFocus();
    });
    widget.onAcknowledged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final servers = _servers;
    return Stack(
      children: [
        ExcludeFocus(excluding: servers.isNotEmpty, child: widget.child),
        if (servers.isNotEmpty) ...[
          RouterBackInterceptor(
            dispatcher: widget.backButtonDispatcher,
            onBack: () async {
              _acknowledge();
              return true;
            },
          ),
          ModalBarrier(
            dismissible: false,
            // The crash prompt's veil; see the note on its barrier in
            // `BgeApp`.
            color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.54),
          ),
          // Above the Navigator there is no Overlay ancestor, which the
          // dialog's buttons need for their tooltips and ink, and no route
          // semantics node, which would otherwise hold the dialog's role.
          // Without the container, that role lands on the root node.
          Overlay.wrap(
            child: Semantics(
              container: true,
              // Keeps Tab inside the notice.
              child: FocusScope(
                child: Center(
                  child: _NoticeDialog(
                    servers: servers,
                    acknowledgeFocus: _acknowledgeFocus,
                    onAcknowledge: _acknowledge,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _NoticeDialog extends StatelessWidget {
  const _NoticeDialog({
    required this.servers,
    required this.acknowledgeFocus,
    required this.onAcknowledge,
  });

  final List<ServerConfig> servers;
  final FocusNode acknowledgeFocus;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final title = i18n.shellDatabaseRecoveredTitle;
    return AlertDialog(
      // Named explicitly: AlertDialog names its route only on some
      // platforms by default, and the title is what should be announced.
      semanticLabel: title,
      // Large text or several server names can outgrow a short screen.
      scrollable: true,
      title: Text(title),
      content: Text(
        i18n.shellDatabaseRecoveredBody(
          servers.length,
          servers
              .map((server) => server.displayName)
              .join(i18n.shellDatabaseRecoveredServerSeparator),
        ),
      ),
      actions: [
        FilledButton(
          key: DatabaseRecoveryNotice.acknowledgeButtonKey,
          focusNode: acknowledgeFocus,
          onPressed: onAcknowledge,
          child: Text(i18n.shellDatabaseRecoveredAcknowledge),
        ),
      ],
    );
  }
}
