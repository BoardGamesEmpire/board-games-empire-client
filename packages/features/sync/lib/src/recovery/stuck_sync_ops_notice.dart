import 'package:flutter/material.dart';
import 'package:interfaces/repositories.dart';
import 'package:ui/ui.dart';

import 'package:sync_queue/l10n/sync_localizations.dart';

/// Says how many changes couldn't sync, and leads to the screen where each
/// can be retried or discarded (#190). Shows nothing while none are stuck.
///
/// Warning tone, not error: nothing the user did failed, and nothing is
/// lost. The changes wait until the user acts on them.
///
/// Takes the session's [queue] rather than a stream, so a rebuild with the
/// same queue keeps its subscription, and a new session's queue gets a new
/// one.
class StuckSyncOpsNotice extends StatefulWidget {
  const StuckSyncOpsNotice({
    required this.queue,
    required this.onReview,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  static const Key bannerKey = Key('stuck_sync_ops_notice.banner');
  static const Key reviewKey = Key('stuck_sync_ops_notice.review');

  final SyncQueueRepository queue;

  /// Opens the retry-or-discard screen.
  final void Function(BuildContext context) onReview;

  /// Around the banner while it shows, so the space it takes goes with it.
  final EdgeInsetsGeometry padding;

  @override
  State<StuckSyncOpsNotice> createState() => _StuckSyncOpsNoticeState();
}

class _StuckSyncOpsNoticeState extends State<StuckSyncOpsNotice> {
  late Stream<int> _count;

  @override
  void initState() {
    super.initState();
    _count = _watch();
  }

  @override
  void didUpdateWidget(StuckSyncOpsNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.queue, widget.queue)) _count = _watch();
  }

  // Distinct, so the many queue writes that leave the count as it was
  // rebuild nothing.
  Stream<int> _watch() => widget.queue
      .watchStuckEntries()
      .map((entries) => entries.length)
      .distinct();

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
    stream: _count,
    builder: (context, snapshot) {
      // A read that fails says nothing is stuck rather than something wrong:
      // the screen it leads to reports its own read.
      final stuck = snapshot.hasError ? 0 : snapshot.data ?? 0;
      if (stuck == 0) return const SizedBox.shrink();
      final l10n = SyncLocalizations.of(context);
      return Padding(
        padding: widget.padding,
        child: BgeInlineBanner(
          key: StuckSyncOpsNotice.bannerKey,
          tone: BgeBannerTone.warning,
          message: l10n.syncStuckNotice(stuck),
          action: TextButton(
            key: StuckSyncOpsNotice.reviewKey,
            onPressed: () => widget.onReview(context),
            child: Text(l10n.syncStuckNoticeAction),
          ),
        ),
      );
    },
  );
}
