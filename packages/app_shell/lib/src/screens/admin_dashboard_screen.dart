import 'dart:async';

import 'package:flutter/material.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';
import '../admin/admin_section.dart';

/// The admin dashboard at `/admin` (#684): the sections the caller's access
/// shows, each opening its own screens beneath it.
///
/// Decoupled from DI like the feature screens: the composition hands in the
/// [sections], already localized and routed, and the session's [access].
///
/// ## What it shows
///
/// - **Each section whose `read` is all** ([visibleAdminSections]), as a row
///   with its icon, title and summary, in the order given. No counts: each
///   section has a screen of its own.
/// - **While the answer is unknown, loading**, and it asks [access] again,
///   once. The drawer hides its entry until the answer is known, so this is
///   reached only from a deep link, a web reload, or a session whose answer
///   hasn't landed. If that ask ends and the answer is still unknown, it says
///   it couldn't check, with a retry that asks again.
/// - **Once the answer is known and shows no section, a refusal** with a way
///   home. So does a composition with no [access] to ask, which shows none.
///
/// It follows [access] as its answer changes, so a section comes and goes
/// while the dashboard is open.
///
/// ## Focus
///
/// A row that leaves with keyboard focus hands it on, rather than leaving it
/// to fall back on whatever had it before: to the next row still listed,
/// else the row before it, else the page's heading, which is no Tab stop but
/// is always there. The last row leaving shows the refusal, with focus on
/// the heading.
///
/// A row usually leaves while its section covers the dashboard: the section
/// is refused, asks the access again, and the answer takes the row away
/// underneath. When the row the page would give focus back to has left, the
/// return hands focus on the same way, once the section has gone. So does
/// the row opened, when the page has no row to give focus back to: a screen
/// reader's double tap opens a row without focusing it. Focus the user moves
/// on the way back is left where they put it.
///
/// Retry, which goes with the failure as the ask starts, hands its focus to
/// the heading.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({
    required this.sections,
    required this.onGoHome,
    this.access,
    super.key,
  });

  static const Key loadingKey = Key('admin_dashboard.loading');
  static const Key failedKey = Key('admin_dashboard.failed');
  static const Key refusedKey = Key('admin_dashboard.refused');

  /// Per-entry key: `admin_dashboard.entry_<id>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key entryKey(String id) => Key('admin_dashboard.entry_$id');

  /// Every section the composition offers, in the order to list them. Only
  /// those [access] shows are listed.
  final List<AdminSection> sections;

  /// The session's access, or null for a composition without one, which
  /// shows no section.
  final CallerAccessRepository? access;

  /// Leaves for home, from the refusal.
  final void Function(BuildContext context) onGoHome;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

/// What the page shows in place of, or as, its list.
enum _Shows { loading, failed, refused, sections }

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  /// On the page's heading, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'admin dashboard heading',
    skipTraversal: true,
  );

  /// Each listed row's own node, by section id. A row's node outlives the
  /// frame that takes the row away, since its `Focus` holds it until then.
  final Map<String, FocusNode> _entries = {};

  /// This page's route.
  ModalRoute<Object?>? _route;

  /// Whether [_route] was the navigator's top one when last built. False
  /// while a section, or anything else, covers the dashboard.
  bool _current = true;

  /// [_route]'s secondary animation, which runs as a route above it comes in
  /// and goes.
  Animation<double>? _above;

  /// The row whose tap opened the route above, until the page is back on
  /// top. A screen reader's double tap moves no input focus, so the page's
  /// focus can't tell which row that was.
  String? _opened;

  /// A hand-off owed to the page's return: the row the page would give focus
  /// back to left while a route covered it. Then the rows to try, nearest
  /// first, as [_handOff] tries them.
  List<String>? _onReturn;

  /// Where the pop puts focus: the page's last focus that is still attached,
  /// read once the frame that took the row away has drawn. Null for none,
  /// and then the pop puts it on the page itself.
  FocusNode? _restored;

  StreamSubscription<CallerAccess>? _changes;

  /// The latest answer from [AdminDashboardScreen.access].
  CallerAccess _answer = const CallerAccess.unknown();

  /// Whether an ask this screen made is still out.
  bool _asking = false;

  /// Counts the asks this screen made, so only the latest one's end counts.
  int _asks = 0;

  @override
  void initState() {
    super.initState();
    _follow(widget.access);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = _route = ModalRoute.of(context);
    final above = route?.secondaryAnimation;
    if (!identical(above, _above)) {
      _above?.removeStatusListener(_onAboveChanged);
      _above = above?..addStatusListener(_onAboveChanged);
    }
    final current = route?.isCurrent ?? true;
    if (current == _current) return;
    _current = current;
    // A pop-up above runs no secondary animation, so it has gone once the
    // page is the top route again.
    if (current && (above?.isDismissed ?? true)) _settleReturnAfterFrame();
  }

  /// Whether a route covers the page.
  bool get _covered => !(_route?.isCurrent ?? true);

  /// A page above has gone once the animation it ran here is dismissed.
  void _onAboveChanged(AnimationStatus status) {
    if (status.isDismissed && !_covered) _settleReturnAfterFrame();
  }

  @override
  void didUpdateWidget(AdminDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // [widget] is the new one already.
    final before = visibleAdminSections(_answer, oldWidget.sections);
    final access = widget.access;
    if (access != oldWidget.access) {
      unawaited(_changes?.cancel());
      _follow(access);
    }
    _handOff(from: before);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _above?.removeStatusListener(_onAboveChanged);
    _heading.dispose();
    for (final node in _entries.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Reads [access]'s answer, follows it from here on, and asks it again if
  /// it doesn't know yet.
  void _follow(CallerAccessRepository? access) {
    _changes = access?.changes.listen(
      (answer) => _change(() => _answer = answer),
    );
    _answer = access?.current ?? const CallerAccess.unknown();
    // An ask made of a repository this screen no longer follows is dropped.
    _asks++;
    _asking = false;
    if (access != null && !_answer.isKnown) _ask(access);
  }

  /// Asks [access] again. The answer arrives through its changes, or is
  /// there to read when the ask ends; if it still isn't, the page says so.
  void _ask(CallerAccessRepository access) {
    final ask = ++_asks;
    _asking = true;
    unawaited(
      access.refresh().then((_) {
        if (!mounted || ask != _asks) return;
        _change(() {
          _asking = false;
          _answer = access.current;
        });
      }),
    );
  }

  void _retry() {
    final access = widget.access;
    if (access == null) return;
    // Retry goes as the ask starts, and would take focus with it.
    _heading.requestFocus();
    setState(() => _ask(access));
  }

  /// The sections listed now.
  List<AdminSection> get _listed =>
      visibleAdminSections(_answer, widget.sections);

  _Shows get _shows {
    if (widget.access == null) return _Shows.refused;
    if (_answer.isKnown) {
      return _listed.isEmpty ? _Shows.refused : _Shows.sections;
    }
    return _asking ? _Shows.loading : _Shows.failed;
  }

  /// Applies [change], and hands on the focus of a row it takes away.
  void _change(VoidCallback change) {
    final before = _listed;
    setState(change);
    _handOff(from: before);
  }

  FocusNode _entryNode(String id) =>
      _entries.putIfAbsent(id, () => FocusNode(debugLabel: 'admin entry $id'));

  /// When a row in [from] is no longer listed and has keyboard focus, hands
  /// it on after the frame that takes the row away, and forgets the nodes of
  /// rows gone by then.
  ///
  /// Runs before that frame, while the row still has focus. Not if the user
  /// has moved focus meanwhile, nor if the row is listed again by then.
  ///
  /// While a route covers the page, no row has focus. One the page would give
  /// focus back to on return is owed a hand-off then instead.
  void _handOff({required List<AdminSection> from}) {
    final listed = {for (final section in _listed) section.id};
    if (from.every((section) => listed.contains(section.id))) return;

    _afterFrame(_forgetRowsGone);
    final gone = from.indexWhere(
      (section) =>
          !listed.contains(section.id) &&
          (_entries[section.id]?.hasFocus ?? false),
    );
    if (gone < 0) {
      if (_covered) _oweReturn(from: from, listed: listed);
      return;
    }

    final goneId = from[gone].id;
    final candidates = _around(from, gone);
    final focused = FocusManager.instance.primaryFocus;
    _afterFrame(() {
      if (!mounted || !focusIsFree(context, untouched: focused)) return;
      // Back before this frame, so it never went, and kept its focus.
      if (_listed.any((section) => section.id == goneId)) return;
      _focus(_firstBuilt(candidates));
    });
  }

  /// The ids of the rows around [from]'s row at [index]: those after it,
  /// nearest first, then those before it.
  static List<String> _around(List<AdminSection> from, int index) => [
    for (var i = index + 1; i < from.length; i++) from[i].id,
    for (var i = index - 1; i >= 0; i--) from[i].id,
  ];

  /// The node of the first of [ids] that is listed and built, else the
  /// heading's. A row's node takes focus only while the row is built.
  FocusNode _firstBuilt(Iterable<String> ids) {
    final now = {for (final section in _listed) section.id};
    return ids
            .where(now.contains)
            .map((id) => _entries[id])
            .firstWhere((node) => node?.parent != null, orElse: () => null) ??
        _heading;
  }

  /// While a route covers the page, as a section the user opened does: when
  /// the row in [from] that the page would give focus back to is no longer
  /// listed, owes a hand-off for when the page is back on top.
  ///
  /// The usual way a row leaves: its section is refused, asks the access
  /// again, and the answer takes the row away underneath. The pop would give
  /// focus back to the page's focus before the row, the back button or the
  /// page itself, which gives a screen reader nothing to say.
  void _oweReturn({
    required List<AdminSection> from,
    required Set<String> listed,
  }) {
    final returning = FocusScope.of(
      context,
      createDependency: false,
    ).focusedChild;
    // The row the page gives focus back to, else, when that is no row, the
    // row opened: a screen reader's double tap opens it without focusing it.
    final returningRow = from.indexWhere(
      (section) => identical(_entries[section.id], returning),
    );
    final gone = returningRow >= 0
        ? (listed.contains(from[returningRow].id) ? -1 : returningRow)
        : from.indexWhere(
            (section) => section.id == _opened && !listed.contains(section.id),
          );
    // The row itself first: listed again by the return, it is where the user
    // left off. A row the page would give focus back to after that one went
    // is not, so the first row owed stays owed.
    if (gone >= 0) _onReturn ??= [from[gone].id, ..._around(from, gone)];
    if (_onReturn == null) return;
    // Read once the row's node has left the page's focus history, and again
    // after every row that goes, which may be the one read before.
    _afterFrame(() {
      if (!mounted) return;
      _restored = FocusScope.of(context, createDependency: false).focusedChild;
    });
  }

  /// Settles a hand-off owed to the return after the next frame, by when the
  /// pop has given focus back to the page.
  void _settleReturnAfterFrame() {
    _opened = null;
    if (_onReturn != null) _afterFrame(_settleReturn);
  }

  /// Back on top, hands focus on from where the pop put it to the row owed
  /// it, else the next row, else the one before, else the heading. Not if
  /// the user has moved focus since.
  void _settleReturn() {
    final owed = _onReturn;
    final restored = _restored;
    _onReturn = null;
    _restored = null;
    if (owed == null || !mounted) return;
    if (!focusIsFree(context, untouched: restored)) return;
    _focus(_firstBuilt(owed));
  }

  /// Puts focus on [target], bringing it into view for a user who can see
  /// focus.
  void _focus(FocusNode target) {
    target.requestFocus();
    if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      target.context?.findRenderObject()?.showOnScreen();
    }
  }

  /// Runs [callback] after the next frame, and asks for one: a post-frame
  /// callback doesn't.
  void _afterFrame(VoidCallback callback) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => callback())
      ..ensureVisualUpdate();
  }

  /// Disposes the nodes of rows no longer listed, once the frame that takes
  /// them down has drawn: a [Focus] holds its node until then.
  void _forgetRowsGone() {
    if (!mounted) return;
    final listed = {for (final section in _listed) section.id};
    final gone = [
      for (final id in _entries.keys)
        if (!listed.contains(id)) id,
    ];
    for (final id in gone) {
      _entries.remove(id)?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final listed = _listed;
    final shows = _shows;

    return BgePage.slivers(
      title: Focus(focusNode: _heading, child: Text(l10n.adminDashboardTitle)),
      width: BgePageWidth.pane,
      semanticChildCount: shows == _Shows.sections ? listed.length : null,
      slivers: [
        switch (shows) {
          _Shows.loading => BgeStateSliver(
            child: BgeLoadingState(
              key: AdminDashboardScreen.loadingKey,
              label: l10n.adminDashboardLoading,
            ),
          ),
          _Shows.failed => BgeStateSliver(
            child: BgeErrorState(
              key: AdminDashboardScreen.failedKey,
              icon: Icons.cloud_off_outlined,
              title: l10n.adminDashboardFailedTitle,
              body: l10n.adminDashboardFailedBody,
              retryLabel: l10n.adminDashboardRetry,
              onRetry: _retry,
            ),
          ),
          _Shows.refused => BgeStateSliver(
            child: BgeEmptyState(
              key: AdminDashboardScreen.refusedKey,
              icon: Icons.lock_outline,
              title: l10n.adminDashboardRefused,
              action: FilledButton(
                onPressed: () => widget.onGoHome(context),
                child: Text(l10n.adminDashboardGoHome),
              ),
            ),
          ),
          _Shows.sections => BgeKeyedSliverList<AdminSection>(
            items: listed,
            keyOf: (section) => AdminDashboardScreen.entryKey(section.id),
            itemBuilder: (context, section) => _Entry(
              section: section,
              focusNode: _entryNode(section.id),
              onOpen: (context) {
                _opened = section.id;
                section.onOpen(context);
              },
            ),
          ),
        },
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.section,
    required this.focusNode,
    required this.onOpen,
  });

  final AdminSection section;

  /// The row's own, which a row that leaves hands its focus to.
  final FocusNode focusNode;

  /// Opens [section], noting which row opened it.
  final void Function(BuildContext context) onOpen;

  @override
  Widget build(BuildContext context) => ListTile(
    focusNode: focusNode,
    leading: Icon(section.icon),
    title: Text(section.title),
    subtitle: Text(section.summary),
    onTap: () => onOpen(context),
  );
}
