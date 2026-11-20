import 'dart:async';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/rate_limited_message.dart';
import 'package:auth/src/sign_in_methods/sign_in_method_rows.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_bloc.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_event.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_state.dart';
import 'package:auth/src/widgets/busy_button_look.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart' show OidcStrategy;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The signed-in user's ways in to this server (#582): their password and
/// the sign-in providers linked to them, with Unlink on each provider, and a
/// Link button for each provider the server offers that isn't linked yet.
///
/// The screen makes its own [SignInMethodsBloc] and reads the list when it
/// opens. Nothing is cached.
///
/// ## Rows
///
/// A row is named by its provider's display name, by a generic name for a
/// provider the server no longer offers (never its id), or as the password.
/// A provider's row says when it was linked. The password row gives no date,
/// though the server dates it too; where the server no longer accepts a
/// password, it says so, since that is why it counts as no way in. The
/// password row has no Unlink. Each Unlink shows "Unlink" and is named for
/// its row, so a screen reader moving between them hears which is which. A
/// provider row whose Unlink would leave no way in keeps it, disabled, with
/// the reason as its label and its name.
/// The button sits under the row's text rather than beside it, so a long
/// label wraps at 320dp and 200% text.
///
/// The rows are few, at most one per provider discovery lists and the
/// password, and share the page with prose, so they sit in a plain column on
/// the box page at the reading measure, not in a sliver list. Each is keyed
/// by its row id, so a row keeps its state and its focus when one above it
/// leaves.
///
/// ## Link and Unlink
///
/// Both write to the server, so offline each is disabled through
/// [BgeOnlineOnly], and one note under the page says why once. One write is
/// out at a time: while a link is starting or an unlink is out, every other
/// Link and Unlink is disabled, so neither result overwrites the other's
/// banner, and a page that leaves for a provider strands no unlink.
///
/// - **Link** leaves for the provider's page and comes back here, where the
///   result is announced. Where this device can't start a link, each Link is
///   disabled and its label says why. While a link is starting, the pressed
///   Link is inert, named as busy, so it keeps focus; the other Link buttons
///   are disabled, since no press of their own made them so (STYLE_GUIDE
///   §5).
/// - **Unlink** asks first, naming the method, or saying that a provider the
///   server no longer offers can't be linked again. Opening the dialog retires
///   the standing outcome, so no stale banner sits under its barrier to be
///   read again when it closes. While an unlink is out, its row's Unlink is
///   inert and the other rows' are disabled, as for Link.
///
/// ## Outcomes
///
/// Every outcome stays on this screen, so each is a [BgeInlineBanner] at the
/// top of the content, announced as it arrives, with a Dismiss that retires
/// it. Failures are titled: some messages give only a cause. A banner is
/// keyed by the attempt it answers, so the same answer twice is a new
/// banner, announced again.
///
/// It shows whatever the list is doing: over the spinner, over the list, and
/// over a failed read's Try again, so the result of a link that came back with
/// the page is never lost to a list that won't load. Each state lays the page
/// out its own way, so the banner's key is global: the one banner moves from
/// state to state, and keeps its semantics node, rather than being built anew
/// and announced again when the list arrives.
///
/// ## Keeping keyboard focus
///
/// Try again goes as the read starts, and would take focus with it, so it
/// hands focus to the page's title, which is no Tab stop but is always
/// there. Dismiss goes with its banner, and does the same. A reload that
/// takes away the row whose Unlink had focus, as a successful unlink does,
/// hands it to the title too.
///
/// ## Closing the bloc
///
/// The bloc closes as the route pops, not when the screen is disposed: the
/// route stays mounted through its exit transition, and a link can still be
/// waiting out its page-leave grace when the user leaves. It closes on
/// dispose too, for a route that goes without a pop.
class SignInMethodsScreen extends StatefulWidget {
  const SignInMethodsScreen({
    required this.repository,
    required this.strategies,
    required this.passwordSignInOffered,
    required this.returnPath,
    super.key,
  });

  static const Key outcomeKey = Key('sign_in_methods.outcome');
  static const Key dismissKey = Key('sign_in_methods.dismiss');
  static const Key retryKey = Key('sign_in_methods.retry');
  static const Key confirmUnlinkKey = Key('sign_in_methods.confirm_unlink');
  static const Key cancelUnlinkKey = Key('sign_in_methods.cancel_unlink');

  /// The row for the sign-in method whose row id is [id].
  static Key rowKey(String id) => ValueKey('sign_in_methods.row.$id');

  /// The Unlink button of the row whose id is [id].
  static Key unlinkKey(String id) => ValueKey('sign_in_methods.unlink.$id');

  /// The Link button for the provider [providerId].
  static Key linkKey(String providerId) =>
      ValueKey('sign_in_methods.link.$providerId');

  final AuthRepository repository;

  /// The providers the server's discovery lists, in its order.
  final List<OidcStrategy> strategies;

  /// Whether the server's discovery offers email and password sign-in. A
  /// password counts as a way in only while it does.
  final bool passwordSignInOffered;

  /// The page a link comes back to: this screen's location.
  final String returnPath;

  @override
  State<SignInMethodsScreen> createState() => _SignInMethodsScreenState();
}

class _SignInMethodsScreenState extends State<SignInMethodsScreen> {
  late final SignInMethodsBloc _bloc;

  /// Whether [_bloc] was closed. Kept here rather than read from the bloc:
  /// `isClosed` turns true only once its close has run, and an event added
  /// meanwhile would throw.
  bool _closed = false;

  /// The outcome banner's key, new with each link or unlink started here: see
  /// "Outcomes".
  GlobalKey _outcomeKey = _newOutcomeKey();

  static GlobalKey _newOutcomeKey() =>
      GlobalKey(debugLabel: 'sign-in methods outcome');

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'sign-in methods heading',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    _bloc = SignInMethodsBloc(
      repository: widget.repository,
      strategies: widget.strategies,
      passwordSignInOffered: widget.passwordSignInOffered,
      returnPath: widget.returnPath,
    )..add(const SignInMethodsRequested());
  }

  @override
  void dispose() {
    _close();
    _heading.dispose();
    super.dispose();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    unawaited(_bloc.close());
  }

  void _add(SignInMethodsEvent event) {
    if (!_closed) _bloc.add(event);
  }

  void _retry() {
    _heading.requestFocus();
    _add(const SignInMethodsRequested());
  }

  void _dismiss() {
    _heading.requestFocus();
    _add(const SignInMethodsOutcomeCleared());
  }

  void _link(OidcStrategy strategy) {
    setState(() => _outcomeKey = _newOutcomeKey());
    _add(SignInMethodLinkRequested(strategy));
  }

  Future<void> _unlink(SignInMethodRow row, String name) async {
    // A banner left under the dialog's barrier is read again when the dialog
    // closes, as news it no longer is (#582).
    _add(const SignInMethodsOutcomeCleared());
    if (!await _confirmUnlink(row, name) || !mounted || _closed) return;
    setState(() => _outcomeKey = _newOutcomeKey());
    _add(SignInMethodUnlinkRequested(row));
  }

  Future<bool> _confirmUnlink(SignInMethodRow row, String name) async {
    final l10n = AuthLocalizations.of(context);
    // A provider the server no longer offers has no name to give, and can't
    // be linked again, so its confirm says that instead (#582).
    final removed = row.label is RemovedProviderLabel;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // A provider's name has no length limit, and is in both the title
        // and the body.
        scrollable: true,
        title: Text(
          removed
              ? l10n.signInMethodsUnlinkRemovedConfirmTitle
              : l10n.signInMethodsUnlinkConfirmTitle(name),
        ),
        content: Text(
          removed
              ? l10n.signInMethodsUnlinkRemovedConfirmBody
              : l10n.signInMethodsUnlinkConfirmBody(name),
        ),
        actions: [
          TextButton(
            key: SignInMethodsScreen.cancelUnlinkKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.signInMethodsUnlinkCancel),
          ),
          TextButton(
            key: SignInMethodsScreen.confirmUnlinkKey,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.signInMethodsUnlinkConfirmAction),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Hands focus to the title when the rows change under a focused control
  /// whose row has gone: see "Keeping keyboard focus".
  ///
  /// Runs before the frame that takes the row away, while its button still
  /// holds focus, so the framework never falls back to another control.
  void _onRowsChanged(BuildContext context, SignInMethodsState state) {
    final focused = FocusManager.instance.primaryFocus?.context;
    final row = focused?.findAncestorWidgetOfExactType<_MethodRow>();
    if (row == null) return;
    final id = row.row.method.id;
    if (state.rows.any((r) => r.method.id == id)) return;
    _heading.requestFocus();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _close();
    },
    child: BlocListener<SignInMethodsBloc, SignInMethodsState>(
      bloc: _bloc,
      listenWhen: (previous, current) => previous.rows != current.rows,
      listener: _onRowsChanged,
      child: BlocBuilder<SignInMethodsBloc, SignInMethodsState>(
        bloc: _bloc,
        builder: _buildState,
      ),
    ),
  );

  Widget _buildState(BuildContext context, SignInMethodsState state) {
    final l10n = AuthLocalizations.of(context);
    final outcome = state.outcome;
    final loaded = state.status == SignInMethodsStatus.loaded;

    return BgePage(
      title: Focus(
        focusNode: _heading,
        child: Text(l10n.signInMethodsTitle),
      ),
      // The spinner and the failure sit mid-page, the list at the top.
      centerVertically: !loaded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (outcome != null) ...[
            // Global, so the one banner moves between the states' layouts:
            // see "Outcomes".
            KeyedSubtree(
              key: _outcomeKey,
              child: _OutcomeBanner(
                outcome: outcome,
                strategies: widget.strategies,
                onDismiss: _dismiss,
              ),
            ),
            const BgeGap.lg(),
          ],
          switch (state.status) {
            SignInMethodsStatus.loading => Center(
              child: BgeLoadingState(label: l10n.signInMethodsLoading),
            ),
            SignInMethodsStatus.loadFailed => BgeErrorState(
              retryKey: SignInMethodsScreen.retryKey,
              icon: Icons.cloud_off_outlined,
              title: l10n.signInMethodsLoadFailed,
              body: l10n.signInMethodsLoadFailedBody,
              retryLabel: l10n.signInMethodsRetry,
              onRetry: _retry,
            ),
            SignInMethodsStatus.loaded => _loaded(context, l10n, state),
          },
        ],
      ),
    );
  }

  Widget _loaded(
    BuildContext context,
    AuthLocalizations l10n,
    SignInMethodsState state,
  ) {
    final offline = BgeConnectivityScope.offlineOf(context);
    final unlinkingId = state.unlinkingId;
    final linkingId = state.linkingProviderId;

    Widget methodRow(SignInMethodRow row) {
      final name = _methodName(l10n, row.label);
      final unlinking = unlinkingId == row.method.id;
      // Offline every Unlink is disabled, the busy one too: no press of its
      // own made it so. So is each other row's while one unlink is out, and
      // every one while a link is starting: see "Link and Unlink".
      final pressable =
          row.canUnlink &&
          !offline &&
          linkingId == null &&
          (unlinkingId == null || unlinking);
      return _MethodRow(
        key: SignInMethodsScreen.rowKey(row.method.id),
        row: row,
        name: name,
        unlinking: unlinking,
        onUnlink: pressable ? () => unawaited(_unlink(row, name)) : null,
      );
    }

    Widget linkButton(OidcStrategy strategy) {
      final linking = linkingId == strategy.providerId;
      // As for Unlink: offline, while another link is starting, or while an
      // unlink is out, it is disabled.
      final pressable =
          !offline && unlinkingId == null && (linkingId == null || linking);
      return _LinkButton(
        key: ValueKey(strategy.providerId),
        strategy: strategy,
        supported: state.linkSupported,
        linking: linking,
        onPressed: pressable ? () => _link(strategy) : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l10n.signInMethodsYourMethods),
        for (final row in state.rows) methodRow(row),
        if (state.linkable.isNotEmpty) ...[
          const BgeGap.lg(),
          _Heading(l10n.signInMethodsLinkSection),
          for (final strategy in state.linkable) ...[
            const BgeGap.sm(),
            linkButton(strategy),
          ],
        ],
        // Only offline: online it would still take its gap.
        if (offline) ...[const BgeGap.md(), const BgeOnlineOnlyNote()],
      ],
    );
  }
}

/// What a method is called on its row, in the confirm and in its outcome.
String _methodName(AuthLocalizations l10n, SignInMethodLabel label) =>
    switch (label) {
      PasswordLabel() => l10n.signInMethodsPassword,
      ProviderLabel(:final displayName) => displayName,
      RemovedProviderLabel() => l10n.signInMethodsRemovedProvider,
    };

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// One sign-in method: its name, and on a provider's row when it was linked,
/// or on a password the server no longer accepts that it doesn't, read as
/// one, with Unlink under them.
class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.row,
    required this.name,
    required this.unlinking,
    required this.onUnlink,
    super.key,
  });

  final SignInMethodRow row;
  final String name;

  /// Whether this row's unlink is out.
  final bool unlinking;

  /// Asks to unlink this row. Null disables Unlink.
  final VoidCallback? onUnlink;

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    // The server dates the password row too, but "Linked" is a provider's
    // word (#582).
    final linkedAt = row.method.isPassword ? null : row.method.linkedAt;
    // Without it, a provider's withheld Unlink would contradict the
    // password row above it (#582).
    final note = row.method.isPassword && !row.isWayIn
        ? l10n.signInMethodsPasswordNotOffered
        : linkedAt == null
        ? null
        : l10n.signInMethodsLinkedOn(linkedAt.toLocal());
    final label = unlinking
        ? l10n.signInMethodsUnlinkInProgress
        : row.unlinkIsLastWayIn
        ? l10n.signInMethodsUnlinkLastWayIn
        : l10n.signInMethodsUnlink;
    // At rest every row's button reads "Unlink", so its name adds the row's
    // after that text, which it must hold (WCAG 2.5.3). A removed provider's
    // is a phrase of its own, as its confirm's title is. Busy or withheld,
    // the visible label says why, and is the name too (#582).
    final semanticsLabel = unlinking || row.unlinkIsLastWayIn
        ? label
        : row.label is RemovedProviderLabel
        ? l10n.signInMethodsUnlinkRemovedSemantics
        : l10n.signInMethodsUnlinkSemantics(name);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MergeSemantics(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(name),
            subtitle: note == null ? null : Text(note),
          ),
        ),
        // The password row has none (#582).
        if (!row.method.isPassword)
          BgeOnlineOnly(
            showNote: false,
            child: BgeInertButton(
              inert: unlinking,
              label: semanticsLabel,
              onPressed: onUnlink,
              builder: (context, focusNode, onPressed) => TextButton.icon(
                key: SignInMethodsScreen.unlinkKey(row.method.id),
                focusNode: focusNode,
                onPressed: onPressed,
                style: unlinking
                    ? inertButtonStyle(
                        context,
                        muted: false,
                      ).merge(_wrappingShape(context))
                    : _wrappingShape(context),
                icon: unlinking
                    ? const BusyButtonSpinner()
                    : const Icon(Icons.link_off),
                // TextButton.icon puts the label in a Flexible, so it wraps.
                label: Text(label),
              ),
            ),
          ),
      ],
    );
  }
}

/// The Link button for one provider not yet linked.
class _LinkButton extends StatelessWidget {
  const _LinkButton({
    required this.strategy,
    required this.supported,
    required this.linking,
    required this.onPressed,
    super.key,
  });

  final OidcStrategy strategy;

  /// Whether this device can start a link. When it can't, the button is
  /// disabled and its label says so.
  final bool supported;

  /// Whether this provider's link is starting.
  final bool linking;

  /// Starts the link. Null disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    final name = strategy.displayName;
    final label = !supported
        ? l10n.signInMethodsLinkUnavailable(name)
        : linking
        ? l10n.signInMethodsLinkInProgress(name)
        : l10n.signInMethodsLink(name);
    final size = OutlinedButton.styleFrom(
      minimumSize: Size(double.infinity, BgeTokens.of(context).minTapTarget),
    ).merge(_wrappingShape(context));

    return BgeOnlineOnly(
      showNote: false,
      child: BgeInertButton(
        inert: linking,
        label: label,
        onPressed: supported ? onPressed : null,
        builder: (context, focusNode, onPressed) => OutlinedButton.icon(
          key: SignInMethodsScreen.linkKey(strategy.providerId),
          focusNode: focusNode,
          onPressed: onPressed,
          style: linking
              ? inertButtonStyle(context, muted: false).merge(size)
              : size,
          icon: linking ? const BusyButtonSpinner() : const Icon(Icons.link),
          // OutlinedButton.icon puts the label in a Flexible, so it wraps.
          label: Text(label),
        ),
      ),
    );
  }
}

/// How the last link or unlink went, with a Dismiss that retires it.
class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({
    required this.outcome,
    required this.strategies,
    required this.onDismiss,
  });

  final SignInMethodsOutcome outcome;
  final List<OidcStrategy> strategies;
  final VoidCallback onDismiss;

  /// The display name discovery gives [providerId], or null when it lists
  /// no such provider.
  String? _providerName(String? providerId) => strategies
      .where((s) => s.providerId == providerId)
      .firstOrNull
      ?.displayName;

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    // Failures are titled because some messages give only a cause: "Could
    // not reach the server" never says that the link failed.
    final (tone, title, message) = switch (outcome) {
      SignInMethodLinked(:final providerId) => (
        BgeBannerTone.success,
        null,
        switch (_providerName(providerId)) {
          final name? => l10n.signInMethodsLinked(name),
          null => l10n.signInMethodsLinkedUnknown,
        },
      ),
      SignInMethodUnlinked(:final label) => (
        BgeBannerTone.success,
        null,
        l10n.signInMethodsUnlinked(_methodName(l10n, label)),
      ),
      SignInMethodLinkFailed(
        :final providerId,
        :final reason,
        :final retryAfter,
      ) =>
        (
          BgeBannerTone.error,
          l10n.signInMethodsLinkFailedTitle,
          _failure(
            l10n,
            reason,
            retryAfter,
            unlink: false,
            provider: _providerName(providerId),
          ),
        ),
      SignInMethodUnlinkFailed(:final reason, :final retryAfter) => (
        BgeBannerTone.error,
        l10n.signInMethodsUnlinkFailedTitle,
        _failure(l10n, reason, retryAfter, unlink: true),
      ),
    };

    return BgeInlineBanner(
      key: SignInMethodsScreen.outcomeKey,
      tone: tone,
      title: title,
      message: message,
      action: TextButton(
        key: SignInMethodsScreen.dismissKey,
        onPressed: onDismiss,
        child: Text(l10n.signInMethodsDismiss),
      ),
    );
  }

  /// Why a link or an unlink failed, by its reason, never by any text the
  /// server or the provider sent (#582). [provider] names the provider a
  /// link was for, when discovery still lists it.
  static String _failure(
    AuthLocalizations l10n,
    ProviderLinkFailureReason reason,
    Duration? retryAfter, {
    required bool unlink,
    String? provider,
  }) => switch (reason) {
    ProviderLinkFailureReason.needsRecentSignIn =>
      unlink
          ? l10n.signInMethodsErrorUnlinkNeedsRecentSignIn
          : l10n.signInMethodsErrorNeedsRecentSignIn,
    ProviderLinkFailureReason.alreadyLinkedElsewhere =>
      provider == null
          ? l10n.signInMethodsErrorAlreadyLinkedElsewhereUnknown
          : l10n.signInMethodsErrorAlreadyLinkedElsewhere(provider),
    ProviderLinkFailureReason.emailUnconfirmed =>
      l10n.signInMethodsErrorEmailUnconfirmed,
    ProviderLinkFailureReason.lastSignInMethod =>
      l10n.signInMethodsErrorLastWayIn,
    ProviderLinkFailureReason.accessDenied =>
      l10n.authProviderErrorAccessDenied,
    ProviderLinkFailureReason.providerUnavailable =>
      l10n.authProviderErrorUnavailable,
    ProviderLinkFailureReason.startAgain => l10n.authProviderErrorStartAgain,
    ProviderLinkFailureReason.rateLimited => rateLimitedMessage(
      l10n,
      retryAfter,
    ),
    ProviderLinkFailureReason.network => l10n.authErrorNetwork,
    ProviderLinkFailureReason.generic => l10n.signInMethodsErrorGeneric,
  };
}

/// The shape of a button whose label can wrap: a rounded box, in place of the
/// theme's stadium (#764). A Material button is clipped to its shape, so a
/// stadium's curved ends cut into a label that wraps, and a reason that runs
/// to several lines at 320dp and 200% text, such as a Link this app can't
/// start, turns it into a circle that cuts off whole words. The focus ring
/// follows the shape it is given, inside the edge as on every text and
/// outlined button (#644).
ButtonStyle _wrappingShape(BuildContext context) {
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(BgeTokens.of(context).radiusMd),
  );
  return ButtonStyle(
    shape: WidgetStatePropertyAll(shape),
    backgroundBuilder: BgeButtonFocusRing.builder(
      shape,
      placement: BgeButtonFocusRingPlacement.inside,
    ),
  );
}
