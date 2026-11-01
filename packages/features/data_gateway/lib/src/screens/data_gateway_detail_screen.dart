import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

import '../access/data_gateway_access.dart';
import '../bloc/data_gateway_detail_bloc.dart';
import '../bloc/data_gateway_detail_event.dart';
import '../bloc/data_gateway_detail_state.dart';
import '../widgets/data_gateway_message.dart';
import '../widgets/data_gateway_status.dart';

/// One DataGateway's own page (#457): whether the server uses it and why not,
/// how its interviews and lists went, and a switch for each thing it can do.
///
/// Decoupled from DI like the list screen: the caller resolves the per-server
/// [DataGatewayRemoteDataSource] and the session's [DataGatewayAccess]. The
/// screen takes an id rather than a row, and reads the row itself.
///
/// The row is read again whenever the screen comes back into view, and from
/// the refresh control. [DataGatewayDetailBloc] says how a read and an action
/// that overlap settle.
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
///
/// A control also loses focus when the tree under it is rebuilt, so what comes
/// and goes keeps the rest in place. The banner is a sliver of a type no
/// section shares, the bar has a slot of its own whether it shows or not, and
/// each switch is keyed.
///
/// ## Access
///
/// A refused read is the access-denied surface, with nothing to act on. A
/// refused change hides the interview button and stops the switches for the
/// rest of the session, and the banner says why (#41).
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

  /// The session's access, or null for a composition without one.
  final DataGatewayAccess? access;

  @override
  Widget build(BuildContext context) => BlocProvider<DataGatewayDetailBloc>(
    // Keyed on the row: go_router keys a page by its path pattern, so going
    // from one DataGateway's location straight to another rebuilds this screen
    // in place. A new id has to start a new bloc, or the screen would show the
    // first row under the second's URL, and write to the first.
    key: ValueKey<String>(id),
    create: (_) =>
        DataGatewayDetailBloc(remote: remote, id: id, access: access)
          ..add(const DataGatewayDetailLoadRequested()),
    // Reads the row again when the screen comes back into view, so it covers
    // whatever was opened over it.
    child: Builder(
      builder: (context) => ReadAgainWhenUncovered(
        onUncovered: () => _readAgain(context),
        child: const _DataGatewayDetailView(),
      ),
    ),
  );
}

/// Reads what the screen shows from the server again: on coming back into
/// view, on a refresh and on a retry.
void _readAgain(BuildContext context) => context
    .read<DataGatewayDetailBloc>()
    .add(const DataGatewayDetailLoadRequested());

class _DataGatewayDetailView extends StatelessWidget {
  const _DataGatewayDetailView();

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return BlocBuilder<DataGatewayDetailBloc, DataGatewayDetailState>(
      builder: (context, state) {
        final ready = state is DataGatewayDetailReady ? state : null;

        return BgePage.slivers(
          title: Text(ready?.gateway.name ?? l10n.dataGatewayListTitle),
          width: BgePageWidth.pane,
          actions: [
            // On every surface but denied, which has nothing to act on. That
            // includes the spinner, so a refresh that takes the row down, or
            // starts over from a failure, leaves focus where it was. It is
            // also the only way to read again from the gone surface.
            if (state is! DataGatewayDetailDenied)
              IconButton(
                key: DataGatewayDetailScreen.refreshKey,
                tooltip: l10n.dataGatewayDetailRefresh,
                icon: const Icon(Icons.refresh),
                onPressed: () => _readAgain(context),
              ),
          ],
          slivers: [
            if (ready?.outcome case final outcome?)
              _OutcomeSliver(outcome: outcome),
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
                :final mayChange,
                :final busy,
                :final interviewWaiting,
              ) =>
                [
                  _StatusSection(gateway: gateway),
                  _InterviewSection(
                    gateway: gateway,
                    mayChange: mayChange,
                    interviewing:
                        busy == DataGatewayDetailBusy.interview ||
                        interviewWaiting,
                  ),
                  _ListsSection(gateway: gateway),
                  _CapabilitiesSection(
                    gateway: gateway,
                    mayChange: mayChange,
                    busy: busy,
                    interviewWaiting: interviewWaiting,
                  ),
                ],
            },
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
    required this.mayChange,
    required this.interviewing,
  });

  final DataGateway gateway;
  final bool mayChange;
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
        if (gateway.enabled && mayChange) ...[
          const BgeGap.md(),
          OutlinedButton(
            key: DataGatewayDetailScreen.interviewKey,
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
class _ListsSection extends StatelessWidget {
  const _ListsSection({required this.gateway});

  final DataGateway gateway;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final expected = dataGatewayExpectedSections(gateway);

    return _Section(
      heading: l10n.dataGatewayListsHeading,
      children: [
        if (expected.isEmpty) Text(l10n.dataGatewayListsNone),
        for (final (:capability, :section) in expected)
          _SectionRow(
            key: DataGatewayDetailScreen.sectionKey(capability),
            capability: capability,
            section: section,
          ),
      ],
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.capability,
    required this.section,
    super.key,
  });

  final String capability;

  /// Null for a list whose job has not run since an interview: not loaded yet,
  /// and not a failure (#457).
  final DataGatewaySection? section;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final loaded = section?.lastLoadedAt;
    final failure = section?.failure;

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
          if (loaded == null && failure == null)
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
    required this.mayChange,
    required this.busy,
    required this.interviewWaiting,
  });

  final DataGateway gateway;
  final bool mayChange;
  final DataGatewayDetailBusy? busy;
  final bool interviewWaiting;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final names = dataGatewayCapabilityRows(gateway);
    // Not stopped by a write of their own, and the bloc settles a press made
    // meanwhile: see the screen's doc.
    final maySwitch =
        mayChange &&
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

class _OutcomeSliver extends StatelessWidget {
  const _OutcomeSliver({required this.outcome});

  final DataGatewayDetailOutcome outcome;

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

    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
        child: BgeInlineBanner(
          key: DataGatewayDetailScreen.outcomeKey,
          tone: tone,
          message: message,
          action: TextButton(
            onPressed: () => context.read<DataGatewayDetailBloc>().add(
              const DataGatewayDetailOutcomeDismissed(),
            ),
            child: Text(l10n.dataGatewayDismiss),
          ),
        ),
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
