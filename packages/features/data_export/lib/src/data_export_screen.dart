import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:data_export/l10n/data_export_localizations.dart';
import 'package:data_export/src/assemble_user_data_export.dart';
import 'package:data_export/src/data_export_cubit.dart';
import 'package:data_export/src/data_export_state.dart';
import 'package:data_export/src/export_category_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Export your data (#93): what the file holds, and the button that saves it.
///
/// The server is named by the name it gives itself, which the file carries
/// too, not the user's nickname for it.
///
/// ## The action area
///
/// Every outcome stays on this screen, so every outcome is a banner, keyed by
/// [DataExportState.answers]: the same answer twice is a new banner,
/// announced and revealed again.
///
/// - **The warning**, while the bundle holds data the server didn't confirm:
///   a banner, with "Refresh and export" and "Save this copy" under it. The
///   buttons sit under the banner rather than in its action slot, so a new
///   banner never remounts them, and they stay up, whichever control started
///   a run from the warning, until that run lands
///   ([DataExportState.showsWarningButtons]). A pressed one stays enabled and
///   inert so it keeps focus ([BgeInertButton]), named and drawn as busy;
///   the other is disabled, as is each while a run Export started is out.
///   The banner goes once a newer copy comes back confirmed
///   ([DataExportState.showsWarningBanner]).
/// - **A success**, with a Dismiss that retires it.
/// - **A failure**, on the Export button through [BgeFormActions]. Untitled:
///   every message names the export. It stays until the next run starts.
///
/// ## Focus after a run
///
/// Focus the user moved elsewhere during a run stays where they put it.
/// Otherwise, after the frame that builds the landing:
///
/// - A landing that takes the warning's buttons down, while one of them has
///   focus, hands it to the success banner's Dismiss, or to Export after a
///   failure or a cancelled save.
/// - A run Export started disables Export while it runs, which lets its
///   focus go: the screen parks it on the page's scope, not on whatever the
///   user tabbed past on the way to Export. When the run lands, Export is
///   enabled again, and focus goes back to it, if it was there when Export
///   was pressed.
///
/// On the web with the semantics tree on, a busy Export also takes the
/// browser's focus off the page: its spinner makes it a different kind of
/// node to the engine, which replaces its element, and the framework parks
/// focus on the root scope. A hand-off then brings the browser's focus back
/// to the page, and the view answers that by focusing the first focusable
/// node in it, the app's text-selection region where it has one. So a
/// hand-off holds its target against that answer.
class DataExportScreen extends StatelessWidget {
  const DataExportScreen({
    required this.server,
    required this.exporters,
    required this.assemble,
    required this.sink,
    required this.labelResolvers,
    super.key,
  });

  static const Key exportKey = Key('data_export.export');
  static const Key refreshKey = Key('data_export.refresh');
  static const Key saveAnywayKey = Key('data_export.save_anyway');
  static const Key dismissKey = Key('data_export.dismiss');

  final ActiveServer server;

  /// The categories the file holds, in the bundle's order.
  final List<UserDataExporter> exporters;

  /// The export bundler's `assemble`.
  final AssembleUserDataExport assemble;

  final UserDataExportSink sink;

  /// Resolve each exporter's label keys, one per feature that registers one.
  final List<ExportCategoryLabelResolver> labelResolvers;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) =>
        DataExportCubit(server: server, assemble: assemble, sink: sink),
    child: _DataExportView(screen: this),
  );
}

class _DataExportView extends StatefulWidget {
  const _DataExportView({required this.screen});

  final DataExportScreen screen;

  @override
  State<_DataExportView> createState() => _DataExportViewState();
}

class _DataExportViewState extends State<_DataExportView>
    with WidgetsBindingObserver {
  /// Around the warning's two buttons, to tell whether either has focus.
  /// Never focused itself.
  final FocusNode _warningButtons = FocusNode(
    debugLabel: 'data export warning buttons',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Around the Export button, whose own node `BgeSubmitButton` keeps to
  /// itself. Never focused itself: a hand-off asks its one descendant.
  final FocusNode _exportFocus = FocusNode(
    debugLabel: 'data export export button',
    canRequestFocus: false,
    skipTraversal: true,
  );

  final FocusNode _dismiss = FocusNode(debugLabel: 'data export dismiss');

  /// Whether Export held focus when the run it started began.
  bool _exportHadFocus = false;

  /// The focus request just made, until it has applied
  /// ([_requestAndHold]).
  VoidCallback? _heldRequest;

  /// Whether the browser's focus is in the page, as the view's focus events
  /// last said.
  bool _viewHasFocus = true;

  /// The view this screen is in, read while the element is active: the
  /// observer still hears view focus events after it is deactivated, where
  /// looking the view up would fail.
  int? _viewId;

  DataExportScreen get _screen => widget.screen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warningButtons.dispose();
    _exportFocus.dispose();
    _dismiss.dispose();
    super.dispose();
  }

  /// Whether [current] is a run's landing that takes the warning's buttons
  /// down. Only a landing does: they stay through every run started under
  /// them.
  static bool _warningLeaves(
    DataExportState previous,
    DataExportState current,
  ) => previous.showsWarningButtons && !current.showsWarningButtons;

  static bool _exportStarts(
    DataExportState previous,
    DataExportState current,
  ) => previous.run == null && current.run == DataExportRun.export;

  static bool _exportLands(
    DataExportState previous,
    DataExportState current,
  ) => previous.run == DataExportRun.export && current.run == null;

  /// Runs before the frame that disables Export, while the press still
  /// leaves focus on it, and if it does, parks focus on the page's scope
  /// after that frame.
  ///
  /// Disabled, Export lets its focus go, and the framework hands it to the
  /// control focused before Export, which a keyboard user tabbed past. That
  /// hand-off applies after the frame, so a request made in the frame's
  /// post-frame callback wins over it. Parked on the scope, focus is free at
  /// the landing unless the user moves it during the run.
  ///
  /// Only if Export still has focus then: focus the user moved between the
  /// press and that frame stays theirs.
  ///
  /// Not when that frame took the browser's focus off the page, as a busy
  /// Export does on the web with the semantics tree on: the framework has
  /// parked focus on the root scope then, which is free as well. Parking on
  /// the page's scope instead would leave the view's answer to the browser's
  /// focus coming back until a frame after the landing's hand-off, out of
  /// reach of [_requestAndHold].
  void _onExportStarts(BuildContext context, DataExportState state) {
    _exportHadFocus = _exportFocus.hasFocus;
    if (!_exportHadFocus) return;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !_viewHasFocus || !_exportFocus.hasFocus) return;
        FocusScope.of(
          this.context,
          createDependency: false,
        ).requestScopeFocus();
      })
      ..ensureVisualUpdate();
  }

  /// Hands focus back to Export after the frame that enables it again, if
  /// Export had it when pressed and nothing the user chose has it since:
  /// focus is still parked where the run's start left it.
  void _onExportLands(BuildContext context, DataExportState state) {
    if (!_exportHadFocus) return;
    _exportHadFocus = false;
    _handOffAfterFrame(
      context,
      // Not into a run started since.
      (landed) => landed.run == null ? _exportButton : null,
    );
  }

  /// Runs before the frame that takes the warning's buttons down, while one
  /// of them still has focus, and hands focus on after that frame.
  void _onWarningLeaves(BuildContext context, DataExportState state) {
    if (!_warningButtons.hasFocus) return;
    _handOffAfterFrame(
      context,
      untouched: FocusManager.instance.primaryFocus,
      (landed) => switch (landed) {
        _ when landed.isSuccess => _dismiss,
        DataExportState(
          phase: DataExportPhase.failed || DataExportPhase.ready,
        ) =>
          _exportButton,
        _ => null,
      },
    );
  }

  /// Focuses the node [target] picks from the state that frame built, after
  /// the frame, if focus is still free ([focusIsFree], with [untouched]): a
  /// request made then wins over the framework's fall-back to the page's
  /// focus history.
  void _handOffAfterFrame(
    BuildContext context,
    FocusNode? Function(DataExportState landed) target, {
    FocusNode? untouched,
  }) {
    final cubit = context.read<DataExportCubit>();
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !focusIsFree(this.context, untouched: untouched)) {
          return;
        }
        if (target(cubit.state) case final node?) {
          _requestAndHold(node.requestFocus);
        }
      })
      ..ensureVisualUpdate();
  }

  /// Makes the focus [request], and makes it again if applying it brings
  /// the browser's focus back to the page.
  ///
  /// The request applies in a microtask. If the browser's focus had left
  /// the page, applying it focuses the page again, and the view's focus
  /// event arrives while it applies: the view answers it first, by focusing
  /// the first focusable node in the page ([didChangeViewFocus] repeats the
  /// request after that). The microtask below runs once the request has
  /// applied, and ends the hold.
  void _requestAndHold(VoidCallback request) {
    _heldRequest = request;
    request();
    scheduleMicrotask(() {
      if (identical(_heldRequest, request)) _heldRequest = null;
    });
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _viewHasFocus = event.state == ViewFocusState.focused;
    final request = _heldRequest;
    if (request == null || !_viewHasFocus) return;
    _heldRequest = null;
    request();
  }

  /// The Export button's own node, the one traversable node under the
  /// wrapper.
  FocusNode? get _exportButton => _exportFocus.traversalDescendants.firstOrNull;

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<DataExportCubit, DataExportState>(
        listenWhen: _exportStarts,
        listener: _onExportStarts,
      ),
      BlocListener<DataExportCubit, DataExportState>(
        listenWhen: _exportLands,
        listener: _onExportLands,
      ),
      BlocListener<DataExportCubit, DataExportState>(
        listenWhen: _warningLeaves,
        listener: _onWarningLeaves,
      ),
    ],
    child: BlocBuilder<DataExportCubit, DataExportState>(builder: _buildState),
  );

  ExportCategoryLabels _labelsOf(
    BuildContext context,
    UserDataExporter exporter,
  ) => resolveExportCategoryLabels(
    context,
    exporter.categoryNameKey,
    _screen.labelResolvers,
  );

  Widget _buildState(BuildContext context, DataExportState state) {
    final l10n = DataExportLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return BgePage(
      title: Text(l10n.dataExportTitle),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.dataExportIntro(_screen.server.identity.name),
            style: textTheme.bodyLarge,
          ),
          const BgeGap.lg(),
          Semantics(
            header: true,
            child: Text(l10n.dataExportIncluded, style: textTheme.titleMedium),
          ),
          for (final exporter in _screen.exporters) ...[
            const BgeGap.md(),
            _CategoryRow(labels: _labelsOf(context, exporter)),
          ],
          const BgeGap.lg(),
          ..._actions(context, l10n, state),
        ],
      ),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    DataExportLocalizations l10n,
    DataExportState state,
  ) {
    final cubit = context.read<DataExportCubit>();
    final run = state.run;
    final failure = state.failure;
    final outcome = switch (state.phase) {
      DataExportPhase.saved => l10n.dataExportSaved,
      DataExportPhase.downloaded => l10n.dataExportDownloaded,
      _ => null,
    };

    return [
      if (state.showsWarningBanner) ...[
        BgeInlineBanner(
          key: ValueKey(state.answers),
          tone: BgeBannerTone.warning,
          title: l10n.dataExportUnconfirmedTitle,
          message: l10n.dataExportUnconfirmedMessage(
            _categoryNames(context, state.unconfirmedKeys),
            _screen.server.identity.name,
          ),
        ),
        const BgeGap.sm(),
      ],
      if (state.showsWarningButtons) ...[
        Focus(
          // Keyed, so the banner leaving above it never remounts the buttons.
          key: const ValueKey('data_export.warning_buttons'),
          focusNode: _warningButtons,
          includeSemantics: false,
          child: Wrap(
            spacing: BgeTokens.of(context).spaceSm,
            runSpacing: BgeTokens.of(context).spaceSm,
            children: [
              _WarningButton(
                buttonKey: DataExportScreen.refreshKey,
                label: l10n.dataExportRefreshAndExport,
                busyLabel: l10n.dataExportPreparing,
                inert: run == DataExportRun.refreshAndExport,
                onPressed: run == null || run == DataExportRun.refreshAndExport
                    ? cubit.refreshAndExport
                    : null,
              ),
              _WarningButton(
                buttonKey: DataExportScreen.saveAnywayKey,
                label: l10n.dataExportSaveAnyway,
                busyLabel: l10n.dataExportPreparing,
                inert: run == DataExportRun.saveAnyway,
                onPressed: run == null || run == DataExportRun.saveAnyway
                    ? cubit.saveAnyway
                    : null,
              ),
            ],
          ),
        ),
        const BgeGap.lg(),
      ],
      if (outcome != null) ...[
        BgeInlineBanner(
          key: ValueKey(state.answers),
          tone: BgeBannerTone.success,
          message: outcome,
          action: TextButton(
            key: DataExportScreen.dismissKey,
            focusNode: _dismiss,
            onPressed: cubit.dismissOutcome,
            child: Text(l10n.dataExportDismiss),
          ),
        ),
        const BgeGap.md(),
      ],
      BgeFormActions(
        failure: failure == null
            ? null
            : BgeFormFailure(
                key: ValueKey(state.answers),
                // Every message names the export, so none needs a title.
                title: null,
                message: _failureMessage(l10n, failure),
              ),
        action: Focus(
          focusNode: _exportFocus,
          includeSemantics: false,
          child: BgeSubmitButton(
            key: DataExportScreen.exportKey,
            label: l10n.dataExportAction,
            progressLabel: l10n.dataExportPreparing,
            submitting: run != null,
            onPressed: cubit.export,
          ),
        ),
      ),
    ];
  }

  /// The names of the categories [keys] name, in order. A key with no
  /// exporter here is shown as it is.
  String _categoryNames(BuildContext context, List<String> keys) => [
    for (final key in keys)
      switch (_screen.exporters
          .where((exporter) => exporter.key == key)
          .firstOrNull) {
        final exporter? => _labelsOf(context, exporter).name,
        null => key,
      },
  ].join(', ');

  static String _failureMessage(
    DataExportLocalizations l10n,
    DataExportFailure failure,
  ) => switch (failure) {
    DataExportFailure.notAuthenticated => l10n.dataExportNotAuthenticated,
    DataExportFailure.sessionUnavailable => l10n.dataExportSessionUnavailable,
    DataExportFailure.saveFailed => l10n.dataExportSaveFailed,
    DataExportFailure.unexpected => l10n.dataExportUnexpected,
  };
}

/// One category the file holds: its name, with its description under it,
/// read as one.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.labels});

  final ExportCategoryLabels labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(labels.name, style: theme.textTheme.titleSmall),
          if (labels.description.isNotEmpty) ...[
            const BgeGap.xs(),
            Text(
              labels.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One of the warning's two buttons: inert through the run its own press
/// started, disabled (a null [onPressed]) through any other.
///
/// While inert it is named [busyLabel], so the name says why it is not
/// available, and draws a spinner over its label, which keeps its place so
/// the button keeps its width. A press or a hover then draws nothing, as on
/// the auth screen's provider button while its sign-in is open; the focus
/// overlay stays, so a keyboard user still sees where they are.
class _WarningButton extends StatelessWidget {
  const _WarningButton({
    required this.buttonKey,
    required this.label,
    required this.busyLabel,
    required this.inert,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final String busyLabel;
  final bool inert;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => BgeInertButton(
    inert: inert,
    label: inert ? busyLabel : label,
    onPressed: onPressed,
    builder: (context, focusNode, onPressed) => OutlinedButton(
      key: buttonKey,
      focusNode: focusNode,
      onPressed: onPressed,
      style: inert ? _busyStyle(context) : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Visibility.maintain(visible: !inert, child: Text(label)),
          if (inert) const _BusySpinner(),
        ],
      ),
    ),
  );

  static ButtonStyle _busyStyle(BuildContext context) {
    final disabled = Theme.of(context).disabledColor;
    return ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? null
            : disabled.withValues(alpha: 0),
      ),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.basic),
      splashFactory: NoSplash.splashFactory,
      enableFeedback: false,
    );
  }
}

/// A busy warning button's spinner: scaled with the label it stands in for,
/// in the button's icon colour, and mute to a screen reader, since the
/// button's name says it is busy.
class _BusySpinner extends StatelessWidget {
  const _BusySpinner();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: BgeTextScale.clampedOf(context)
          .scale(BgeTokens.of(context).spaceMd),
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: IconTheme.of(context).color,
      ),
    ),
  );
}
