import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

import '../bloc/data_gateway_detail_bloc.dart';
import '../bloc/data_gateway_detail_event.dart';
import '../bloc/data_gateway_detail_state.dart';
import '../bloc/language_link_list_bloc.dart';
import '../bloc/language_link_list_event.dart';
import '../bloc/language_link_list_state.dart';
import '../widgets/data_gateway_message.dart';
import '../widgets/data_gateway_status.dart';
import '../widgets/focus_is_free.dart';
import '../widgets/language_link_worklist.dart';

/// One DataGateway's own page (#457): its name, whether the server uses it and
/// why not, how its interviews and lists went, a switch for each thing it can
/// do, and the language names it uses that are left to review.
///
/// Decoupled from DI like the list screen: the caller resolves the per-server
/// [DataGatewayRemoteDataSource] and the session's [CallerAccessRepository].
/// The screen takes an id rather than a row, and reads the row itself.
///
/// The row and the worklist are read again whenever the screen comes back into
/// view, and from the refresh control. [DataGatewayDetailBloc] and
/// [LanguageLinkListBloc] each say how a read and an action that overlap
/// settle.
///
/// The worklist ([LanguageLinkWorklist]) shows while the row does, and has
/// surfaces of its own for its own reads. The row's other surfaces take the
/// screen. A worklist found gone asks for the row again, and if that finds the
/// DataGateway gone too, the gone surface takes the screen.
///
/// The name heads the page as well as the app bar, which cuts a long one short:
/// at 200% text on a phone, to a few letters.
///
/// ## What an action answered
///
/// Both banners are in the page's footer: what an action on the DataGateway
/// answered, then what an action on a language link answered, each with its
/// own Dismiss. A footer is always built and always on screen, so a banner
/// there is seen and announced wherever the user is working on a long page,
/// and its coming and going moves no control. At the head of the page, the
/// banner for a switch far down took the page to the top, and the next action
/// took it away and moved every switch up under the pointer. Among the
/// worklist's rows, the banner wasn't built once the user had scrolled away.
///
/// A banner stays up until the next action answers, not just until it starts.
/// Taken down at the start, it came back at the answer, and the view's foot
/// went and came with it through every action. With the page at its end,
/// [BgePage.footer] keeps the room a banner leaves, so nothing drops under the
/// pointer when one goes. An answer that repeats the last is a new banner, or
/// it would go unsaid: a live region speaks only when it appears or changes.
///
/// ## Keeping keyboard focus
///
/// A disabled control gives up keyboard focus (#607), so a control stays
/// enabled through its own action and says it is busy some other way, and the
/// bloc settles a press made meanwhile:
///
/// - Through a capability write every switch stays enabled, and a bar at the
///   head of the capabilities is the busy cue. A switch pressed then goes when
///   the write has answered, and shows what the server answers then. The
///   interview button pressed then does too, and changes its label at once.
/// - Through an interview its button stays enabled and changes its label. The
///   switches do stop taking presses: an interview starts from the button, so
///   focus is not on a switch, and up to a minute of presses that go nowhere
///   would mislead.
/// - Access falling takes the interview button away and stops the switches,
///   whenever the session's answer changes, and a row found disabled takes the
///   button away, whichever read or action found it. Left to go with the
///   control, focus would land on whatever had it before. So if that control
///   had focus, it goes to the banner's Dismiss, or with no banner to the first
///   switch still taking presses, or else to refresh. A refusal takes nothing
///   away by itself, so the control keeps focus through it, as through any
///   other answer, until access answers.
/// - The banner takes room from the foot of the view as it arrives. A switch
///   with focus that it covers is brought back into view, as Tab would, for a
///   user who can see focus.
///
/// A control also loses focus when the tree under it is rebuilt, so what comes
/// and goes keeps the rest in place: the bar has a slot of its own whether it
/// shows or not, and each switch is keyed.
///
/// ## Access
///
/// The interview button shows, and the switches take presses, while the
/// caller's access allows update (#456). While the answer is unknown they
/// don't, and nothing is said about the role. They come and go as the answer
/// changes, without reading the row again.
///
/// A refused read is the access-denied surface, with nothing to act on. A
/// refused change says why in the banner. Both ask the session's access
/// again, and the controls follow its answer.
class DataGatewayDetailScreen extends StatelessWidget {
  const DataGatewayDetailScreen({
    required this.remote,
    required this.id,
    this.access,
    super.key,
  });

  static const Key loadingKey = Key('data_gateway_detail.loading');
  static const Key deniedKey = Key('data_gateway_detail.denied');
  static const Key goneKey = Key('data_gateway_detail.gone');
  static const Key errorKey = Key('data_gateway_detail.error');
  static const Key outcomeKey = Key('data_gateway_detail.outcome');
  static const Key nameKey = Key('data_gateway_detail.name');
  static const Key interviewKey = Key('data_gateway_detail.interview');
  static const Key refreshKey = Key('data_gateway_detail.refresh');

  /// On the [DataGatewayStatusLine]. A disabled DataGateway has none.
  static const Key statusKey = Key('data_gateway_detail.status');

  /// One capability's switch, by the server's own spelling of its name.
  static Key capabilityKey(String capability) =>
      Key('data_gateway_detail.capability_$capability');

  /// One list's row under the Lists heading, by the server's own spelling of
  /// its capability.
  static Key sectionKey(String capability) =>
      Key('data_gateway_detail.section_$capability');

  final DataGatewayRemoteDataSource remote;

  /// The DataGateway to show.
  final String id;

  /// The session's access, or null for a composition without one, which
  /// offers no change.
  final CallerAccessRepository? access;

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    // Keyed on the row: go_router keys a page by its path pattern, so going
    // from one DataGateway's location straight to another rebuilds this screen
    // in place. A new id has to start new blocs, or the screen would show the
    // first row under the second's URL, and write to the first.
    key: ValueKey<String>(id),
    providers: [
      BlocProvider<DataGatewayDetailBloc>(
        create: (_) =>
            DataGatewayDetailBloc(remote: remote, id: id, access: access)
              ..add(const DataGatewayDetailLoadRequested()),
      ),
      BlocProvider<LanguageLinkListBloc>(
        create: (_) =>
            LanguageLinkListBloc(remote: remote, gatewayId: id, access: access)
              ..add(const LanguageLinkListLoadRequested()),
      ),
    ],
    child: BlocListener<LanguageLinkListBloc, LanguageLinkListState>(
      // A 404 on the worklist may mean the DataGateway itself is gone. Reading
      // the row finds out, and its answer takes the screen.
      listenWhen: (_, state) => state is LanguageLinkListGone,
      listener: (context, _) => context.read<DataGatewayDetailBloc>().add(
        const DataGatewayDetailLoadRequested(),
      ),
      // Reads what the screen shows again when it comes back into view, so it
      // covers whatever was opened over it.
      child: Builder(
        builder: (context) => ReadAgainWhenUncovered(
          onUncovered: () => _readAgain(context),
          child: _DataGatewayDetailView(remote: remote),
        ),
      ),
    ),
  );
}

/// Reads what the screen shows from the server again: on coming back into
/// view, on a refresh and on a retry.
void _readAgain(BuildContext context) {
  context.read<DataGatewayDetailBloc>().add(
    const DataGatewayDetailLoadRequested(),
  );
  context.read<LanguageLinkListBloc>().add(
    const LanguageLinkListLoadRequested(),
  );
}

class _DataGatewayDetailView extends StatefulWidget {
  const _DataGatewayDetailView({required this.remote});

  final DataGatewayRemoteDataSource remote;

  @override
  State<_DataGatewayDetailView> createState() => _DataGatewayDetailViewState();
}

class _DataGatewayDetailViewState extends State<_DataGatewayDetailView> {
  /// Around the interview button and the switches, so the footer can tell
  /// whether one of them has focus. It takes none itself.
  final FocusNode _controls = FocusNode(
    debugLabel: 'data gateway controls',
    canRequestFocus: false,
    skipTraversal: true,
  );

  final FocusNode _interview = FocusNode(debugLabel: 'data gateway interview');
  final FocusNode _refresh = FocusNode(debugLabel: 'data gateway refresh');

  @override
  void dispose() {
    _controls.dispose();
    _interview.dispose();
    _refresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return BlocBuilder<DataGatewayDetailBloc, DataGatewayDetailState>(
      builder: (context, state) {
        final ready = state is DataGatewayDetailReady ? state : null;
        final worklistRows = context.select<LanguageLinkListBloc, int?>(
          (bloc) => switch (bloc.state) {
            LanguageLinkListReady(:final links) when links.isNotEmpty =>
              links.length,
            _ => null,
          },
        );
        final inset = BgeTokens.of(context).spaceLg;

        return BgePage.slivers(
          title: Text(ready?.gateway.name ?? l10n.dataGatewayListTitle),
          width: BgePageWidth.pane,
          // "Language name 3 of 50": only the worklist's rows are counted, and
          // only while it shows.
          semanticChildCount: ready == null ? null : worklistRows,
          // The bottom inset ends the slivers instead. The page would put it
          // around the footer, which would then be a band with nothing in it.
          padding: EdgeInsets.fromLTRB(inset, inset, inset, 0),
          // On every build, in every state: see the footer's doc.
          footer: _OutcomeFooter(
            controls: _controls,
            interview: _interview,
            refresh: _refresh,
          ),
          actions: [
            // On every surface but denied, which has nothing to act on. That
            // includes the spinner, so a refresh that takes the row down, or
            // starts over from a failure, leaves focus where it was. It is
            // also the only way to read again from the gone surface.
            if (state is! DataGatewayDetailDenied)
              IconButton(
                key: DataGatewayDetailScreen.refreshKey,
                focusNode: _refresh,
                tooltip: l10n.dataGatewayDetailRefresh,
                icon: const Icon(Icons.refresh),
                onPressed: () => _readAgain(context),
              ),
          ],
          slivers: [
            // A group of its own, so that Tab and Shift-Tab go through the page
            // as a block. Reading order goes by height alone, which would stop
            // at the footer's Dismiss among the rows built below the fold, and
            // at the app bar's refresh among those above the view.
            FocusTraversalGroup(
              child: SliverMainAxisGroup(
                slivers: [
                  ...switch (state) {
                    DataGatewayDetailLoading() => [
                      _LoadingSliver(message: l10n.dataGatewayDetailLoading),
                    ],
                    DataGatewayDetailDenied() => [
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: DataGatewayMessage(
                            key: DataGatewayDetailScreen.deniedKey,
                            icon: Icons.lock_outline,
                            title: l10n.dataGatewayDeniedTitle,
                            body: l10n.dataGatewayDeniedBody,
                          ),
                        ),
                      ),
                    ],
                    DataGatewayDetailGone() => [
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: DataGatewayMessage(
                            key: DataGatewayDetailScreen.goneKey,
                            icon: Icons.search_off_outlined,
                            title: l10n.dataGatewayDetailGoneTitle,
                            body: l10n.dataGatewayDetailGoneBody,
                          ),
                        ),
                      ),
                    ],
                    DataGatewayDetailFailed() => [
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: BgeErrorState(
                            key: DataGatewayDetailScreen.errorKey,
                            icon: Icons.cloud_off_outlined,
                            title: l10n.dataGatewayDetailErrorTitle,
                            body: l10n.dataGatewayDetailErrorBody,
                            retryLabel: l10n.dataGatewayRetry,
                            onRetry: () => _readAgain(context),
                          ),
                        ),
                      ),
                    ],
                    DataGatewayDetailReady(
                      :final gateway,
                      :final mayUpdate,
                      :final busy,
                      :final interviewWaiting,
                    ) =>
                      [
                        _NameHeading(name: gateway.name),
                        _StatusSection(gateway: gateway),
                        Focus(
                          focusNode: _controls,
                          // A sliver can't sit under the box Focus otherwise
                          // puts around its child for semantics.
                          includeSemantics: false,
                          child: SliverMainAxisGroup(
                            slivers: [
                              _InterviewSection(
                                gateway: gateway,
                                mayUpdate: mayUpdate,
                                focusNode: _interview,
                                interviewing:
                                    busy == DataGatewayDetailBusy.interview ||
                                    interviewWaiting,
                              ),
                              _ListsSection(gateway: gateway),
                              _CapabilitiesSection(
                                gateway: gateway,
                                mayUpdate: mayUpdate,
                                busy: busy,
                                interviewWaiting: interviewWaiting,
                              ),
                            ],
                          ),
                        ),
                        LanguageLinkWorklist(remote: widget.remote),
                      ],
                  },
                  const SliverToBoxAdapter(child: BgeGap.lg()),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One block of the page, as a sliver of its own, with room after it.
class _Section extends StatelessWidget {
  const _Section({required this.children, this.heading});

  final String? heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final heading = this.heading;

    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (heading != null) ...[
              Semantics(
                header: true,
                child: Text(
                  heading,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const BgeGap.sm(),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

/// The DataGateway's name, whole, as the page's first heading.
///
/// The app bar cuts a long name short, and "BGG staging" and "BGG prod" can
/// read the same there (#457).
class _NameHeading extends StatelessWidget {
  const _NameHeading({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
      child: Semantics(
        header: true,
        child: Text(
          name,
          key: DataGatewayDetailScreen.nameKey,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
    ),
  );
}

/// Whether the DataGateway is switched on, and whether the server uses it yet.
class _StatusSection extends StatelessWidget {
  const _StatusSection({required this.gateway});

  final DataGateway gateway;

  @override
  Widget build(BuildContext context) => _Section(
    children: [
      // First because the line under it says nothing on a disabled DataGateway,
      // and the interview button is gone too: this is the only word on why
      // that one returns nothing.
      DataGatewayEnabledBadge(enabled: gateway.enabled),
      if (gateway.enabled) ...[
        const BgeGap.xs(),
        DataGatewayStatusLine(
          key: DataGatewayDetailScreen.statusKey,
          gateway: gateway,
        ),
      ],
    ],
  );
}

/// When the interviews ran, the current failure as the server says it, and the
/// button that runs another.
class _InterviewSection extends StatelessWidget {
  const _InterviewSection({
    required this.gateway,
    required this.mayUpdate,
    required this.focusNode,
    required this.interviewing,
  });

  final DataGateway gateway;

  /// Whether the caller's access allows update, which the button needs.
  final bool mayUpdate;
  final FocusNode focusNode;
  final bool interviewing;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final interview = gateway.interview;
    final first = interview.firstInterviewedAt;
    final last = interview.lastInterviewedAt;
    final failure = interview.failure;
    // One failure, so one severity: the tone the status line above gives it.
    final (failureIcon, failureColor) = dataGatewayInterviewFailureTone(
      Theme.of(context).colorScheme,
      interviewed: interview.interviewed,
    );

    return _Section(
      heading: l10n.dataGatewayInterviewHeading,
      children: [
        if (!interview.interviewed) Text(l10n.dataGatewayInterviewNever),
        if (first != null)
          Text(l10n.dataGatewayInterviewFirst(_when(context, first))),
        if (last != null)
          Text(l10n.dataGatewayInterviewLast(_when(context, last))),
        if (failure != null)
          DataGatewayIconAndWords(
            icon: failureIcon,
            color: failureColor,
            words: l10n.dataGatewayInterviewLastFailure(
              _when(context, failure.at),
              dataGatewayInterviewFailureLabel(l10n, failure.code),
            ),
          ),
        if (gateway.enabled && mayUpdate) ...[
          const BgeGap.md(),
          OutlinedButton(
            key: DataGatewayDetailScreen.interviewKey,
            focusNode: focusNode,
            // Enabled while its own interview runs, and the bloc settles a press
            // made meanwhile: see the screen's doc.
            onPressed: () => context.read<DataGatewayDetailBloc>().add(
              const DataGatewayDetailInterviewRequested(),
            ),
            child: Semantics(
              liveRegion: interviewing,
              child: Text(
                interviewing
                    ? l10n.dataGatewayInterviewing
                    : l10n.dataGatewayInterviewAgain,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The lists the server loads from this DataGateway, and how each last went.
///
/// A list switched off keeps its row, which says so: see
/// [dataGatewayListRows].
class _ListsSection extends StatelessWidget {
  const _ListsSection({required this.gateway});

  final DataGateway gateway;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final rows = dataGatewayListRows(gateway);

    return _Section(
      heading: l10n.dataGatewayListsHeading,
      children: [
        if (rows.isEmpty) Text(l10n.dataGatewayListsNone),
        for (final (:capability, :section, :switchedOff) in rows)
          _SectionRow(
            key: DataGatewayDetailScreen.sectionKey(capability),
            capability: capability,
            section: section,
            switchedOff: switchedOff,
          ),
      ],
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.capability,
    required this.section,
    required this.switchedOff,
    super.key,
  });

  final String capability;

  /// Null for a list whose job has not run since an interview: not loaded yet,
  /// and not a failure (#457).
  final DataGatewaySection? section;

  /// An admin switched the list off. Its row says that alone: how it last
  /// loaded is history while the server isn't loading it, and one line in
  /// place of the usual one or two keeps the switches below where they were.
  final bool switchedOff;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final loaded = switchedOff ? null : section?.lastLoadedAt;
    final failure = switchedOff ? null : section?.failure;

    // Content, not a control: with no onTap the tile is no focus stop, and it
    // reads as one node.
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(_capabilityLabel(l10n, capability)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loaded != null)
            Text(l10n.dataGatewaySectionLoaded(_when(context, loaded))),
          if (failure != null)
            DataGatewayIconAndWords(
              icon: Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
              words: l10n.dataGatewaySectionFailed(
                _when(context, failure.at),
                _sectionFailureLabel(l10n, failure.code),
              ),
            ),
          if (switchedOff)
            Text(l10n.dataGatewaySectionSwitchedOff)
          else if (loaded == null && failure == null)
            Text(l10n.dataGatewaySectionNotLoaded),
        ],
      ),
    );
  }
}

/// A switch for each capability the DataGateway declares or an admin switched
/// off.
class _CapabilitiesSection extends StatelessWidget {
  const _CapabilitiesSection({
    required this.gateway,
    required this.mayUpdate,
    required this.busy,
    required this.interviewWaiting,
  });

  final DataGateway gateway;

  /// Whether the caller's access allows update. Without it the switches show
  /// where each capability stands, and take no presses.
  final bool mayUpdate;
  final DataGatewayDetailBusy? busy;
  final bool interviewWaiting;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final names = dataGatewayCapabilityRows(gateway);
    // Not stopped by a write of their own, and the bloc settles a press made
    // meanwhile: see the screen's doc.
    final maySwitch =
        mayUpdate &&
        busy != DataGatewayDetailBusy.interview &&
        !interviewWaiting;

    return _Section(
      heading: l10n.dataGatewayCapabilitiesHeading,
      children: [
        _SavingBar(saving: busy == DataGatewayDetailBusy.capabilities),
        if (names.isEmpty) Text(l10n.dataGatewayCapabilitiesNone),
        for (final name in names)
          SwitchListTile(
            key: DataGatewayDetailScreen.capabilityKey(name),
            contentPadding: EdgeInsets.zero,
            title: Text(_capabilityLabel(l10n, name)),
            // What the server last answered, not what was last pressed: the
            // bar says a write is on its way.
            value: !gateway.disabledCapabilities.contains(name),
            onChanged: maySwitch
                ? (on) => context.read<DataGatewayDetailBloc>().add(
                    DataGatewayDetailCapabilitySwitched(name, on: on),
                  )
                : null,
          ),
      ],
    );
  }
}

/// The busy cue while a capability write runs.
///
/// Its slot keeps its height whether the bar shows or not, so the switches
/// don't move under the pointer that just pressed one.
class _SavingBar extends StatelessWidget {
  const _SavingBar({required this.saving});

  final bool saving;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: BgeTokens.of(context).spaceXs,
    child: saving
        ? Semantics(
            liveRegion: true,
            label: DataGatewayLocalizations.of(context)
                .dataGatewayCapabilitySaving,
            child: const ExcludeSemantics(child: LinearProgressIndicator()),
          )
        : null,
  );
}

/// What the last actions answered (#457), for the page's footer: the
/// DataGateway's own banner, then the worklist's.
///
/// See the screen's doc for why a footer. A banner here reveals itself only
/// within the footer's own scroll view, so the page doesn't move.
///
/// Given to the page on every build, whatever there is to show. [BgePage]
/// builds a different tree with a footer than without one, so a footer that
/// came and went would rebuild the page, and lose its scroll position and
/// focus. It renders nothing while neither has anything to report, and while
/// the DataGateway isn't showing, which the worklist shows only with. To leave
/// no band then, it pads itself only while it shows a banner, and the page
/// gives it no bottom inset of its own.
///
/// It also minds focus on the DataGateway's own controls as its banner
/// arrives, and when one of them goes, as the screen's doc says. And it counts
/// the answers, to make a banner new for each: see the screen's doc.
class _OutcomeFooter extends StatefulWidget {
  const _OutcomeFooter({
    required this.controls,
    required this.interview,
    required this.refresh,
  });

  /// Has focus while the interview button or a switch does.
  final FocusNode controls;

  /// The interview button's node.
  final FocusNode interview;

  /// The refresh control's node: what is left when no control of the
  /// DataGateway's is.
  final FocusNode refresh;

  @override
  State<_OutcomeFooter> createState() => _OutcomeFooterState();
}

class _OutcomeFooterState extends State<_OutcomeFooter> {
  /// The node of the Dismiss on the DataGateway's own banner.
  final FocusNode _dismiss = FocusNode(debugLabel: 'data gateway dismiss');

  /// The node of the Dismiss on the worklist's banner, so that it keeps focus
  /// when an answer makes the banner new.
  final FocusNode _linksDismiss = FocusNode(debugLabel: 'language dismiss');

  /// How many actions on the DataGateway have answered.
  int _ownAnswers = 0;

  /// How many actions on a language link have answered.
  int _linkAnswers = 0;

  @override
  void dispose() {
    _dismiss.dispose();
    _linksDismiss.dispose();
    super.dispose();
  }

  /// Whether the action [previous] was running has answered.
  static bool _ownAnswered(
    DataGatewayDetailState previous,
    DataGatewayDetailState current,
  ) =>
      previous is DataGatewayDetailReady &&
      current is DataGatewayDetailReady &&
      previous.busy != null &&
      current.busy == null;

  /// Whether one of the actions [previous] was running has answered.
  static bool _linkAnswered(
    LanguageLinkListState previous,
    LanguageLinkListState current,
  ) =>
      previous is LanguageLinkListReady &&
      current is LanguageLinkListReady &&
      current.busy.length < previous.busy.length;

  /// Whether [current] brings an outcome that wasn't showing.
  static bool _arrives(
    DataGatewayDetailState previous,
    DataGatewayDetailState current,
  ) =>
      current is DataGatewayDetailReady &&
      current.outcome != null &&
      !(previous is DataGatewayDetailReady &&
          previous.outcome == current.outcome);

  /// Whether [current] takes away a control [previous] showed: the caller's
  /// access no longer allows update (#456), or the row is now disabled.
  static bool _takesControlAway(
    DataGatewayDetailState previous,
    DataGatewayDetailState current,
  ) =>
      previous is DataGatewayDetailReady &&
      current is DataGatewayDetailReady &&
      ((previous.mayUpdate && !current.mayUpdate) ||
          (previous.gateway.enabled && !current.gateway.enabled));

  /// Runs before the frame that takes the control away, while it still has
  /// focus, and hands it on after that frame. Not if the user has moved focus
  /// meanwhile, and not if access has given the control back by then.
  void _onControlTakenAway(BuildContext context, DataGatewayDetailState state) {
    if (state is! DataGatewayDetailReady) return;
    // Without update every control goes or stops. With it, only the button
    // can have gone, with the row now disabled.
    final hadFocus = state.mayUpdate
        ? widget.interview.hasFocus
        : widget.controls.hasFocus;
    if (!hadFocus) return;
    final onInterview = widget.interview.hasFocus;
    final banner = state.outcome != null;
    final focused = FocusManager.instance.primaryFocus;
    final bloc = context.read<DataGatewayDetailBloc>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(this.context, untouched: focused)) return;
      final now = bloc.state;
      final back =
          now is DataGatewayDetailReady &&
          now.mayUpdate &&
          (!onInterview || now.gateway.enabled);
      if (back) return;
      if (banner) {
        _focusDismiss();
      } else {
        final next = widget.controls.traversalDescendants.firstOrNull;
        (next ?? widget.refresh).requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Puts focus on the Dismiss of the DataGateway's own banner.
  void _focusDismiss() {
    _dismiss.requestFocus();
    if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      // After the banner's own reveal, which brings its head into view. The
      // Dismiss is at its foot.
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealDismiss());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  /// Runs before the frame that builds the banner, while the control that had
  /// focus still has it.
  void _onArrival(BuildContext context, DataGatewayDetailState state) {
    if (!widget.controls.hasFocus) return;
    // A control access takes away is [_onControlTakenAway]'s.
    if (state is DataGatewayDetailReady && !state.mayUpdate) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.controls.hasFocus &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional) {
        // The banner took the foot of the view, which may cover it.
        FocusManager.instance.primaryFocus?.context
            ?.findRenderObject()
            ?.showOnScreen();
      }
    });
  }

  /// Brings the Dismiss into view within the footer, once the footer has
  /// stopped scrolling. A banner taller than the footer's half of the body
  /// scrolls inside it, and focus out of sight is focus lost.
  void _revealDismiss() {
    final dismiss = _dismiss.context;
    if (!mounted ||
        dismiss == null ||
        !dismiss.mounted ||
        !_dismiss.hasPrimaryFocus) {
      return;
    }
    final position = Scrollable.maybeOf(dismiss)?.position;
    if (position == null) return;
    final scrolling = position.isScrollingNotifier;
    if (scrolling.value) {
      void settled() {
        if (scrolling.value) return;
        scrolling.removeListener(settled);
        _revealDismiss();
      }

      scrolling.addListener(settled);
      return;
    }
    unawaited(
      Scrollable.ensureVisible(
        dismiss,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (shown, own) = context
        .select<DataGatewayDetailBloc, (bool, DataGatewayDetailOutcome?)>(
          (bloc) => switch (bloc.state) {
            DataGatewayDetailReady(:final outcome) => (true, outcome),
            _ => (false, null),
          },
        );
    final links = context.select<LanguageLinkListBloc, LanguageLinkOutcome?>(
      (bloc) => switch (bloc.state) {
        LanguageLinkListReady(:final outcome) => outcome,
        _ => null,
      },
    );
    final worklist = shown ? links : null;
    final tokens = BgeTokens.of(context);

    return MultiBlocListener(
      listeners: [
        BlocListener<DataGatewayDetailBloc, DataGatewayDetailState>(
          listenWhen: _ownAnswered,
          listener: (_, _) => setState(() => _ownAnswers++),
        ),
        BlocListener<LanguageLinkListBloc, LanguageLinkListState>(
          listenWhen: _linkAnswered,
          listener: (_, _) => setState(() => _linkAnswers++),
        ),
        BlocListener<DataGatewayDetailBloc, DataGatewayDetailState>(
          listenWhen: _arrives,
          listener: _onArrival,
        ),
        BlocListener<DataGatewayDetailBloc, DataGatewayDetailState>(
          listenWhen: _takesControlAway,
          listener: _onControlTakenAway,
        ),
      ],
      child: own == null && worklist == null
          ? const SizedBox.shrink()
          : Padding(
              padding: EdgeInsets.only(
                top: tokens.spaceSm,
                bottom: tokens.spaceLg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (own != null)
                    KeyedSubtree(
                      key: ValueKey('own $_ownAnswers'),
                      child: _OwnOutcomeBanner(
                        outcome: own,
                        dismissFocus: _dismiss,
                      ),
                    ),
                  if (own != null && worklist != null) const BgeGap.sm(),
                  if (worklist != null)
                    KeyedSubtree(
                      key: ValueKey('links $_linkAnswers'),
                      child: LanguageLinkOutcomeBanner(
                        outcome: worklist,
                        dismissFocus: _linksDismiss,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// What the last action on the DataGateway itself answered.
class _OwnOutcomeBanner extends StatelessWidget {
  const _OwnOutcomeBanner({required this.outcome, required this.dismissFocus});

  final DataGatewayDetailOutcome outcome;

  /// For the Dismiss, which takes focus from a control that goes while the
  /// banner shows.
  final FocusNode dismissFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    final (tone, message) = switch (outcome) {
      DataGatewayDetailOutcome.interviewDone => (
        BgeBannerTone.success,
        l10n.dataGatewayOutcomeInterviewDone,
      ),
      DataGatewayDetailOutcome.interviewFailed => (
        BgeBannerTone.warning,
        l10n.dataGatewayOutcomeInterviewFailed,
      ),
      DataGatewayDetailOutcome.interviewUnknown => (
        BgeBannerTone.info,
        l10n.dataGatewayOutcomeInterviewUnknown,
      ),
      DataGatewayDetailOutcome.interviewDisabled => (
        BgeBannerTone.info,
        l10n.dataGatewayOutcomeInterviewDisabled,
      ),
      DataGatewayDetailOutcome.interviewNoAnswer => (
        BgeBannerTone.error,
        l10n.dataGatewayOutcomeInterviewNoAnswer,
      ),
      DataGatewayDetailOutcome.capabilityFailed => (
        BgeBannerTone.error,
        l10n.dataGatewayOutcomeCapabilityFailed,
      ),
      DataGatewayDetailOutcome.refused => (
        BgeBannerTone.info,
        l10n.dataGatewayChangeRefused,
      ),
    };

    return BgeInlineBanner(
      key: DataGatewayDetailScreen.outcomeKey,
      tone: tone,
      message: message,
      action: TextButton(
        focusNode: dismissFocus,
        onPressed: () => context.read<DataGatewayDetailBloc>().add(
          const DataGatewayDetailOutcomeDismissed(),
        ),
        child: Text(l10n.dataGatewayDismiss),
      ),
    );
  }
}

class _LoadingSliver extends StatelessWidget {
  const _LoadingSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      key: DataGatewayDetailScreen.loadingKey,
      child: Semantics(
        liveRegion: true,
        label: message,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}

/// When [instant] was, as `eventWhenLabel` says an event's date: the day in
/// device-local time, with the year only when it isn't this year's, then the
/// time on the user's own clock.
///
/// The year matters here: "Last interviewed Fri, Oct 30" about last year's
/// interview would mislead an admin working out why a DataGateway returns
/// nothing (#457).
String _when(BuildContext context, DateTime instant) {
  final l10n = DataGatewayLocalizations.of(context);
  final local = instant.toLocal();
  final time = MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return local.year == DateTime.now().toLocal().year
      ? l10n.dataGatewayDateTime(local, time)
      : l10n.dataGatewayDateTimeWithYear(local, time);
}

/// What a capability is called. A name this client has no label for still
/// shows, as the server spells it (#457).
String _capabilityLabel(DataGatewayLocalizations l10n, String capability) =>
    switch (capability) {
      DataGatewayCapabilities.search => l10n.dataGatewayCapabilitySearch,
      DataGatewayCapabilities.fetch => l10n.dataGatewayCapabilityFetch,
      DataGatewayCapabilities.fetchExpansions =>
        l10n.dataGatewayCapabilityFetchExpansions,
      DataGatewayCapabilities.listLanguages =>
        l10n.dataGatewayCapabilityListLanguages,
      DataGatewayCapabilities.listPlatforms =>
        l10n.dataGatewayCapabilityListPlatforms,
      DataGatewayCapabilities.listCategories =>
        l10n.dataGatewayCapabilityListCategories,
      DataGatewayCapabilities.listMechanics =>
        l10n.dataGatewayCapabilityListMechanics,
      _ => l10n.dataGatewayCapabilityOther(capability),
    };

/// Why a list failed to load, as a phrase that follows a colon.
String _sectionFailureLabel(
  DataGatewayLocalizations l10n,
  DataGatewaySectionFailureCode code,
) => switch (code) {
  DataGatewaySectionFailureCode.listUnsupported =>
    l10n.dataGatewaySectionFailureListUnsupported,
  DataGatewaySectionFailureCode.listFailed =>
    l10n.dataGatewaySectionFailureListFailed,
  DataGatewaySectionFailureCode.linkFailed =>
    l10n.dataGatewaySectionFailureLinkFailed,
  DataGatewaySectionFailureCode.unknown =>
    l10n.dataGatewaySectionFailureUnknown,
};
