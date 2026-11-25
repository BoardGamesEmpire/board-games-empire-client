import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/detail/api_key_detail_bloc.dart';
import 'package:api_keys/src/detail/api_key_detail_event.dart';
import 'package:api_keys/src/detail/api_key_detail_state.dart';
import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:api_keys/src/widgets/api_key_scope_list.dart';
import 'package:api_keys/src/widgets/delete_key_dialog.dart';
import 'package:api_keys/src/widgets/scope_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One of the signed-in user's API keys, on its own page (#1028): its name,
/// the start of its secret, when it was made, when it expires and when it was
/// last used, an Enabled switch, every permission it holds with its risk in
/// words ([ApiKeyScopeList]), and Delete.
///
/// Online only, as the key list is: the key and the permissions the user may
/// grant are read from the server when the page opens, and nothing is
/// stored. A 404 says the key no longer exists, with a way back. The
/// grantable permissions only describe the key's scopes, so when they can't
/// be read the scopes show their slugs, and the page is otherwise whole.
///
/// The name heads the page as well as the app bar, which cuts a long one
/// short at 200% text on a phone.
///
/// ## Enabled and Delete
///
/// Both go straight to the server, so offline each is disabled and says why
/// (#49): the switch in its own label, Delete in its hint and a note under
/// it. One write is out at a time. The control that started it stays enabled
/// and ignores presses, so it keeps focus (STYLE_GUIDE §5); the other is
/// disabled, since no press of its own made it so.
///
/// - **Enabled** asks for nothing: re-enabling a key needs no confirmation.
///   It shows the key as the server last answered it, and a bar above it,
///   read out as "Saving…", says a change is on its way.
/// - **Delete** asks first, naming the key. Opening the dialog retires a
///   standing failure, so no stale banner sits under its barrier to be read
///   again when it closes. Delete takes focus as it is pressed, which a
///   screen reader's double tap doesn't give it, so the dialog hands focus
///   back to it when it closes. While the delete is out its label says it is
///   deleting.
///
/// A failure shows in a [BgeInlineBanner] directly above the control it
/// answers, until the next write starts or Delete's dialog opens. A key the
/// server finds gone takes the page to the gone state, with focus on the
/// page's title, since the controls went with the key.
///
/// ## Leaving
///
/// A delete that goes through says "Deleted {name}" in a SnackBar, on the
/// messenger above the route, and pops the page. The page goes on drawing
/// the key meanwhile, so nothing flashes on the way out.
///
/// The page saves and then leaves, so it owns its bloc past the route
/// (STYLE_GUIDE, "a screen that saves and then leaves"; #464). It makes the
/// bloc when it opens, with the [sessionLease] of the session [remote] came
/// from, and closes it through `closeWhenSettled` in `dispose`. A write the
/// user walked away from is said once it ends, in a SnackBar on the page
/// they went to: deleted, enabled, disabled, or why it failed. So is one
/// that ends while the route is still leaving, and that never navigates.
/// Nothing is said once the session has ended (#694).
///
/// ## Another key
///
/// The router keeps this page when only the id changes, so a new [id] makes
/// a new bloc, and the old key's late answer is said as if its page had
/// gone.
class ApiKeyDetailScreen extends StatelessWidget {
  const ApiKeyDetailScreen({
    required this.remote,
    required this.id,
    required this.sessionLease,
    super.key,
  });

  static const Key loadingKey = Key('api_key_detail.loading');
  static const Key failedKey = Key('api_key_detail.failed');
  static const Key retryKey = Key('api_key_detail.retry');
  static const Key goneKey = Key('api_key_detail.gone');
  static const Key backKey = Key('api_key_detail.back');

  /// On the Enabled switch's `SwitchListTile`.
  static const Key enabledKey = Key('api_key_detail.enabled');

  /// On Delete's `TextButton`.
  static const Key deleteKey = Key('api_key_detail.delete');

  /// The banner above the switch when enabling or disabling failed.
  static const Key toggleFailedKey = Key('api_key_detail.toggle_failed');

  /// The banner above Delete when deleting failed.
  static const Key deleteFailedKey = Key('api_key_detail.delete_failed');

  final ApiKeyRemoteDataSource remote;

  /// The key to show.
  final String id;

  /// The user session [remote] came from. A write that ends after the page
  /// has gone is said only while it is live (#694).
  final SessionLease sessionLease;

  @override
  Widget build(BuildContext context) => _ApiKeyDetail(
    // go_router keeps this page when only the id changes; the key makes a
    // new id a new bloc rather than the old key under the new one's URL.
    key: ValueKey<String>(id),
    screen: this,
  );
}

/// The page for one key, and its bloc, which outlives the route.
class _ApiKeyDetail extends StatefulWidget {
  const _ApiKeyDetail({required this.screen, super.key});

  final ApiKeyDetailScreen screen;

  @override
  State<_ApiKeyDetail> createState() => _ApiKeyDetailState();
}

class _ApiKeyDetailState extends State<_ApiKeyDetail> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the route: a write still out then would never say how it ended. See
  /// [dispose].
  late final ApiKeyDetailBloc _bloc;

  /// The lease of the session the bloc's remote came from, taken when the
  /// bloc is made, since [dispose] can't trust a later build's.
  late final SessionLease _session;

  /// The messenger above the route, which says a bar only while [_session] is
  /// live, and this page's strings, captured while the page is mounted: a
  /// write that ends after it is gone is said with them, and [dispose] can't
  /// look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late ApiKeysLocalizations _l10n;

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop. Where focus goes when the control that had it goes.
  final FocusNode _heading = FocusNode(
    debugLabel: 'API key heading',
    skipTraversal: true,
  );

  /// Delete's focus node, owned by its [BgeInertButton] and taken from its
  /// builder, so a press can give Delete focus before its dialog opens.
  FocusNode? _deleteFocus;

  @override
  void initState() {
    super.initState();
    final screen = widget.screen;
    _session = screen.sessionLease;
    _bloc = ApiKeyDetailBloc(screen.remote, id: screen.id)
      ..add(const ApiKeyDetailRequested());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger.attach(context);
    _l10n = ApiKeysLocalizations.of(context);
  }

  @override
  void dispose() {
    // Gone with a write out: it ends, is said while the session lives, and
    // the bloc closes then. Otherwise the page has shown whatever there was,
    // and the bloc closes now.
    unawaited(
      closeWhenSettled<ApiKeyDetailState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: (state) => state.writing != null,
        outcomeOf: _lateMessage,
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    _heading.dispose();
    super.dispose();
  }

  /// How a write ended, in words for a SnackBar once the user has left the
  /// page: deleted, enabled or disabled, or why it failed, since the banner
  /// went with the page. Nothing for a key found gone.
  String? _lateMessage(ApiKeyDetailState state) {
    final key = state.key;
    if (key == null) return null;
    final name = _nameOf(_l10n, key);
    return switch (state.outcome) {
      ApiKeyDetailDeleted() => _l10n.apiKeyDeleted(name),
      ApiKeyDetailFailed(:final failure, :final write) =>
        _l10n.apiKeyFailedLate(
          _failedTitle(_l10n, write, key),
          apiKeyFailureMessage(_l10n, failure, grantable: state.grantable),
        ),
      // A toggle that went through: the key is as the server answered.
      null =>
        key.enabled
            ? _l10n.apiKeyEnabledDone(name)
            : _l10n.apiKeyDisabledDone(name),
    };
  }

  /// Once a write ends: see "Leaving" on [ApiKeyDetailScreen].
  ///
  /// A route already on its way out, by its back button say, says how the
  /// write ended, a failure too, and goes nowhere: popping then would take
  /// the page beneath with it. By `dispose` the write has ended, so
  /// `closeWhenSettled` says nothing more.
  void _onWriteEnded(BuildContext context, ApiKeyDetailState state) {
    final route = ModalRoute.of(context);
    if (route != null && !route.isActive) {
      _messenger.say(_lateMessage(state));
      return;
    }
    if (state.status == ApiKeyDetailStatus.gone) {
      // The switch and Delete went with the key, focus too, so it waits on
      // the title.
      _heading.requestFocus();
      return;
    }
    if (!state.deleted) return;
    // The page stays live while the delete is out, so something can be
    // open over it when the answer lands, and a pop would take whatever is
    // on top. That goes first.
    if (route != null && !route.isCurrent) {
      Navigator.of(context).popUntil((r) => r == route);
    }
    // The messenger is above the route, so the bar outlives it and shows on
    // the page it leaves for.
    _messenger.say(_lateMessage(state));
    Navigator.of(context).maybePop();
  }

  void _retry() {
    // Try again goes as the read starts, and would take focus with it.
    _heading.requestFocus();
    _bloc.add(const ApiKeyDetailRequested());
  }

  Future<void> _delete(String name) async {
    // Given here as well as by a key press, so the dialog hands focus back
    // to Delete for a screen reader's double tap too, which gives it none.
    _deleteFocus?.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    // A banner left under the dialog's barrier is read again when the dialog
    // closes, as news it no longer is.
    _bloc.add(const ApiKeyDetailOutcomeCleared());
    final confirmed = await DeleteKeyDialog.show(context, name: name);
    if (!confirmed || !mounted) return;
    _bloc.add(const ApiKeyDeleteRequested());
  }

  @override
  Widget build(BuildContext context) => BlocProvider<ApiKeyDetailBloc>.value(
    value: _bloc,
    child: BlocListener<ApiKeyDetailBloc, ApiKeyDetailState>(
      listenWhen: (previous, current) =>
          previous.writing != null && current.writing == null,
      listener: _onWriteEnded,
      child: BlocBuilder<ApiKeyDetailBloc, ApiKeyDetailState>(
        builder: _buildState,
      ),
    ),
  );

  Widget _buildState(BuildContext context, ApiKeyDetailState state) {
    final l10n = ApiKeysLocalizations.of(context);
    final key = state.key;

    return BgePage(
      title: Focus(
        focusNode: _heading,
        child: Text(key == null ? l10n.apiKeyDetailTitle : _nameOf(l10n, key)),
      ),
      // The spinner, the failure and gone sit mid-page, the key at the top.
      centerVertically: key == null,
      child: switch (state.status) {
        ApiKeyDetailStatus.loading => BgeLoadingState(
          key: ApiKeyDetailScreen.loadingKey,
          label: l10n.apiKeyDetailLoading,
        ),
        ApiKeyDetailStatus.loadFailed => BgeErrorState(
          key: ApiKeyDetailScreen.failedKey,
          retryKey: ApiKeyDetailScreen.retryKey,
          icon: Icons.cloud_off_outlined,
          title: l10n.apiKeyDetailLoadFailed,
          body: l10n.apiKeyDetailLoadFailedBody,
          retryLabel: l10n.apiKeyDetailRetry,
          onRetry: _retry,
        ),
        ApiKeyDetailStatus.gone => BgeEmptyState(
          key: ApiKeyDetailScreen.goneKey,
          icon: Icons.key_off_outlined,
          title: l10n.apiKeyGoneTitle,
          body: l10n.apiKeyGoneBody,
          action: TextButton(
            key: ApiKeyDetailScreen.backKey,
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(l10n.apiKeyGoneBack),
          ),
        ),
        ApiKeyDetailStatus.loaded => _loaded(context, l10n, state, key!),
      },
    );
  }

  Widget _loaded(
    BuildContext context,
    ApiKeysLocalizations l10n,
    ApiKeyDetailState state,
    ApiKey key,
  ) {
    final offline = BgeConnectivityScope.offlineOf(context);
    final toggling = state.writing == ApiKeyWrite.toggle;
    // Deleted, the page is leaving, and still reads as deleting.
    final deleting = state.writing == ApiKeyWrite.delete || state.deleted;
    final failed = switch (state.outcome) {
      final ApiKeyDetailFailed failed => failed,
      _ => null,
    };
    final name = _nameOf(l10n, key);

    Widget banner(Key bannerKey, ApiKeyDetailFailed failed) => BgeInlineBanner(
      key: bannerKey,
      tone: BgeBannerTone.error,
      // Some messages give only a cause: "Couldn't reach the server" never
      // says what failed.
      title: _failedTitle(l10n, failed.write, key),
      message: apiKeyFailureMessage(
        l10n,
        failed.failure,
        grantable: state.grantable,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Heading(name, style: Theme.of(context).textTheme.headlineSmall),
        const BgeGap.sm(),
        _Facts(apiKey: key, grantable: state.grantable),
        const BgeGap.lg(),
        if (failed?.write == ApiKeyWrite.toggle) ...[
          banner(ApiKeyDetailScreen.toggleFailedKey, failed!),
          const BgeGap.md(),
        ],
        _SavingBar(saving: toggling),
        // Keyed, so it keeps its element and focus as a banner comes and
        // goes above it.
        BgeRowFocusRing(
          key: const ValueKey('api_key_detail.enabled_ring'),
          outsideSides: true,
          builder: (context, row) => SwitchListTile(
            key: ApiKeyDetailScreen.enabledKey,
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            contentPadding: EdgeInsets.zero,
            // Offline the reason is a second line of the title, so the
            // tile's one node carries it (#49).
            title: BgeOnlineOnlyLabel(l10n.apiKeyEnabledSwitch),
            subtitle: Text(
              key.enabled ? l10n.apiKeyEnabledOn : l10n.apiKeyEnabledOff,
            ),
            // What the server last answered, not what was last pressed: the
            // bar says a change is on its way.
            value: key.enabled,
            // Through its own change it stays enabled and ignores presses,
            // so it keeps focus (STYLE_GUIDE §5).
            onChanged: offline || deleting
                ? null
                : (on) {
                    if (!toggling) {
                      _bloc.add(ApiKeyEnabledChanged(enabled: on));
                    }
                  },
          ),
        ),
        const BgeGap.lg(),
        _Heading(
          l10n.apiKeyPermissionsHeading,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const BgeGap.sm(),
        ApiKeyScopeList(scopes: key.scopes, grantable: state.grantable),
        const BgeGap.lg(),
        if (failed?.write == ApiKeyWrite.delete) ...[
          banner(ApiKeyDetailScreen.deleteFailedKey, failed!),
          const BgeGap.md(),
        ],
        BgeOnlineOnly(
          key: const ValueKey('api_key_detail.delete_gate'),
          child: _DeleteButton(
            deleting: deleting,
            onPressed: offline || toggling
                ? null
                : () => unawaited(_delete(name)),
            onFocusNode: (node) => _deleteFocus = node,
          ),
        ),
      ],
    );
  }
}

/// What a key is called on its page and in what is said of it: its name, or
/// "Unnamed key", as its row on the list says.
String _nameOf(ApiKeysLocalizations l10n, ApiKey key) =>
    key.name ?? l10n.apiKeyUnnamed;

/// What failed, by the [write] and the [key] it was sent for. A failed toggle
/// leaves the key as it was, so an enabled key failed to be disabled.
String _failedTitle(
  ApiKeysLocalizations l10n,
  ApiKeyWrite write,
  ApiKey key,
) {
  final name = _nameOf(l10n, key);
  return switch (write) {
    ApiKeyWrite.toggle =>
      key.enabled
          ? l10n.apiKeyDisableFailed(name)
          : l10n.apiKeyEnableFailed(name),
    ApiKeyWrite.delete => l10n.apiKeyDeleteFailed(name),
  };
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: style),
  );
}

/// The key's facts, a line each, as its row on the list gives them, with
/// when it was made. Whether it is enabled is the switch's to say.
class _Facts extends StatelessWidget {
  const _Facts({required this.apiKey, required this.grantable});

  final ApiKey apiKey;
  final Map<String, GrantablePermission>? grantable;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final start = apiKey.start;
    final expiresAt = apiKey.expiresAt;
    final lastUsedAt = apiKey.lastUsedAt;
    final scopes = apiKey.scopes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (start != null) Text(l10n.apiKeyStart(start)),
        // With none, the permissions below say the key works nowhere.
        if (scopes.isNotEmpty) Text(scopeSummary(l10n, scopes, grantable)),
        Text(l10n.apiKeyCreated(apiKey.createdAt.toLocal())),
        Text(
          expiresAt == null
              ? l10n.apiKeyNeverExpires
              : l10n.apiKeyExpires(expiresAt.toLocal()),
        ),
        Text(
          lastUsedAt == null
              ? l10n.apiKeyNeverUsed
              : l10n.apiKeyLastUsed(lastUsedAt.toLocal()),
        ),
      ],
    );
  }
}

/// The busy cue while enabling or disabling is on its way, read out as
/// "Saving…".
///
/// Its slot keeps its height whether the bar shows or not, so the switch
/// doesn't move under the pointer that just pressed it.
class _SavingBar extends StatelessWidget {
  const _SavingBar({required this.saving});

  final bool saving;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: BgeTokens.of(context).spaceXs,
    child: saving
        ? Semantics(
            liveRegion: true,
            label: ApiKeysLocalizations.of(context).apiKeySaving,
            child: const ExcludeSemantics(child: LinearProgressIndicator()),
          )
        : null,
  );
}

/// Delete: destructive, in the error colour. While the delete is out it
/// stays enabled and ignores presses, so it keeps focus, and its name says
/// it is deleting (STYLE_GUIDE §5).
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    required this.deleting,
    required this.onPressed,
    required this.onFocusNode,
  });

  final bool deleting;

  /// Asks, then deletes. Null disables the button.
  final VoidCallback? onPressed;

  /// Given the button's focus node as it is built.
  final ValueChanged<FocusNode> onFocusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final label = deleting ? l10n.apiKeyDeleting : l10n.apiKeyDelete;

    return BgeInertButton(
      inert: deleting,
      label: label,
      onPressed: onPressed,
      builder: (context, focusNode, onPressed) {
        onFocusNode(focusNode);
        return TextButton.icon(
          key: ApiKeyDetailScreen.deleteKey,
          focusNode: focusNode,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline),
          // TextButton.icon puts the label in a Flexible, so it wraps.
          label: Text(label),
        );
      },
    );
  }
}
