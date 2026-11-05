import 'package:flutter/material.dart';

/// The list or thumbnails choice for a screen of games, as a two-option
/// segmented control (#710).
///
/// Both segments are icon-only, so each icon carries its label as a tooltip
/// and as its accessible name. The segmented button itself announces the
/// selected segment as selected.
class BgeLayoutToggle extends StatelessWidget {
  /// Creates a toggle showing [thumbnails] as chosen.
  const BgeLayoutToggle({
    required this.thumbnails,
    required this.onChanged,
    required this.listLabel,
    required this.thumbnailsLabel,
    super.key,
  });

  /// Whether the thumbnails segment is the chosen one.
  final bool thumbnails;

  /// Called with `true` for thumbnails and `false` for the list.
  final ValueChanged<bool> onChanged;

  /// The list segment's tooltip and accessible name.
  final String listLabel;

  /// The thumbnails segment's tooltip and accessible name.
  final String thumbnailsLabel;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: false,
          icon: _SegmentIcon(Icons.view_list_outlined, label: listLabel),
        ),
        ButtonSegment(
          value: true,
          icon: _SegmentIcon(Icons.grid_view_outlined, label: thumbnailsLabel),
        ),
      ],
      selected: {thumbnails},
      onSelectionChanged: (selection) => onChanged(selection.single),
    );
  }
}

/// An icon that names itself to a screen reader and to a pointer.
///
/// The tooltip leaves semantics out on purpose: the segment's own `tooltip`
/// would add the same words to its node a second time, as a tooltip beside
/// the label, so a screen reader could say the name twice.
class _SegmentIcon extends StatelessWidget {
  const _SegmentIcon(this.icon, {required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: Icon(icon, semanticLabel: label),
  );
}

/// Reads a screen's remembered list or thumbnails choice, and writes a new
/// one (#710).
///
/// [read] is called once, in `initState`. The builder gets `null` until it
/// answers, so a screen can hold back rather than flash the wrong layout. It
/// gets `false`, the list, when [read] is null, throws or answers null.
///
/// A change shows at once and is then written without waiting. A change made
/// before [read] answers wins: the late answer is dropped, so the screen keeps
/// what the user chose and what was written.
///
/// A read or a write that fails is reported through
/// [FlutterError.reportError] and not shown. A failed read shows the list,
/// and a failed write keeps the choice for this visit, simply not
/// remembered. Reported, so that a store that always fails, which looks to
/// the user like a choice that is never kept, can be found.
///
/// A widget that needs a fresh read for a different store takes a new key,
/// since [read] is not called again.
class BgeRememberedLayout extends StatefulWidget {
  /// Creates a widget that builds with the remembered choice.
  const BgeRememberedLayout({
    required this.read,
    required this.write,
    required this.builder,
    super.key,
  });

  /// Reads the stored choice, or null when nothing is stored.
  final Future<bool?> Function()? read;

  /// Stores `thumbnails` as the choice.
  final Future<void> Function(bool thumbnails)? write;

  /// Builds the screen with the choice, `null` while it is being read.
  final Widget Function(
    BuildContext context,
    bool? thumbnails,
    ValueChanged<bool> onChanged,
  )
  builder;

  @override
  State<BgeRememberedLayout> createState() => _BgeRememberedLayoutState();
}

class _BgeRememberedLayoutState extends State<BgeRememberedLayout> {
  bool? _thumbnails;

  /// Whether the user chose before the read answered.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    final read = widget.read;
    if (read == null) {
      _thumbnails = false;
      return;
    }
    _load(read);
  }

  Future<void> _load(Future<bool?> Function() read) async {
    bool value;
    try {
      value = await read() ?? false;
    } on Object catch (error, stack) {
      _report(error, stack, 'while reading the remembered layout choice');
      value = false;
    }
    if (!mounted || _changed) {
      return;
    }
    setState(() => _thumbnails = value);
  }

  Future<void> _change(bool thumbnails) async {
    _changed = true;
    setState(() => _thumbnails = thumbnails);
    final write = widget.write;
    if (write == null) {
      return;
    }
    try {
      await write(thumbnails);
    } on Object catch (error, stack) {
      _report(error, stack, 'while remembering the layout choice');
    }
  }

  void _report(Object error, StackTrace stack, String context) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'ui',
          context: ErrorDescription(context),
        ),
      );

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _thumbnails, _change);
}
