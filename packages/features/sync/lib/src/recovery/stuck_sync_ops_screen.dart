import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:sync_queue/l10n/sync_localizations.dart';

import 'stuck_sync_op.dart';
import 'stuck_sync_ops_bloc.dart';
import 'stuck_sync_ops_event.dart';
import 'stuck_sync_ops_state.dart';
import 'sync_recovery.dart';

/// The changes that couldn't sync, each with a retry and a discard (#190).
///
/// Lists every stuck op in queue order, described in plain words. The error
/// the queue recorded is never shown: it can hold server messages and URLs,
/// and the app can't tell a refusal from an op that ran out of retries, so
/// one status line serves both.
///
/// A discard asks first, because it can delete what the op created on this
/// device, such as a household that only exists here.
///
/// Decoupled from DI like the household screens: the shell builds the
/// [SyncRecovery] from the active session's container and passes it in.
class StuckSyncOpsScreen extends StatelessWidget {
  const StuckSyncOpsScreen({required this.recovery, super.key});

  static const Key loadingKey = Key('stuck_sync_ops.loading');
  static const Key emptyKey = Key('stuck_sync_ops.empty');
  static const Key errorKey = Key('stuck_sync_ops.error');
  static const Key actionFailedKey = Key('stuck_sync_ops.action_failed');
  static const Key refusedAgainKey = Key('stuck_sync_ops.refused_again');
  static const Key discardConfirmKey = Key('stuck_sync_ops.discard_confirm');

  static Key rowKey(String entryId) => Key('stuck_sync_ops.row_$entryId');
  static Key retryKey(String entryId) => Key('stuck_sync_ops.retry_$entryId');
  static Key discardKey(String entryId) =>
      Key('stuck_sync_ops.discard_$entryId');

  final SyncRecovery recovery;

  @override
  Widget build(BuildContext context) => BlocProvider<StuckSyncOpsBloc>(
    create: (_) => StuckSyncOpsBloc(recovery: recovery),
    child: const _StuckSyncOpsView(),
  );
}

class _StuckSyncOpsView extends StatelessWidget {
  const _StuckSyncOpsView();

  @override
  Widget build(BuildContext context) {
    final l10n = SyncLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return BlocBuilder<StuckSyncOpsBloc, StuckSyncOpsState>(
      builder: (context, state) {
        final ops = switch (state) {
          StuckSyncOpsReady(:final ops) => ops,
          _ => const <StuckSyncOp>[],
        };
        return BgePage.slivers(
          title: Text(l10n.syncStuckTitle),
          width: BgePageWidth.pane,
          semanticChildCount: ops.isEmpty ? null : ops.length,
          slivers: [
            if (state case StuckSyncOpsReady(:final problem?))
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: switch (problem) {
                    StuckSyncOpsProblem.actionFailed => BgeInlineBanner(
                      key: StuckSyncOpsScreen.actionFailedKey,
                      tone: BgeBannerTone.error,
                      message: l10n.syncStuckActionFailed,
                    ),
                    // Warning, not error: nothing failed on this device, and
                    // the change is still there to retry or discard.
                    StuckSyncOpsProblem.refusedAgain => BgeInlineBanner(
                      key: StuckSyncOpsScreen.refusedAgainKey,
                      tone: BgeBannerTone.warning,
                      message: l10n.syncStuckRefusedAgain,
                    ),
                  },
                ),
              ),
            switch (state) {
              StuckSyncOpsLoading() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  key: StuckSyncOpsScreen.loadingKey,
                  child: Semantics(
                    liveRegion: true,
                    label: l10n.syncStuckLoading,
                    child: const ExcludeSemantics(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
              StuckSyncOpsError() => SliverToBoxAdapter(
                child: BgeInlineBanner(
                  key: StuckSyncOpsScreen.errorKey,
                  tone: BgeBannerTone.error,
                  message: l10n.syncStuckError,
                ),
              ),
              StuckSyncOpsReady(:final ops) when ops.isEmpty =>
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    key: StuckSyncOpsScreen.emptyKey,
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.syncStuckEmpty,
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              StuckSyncOpsReady() => SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceSm),
                  child: Text(l10n.syncStuckIntro),
                ),
              ),
            },
            // Its own sliver, after the intro rather than holding it, so the
            // list's children are the rows alone and a screen reader counts
            // them against [semanticChildCount].
            if (state case StuckSyncOpsReady(:final ops, :final busy)
                when ops.isNotEmpty)
              SliverList.list(
                children: [
                  // Keyed here, on the list's own child, so a row keeps its
                  // controls and their focus when a row above it leaves.
                  for (final op in ops)
                    _StuckRow(
                      key: StuckSyncOpsScreen.rowKey(op.entryId),
                      op: op,
                      busy: busy.contains(op.entryId),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _StuckRow extends StatelessWidget {
  const _StuckRow({required this.op, required this.busy, super.key});

  final StuckSyncOp op;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = SyncLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final bloc = context.read<StuckSyncOpsBloc>();

    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // One node for the description and its status, read together.
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _describe(l10n, op),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const BgeGap.xs(),
                const _StuckBadge(),
              ],
            ),
          ),
          // A Wrap, not a Row, so the two buttons stack rather than
          // overflow at large text on a narrow window.
          Wrap(
            spacing: tokens.spaceSm,
            children: [
              // A payload this build can't read would only be counted again,
              // never sent, so retrying it offers nothing.
              if (op.kind != StuckSyncOpKind.unreadable)
                TextButton(
                  key: StuckSyncOpsScreen.retryKey(op.entryId),
                  // Disabled, not removed, while it runs, and relabelled
                  // rather than a bare spinner, so focus stays put and the
                  // control still says what it is doing.
                  onPressed: busy
                      ? null
                      : () => bloc.add(StuckSyncOpsRetryRequested(op.entryId)),
                  child: Text(
                    busy ? l10n.syncStuckRetrying : l10n.syncStuckRetry,
                  ),
                ),
              TextButton(
                key: StuckSyncOpsScreen.discardKey(op.entryId),
                onPressed: busy
                    ? null
                    : () async {
                        if (await _confirmDiscard(context, op.kind)) {
                          bloc.add(StuckSyncOpsDiscardRequested(op.entryId));
                        }
                      },
                child: Text(l10n.syncStuckDiscard),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _describe(SyncLocalizations l10n, StuckSyncOp op) {
    final subject = op.subject;
    return switch (op.kind) {
      StuckSyncOpKind.addToCollection =>
        subject == null
            ? l10n.syncStuckAddToCollectionUnnamed
            : l10n.syncStuckAddToCollection(subject),
      StuckSyncOpKind.updateCollection =>
        subject == null
            ? l10n.syncStuckUpdateCollectionUnnamed
            : l10n.syncStuckUpdateCollection(subject),
      StuckSyncOpKind.removeFromCollection =>
        subject == null
            ? l10n.syncStuckRemoveFromCollectionUnnamed
            : l10n.syncStuckRemoveFromCollection(subject),
      // A household's name is required, so a create always carries one.
      StuckSyncOpKind.createHousehold => l10n.syncStuckCreateHousehold(
        subject ?? '',
      ),
      StuckSyncOpKind.unreadable => l10n.syncStuckUnreadable,
    };
  }

  static Future<bool> _confirmDiscard(
    BuildContext context,
    StuckSyncOpKind kind,
  ) async {
    final l10n = SyncLocalizations.of(context);
    // An add or a removal goes with the changes to the game queued after it
    // ([GameCollectionRepository.discardQueuedOp]).
    final body = switch (kind) {
      StuckSyncOpKind.addToCollection || StuckSyncOpKind.removeFromCollection =>
        l10n.syncStuckDiscardBodyWithLater,
      StuckSyncOpKind.updateCollection ||
      StuckSyncOpKind.createHousehold ||
      StuckSyncOpKind.unreadable => l10n.syncStuckDiscardBody,
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.syncStuckDiscardTitle),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.syncStuckDiscardCancel),
          ),
          TextButton(
            key: StuckSyncOpsScreen.discardConfirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(l10n.syncStuckDiscardConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

/// "Couldn't sync", with the icon that carries the state alongside its
/// colour.
class _StuckBadge extends StatelessWidget {
  const _StuckBadge();

  @override
  Widget build(BuildContext context) {
    final l10n = SyncLocalizations.of(context);
    final theme = Theme.of(context);
    final color = BgeStatusColors.of(context).conflict;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          BgeStatusColors.iconFor(BgeStatus.conflict),
          // Scales with its label, as the household list's badge does.
          size: MediaQuery.textScalerOf(context)
              .scale(theme.textTheme.labelMedium?.fontSize ?? 0),
          color: color,
        ),
        const BgeGap.xs(axis: Axis.horizontal),
        Flexible(
          child: Text(
            l10n.syncStuckStatus,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
