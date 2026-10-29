import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

/// A filter range's From and To fields, shared by the search's publish-year,
/// player-count and play-time sections (#565, #580).
///
/// ## When it commits
///
/// A field commits on submit, when it loses focus, and when the sheet
/// holding it closes, so typing "1990" is one search, not four. A commit
/// reaches [onCommit] only when each field holds a bound or none, each
/// bound is within [lowest] and [highest], and From is not after To.
/// Otherwise the field says why, and nothing is sent. An empty field, or a
/// lone minus sign, is no bound. Closing on bounds that can't be sent drops
/// them, and tells [onDropped] why, since the field is no longer there to.
///
/// [value] seeds the fields, and seeds them again when its bounds change
/// from outside, as when a band is chosen or the range is cleared, or when
/// [generation] changes. Only the bounds are this widget's: [onCommit] gets
/// [value] with them replaced.
///
/// A problem is announced the moment it appears, as `BgeTextField` announces
/// its errors. This isn't one: it commits against no form.
///
/// The two fields sit side by side where each has room, and one above the
/// other where it doesn't, as at a large text size.
class SearchRangeField extends StatefulWidget {
  const SearchRangeField({
    required this.value,
    required this.onCommit,
    required this.lowest,
    this.highest = GamesRemoteDataSource.maxRangeBound,
    this.allowNegative = false,
    this.helper,
    this.fromKey,
    this.toKey,
    this.generation = 0,
    this.onDropped,
    super.key,
  });

  final GameSearchRange value;
  final ValueChanged<GameSearchRange> onCommit;

  /// The lowest bound the server accepts.
  final int lowest;

  /// The highest bound the server accepts.
  final int highest;

  /// Whether a bound may be typed with a leading minus, as a year before the
  /// common era is (#565).
  final bool allowNegative;

  /// A line under the fields saying how to fill them in.
  final String? helper;

  final Key? fromKey;
  final Key? toKey;

  /// Changes when the fields should drop what was typed and not sent, and
  /// read [value] again even though it hasn't changed: the sheet's Clear all.
  final int generation;

  /// Told why, when the sheet closes on bounds that can't be sent.
  final ValueChanged<String>? onDropped;

  @override
  State<SearchRangeField> createState() => _SearchRangeFieldState();
}

/// Why a field's text can't be committed.
enum _Problem { tooLow, tooHigh, reversed }

class _SearchRangeFieldState extends State<SearchRangeField> {
  /// Below this width, scaled by the text size, a field doesn't fit beside
  /// the other.
  static const double _minFieldWidth = 112;

  /// The most digits a bound may have: enough for any int32.
  static const int _maxDigits = 10;

  static final RegExp _signedBound = RegExp(r'^-?\d{0,10}$');

  // Set in initState, not lazily: a lazy initializer first read in
  // didUpdateWidget would see the new value, and miss the change.
  late final TextEditingController _from;
  late final TextEditingController _to;
  final FocusNode _fromFocus = FocusNode();
  final FocusNode _toFocus = FocusNode();

  /// What was last committed, or seeded from [SearchRangeField.value].
  late GameSearchRange _committed;

  /// Whether a commit has been tried since the fields were seeded. Until
  /// then, a field says nothing about what is being typed.
  bool _checked = false;
  _Problem? _fromProblem;
  _Problem? _toProblem;

  /// Read while mounted: a field closing with the sheet says why it can't
  /// commit, and may look nothing up by then.
  late GameCatalogLocalizations _l10n;

  @override
  void initState() {
    super.initState();
    _committed = widget.value;
    _from = TextEditingController(text: _text(widget.value.min));
    _to = TextEditingController(text: _text(widget.value.max));
    _fromFocus.addListener(_onFromFocus);
    _toFocus.addListener(_onToFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _l10n = GameCatalogLocalizations.of(context);
  }

  @override
  void didUpdateWidget(SearchRangeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final value = widget.value;
    if (widget.generation != oldWidget.generation ||
        value.min != _committed.min ||
        value.max != _committed.max) {
      // Set from outside: a band, a cleared chip or Clear all.
      _from.text = _text(value.min);
      _to.text = _text(value.max);
      _checked = false;
      _fromProblem = _toProblem = null;
    }
    _committed = value;
  }

  @override
  void dispose() {
    // Closing the sheet commits what was typed, as leaving a field does.
    if (_message(_commit(show: false)) case final problem?) {
      widget.onDropped?.call(problem);
    }
    _fromFocus
      ..removeListener(_onFromFocus)
      ..dispose();
    _toFocus
      ..removeListener(_onToFocus)
      ..dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  static String _text(int? bound) => bound == null ? '' : '$bound';

  /// The bound [text] holds, or null for none.
  static int? _parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed == '-') return null;
    return int.tryParse(trimmed);
  }

  void _onFromFocus() {
    if (!_fromFocus.hasFocus) _commit();
  }

  void _onToFocus() {
    if (!_toFocus.hasFocus) _commit();
  }

  ({int? from, int? to, _Problem? fromProblem, _Problem? toProblem}) _read() {
    final (from, to) = (_parse(_from.text), _parse(_to.text));
    _Problem? outside(int? bound) => switch (bound) {
      null => null,
      final bound when bound < widget.lowest => _Problem.tooLow,
      final bound when bound > widget.highest => _Problem.tooHigh,
      _ => null,
    };
    final fromProblem = outside(from);
    final toProblem =
        outside(to) ??
        (fromProblem == null && from != null && to != null && from > to
            ? _Problem.reversed
            : null);
    return (from: from, to: to, fromProblem: fromProblem, toProblem: toProblem);
  }

  /// Sends the bounds typed, when they can be sent and have changed, and
  /// returns why they can't be. [show] puts any problem on screen, which a
  /// disposing field can't.
  _Problem? _commit({bool show = true}) {
    final read = _read();
    if (show && mounted) {
      setState(() {
        _checked = true;
        _fromProblem = read.fromProblem;
        _toProblem = read.toProblem;
      });
    }
    if (read.fromProblem ?? read.toProblem case final problem?) {
      return problem;
    }

    final range = widget.value.copyWith(min: read.from, max: read.to);
    if (range == _committed) return null;
    _committed = range;
    widget.onCommit(range);
    return null;
  }

  String? _message(_Problem? problem) => switch (problem) {
    null => null,
    _Problem.tooLow => _l10n.catalogSearchRangeTooLow(widget.lowest),
    _Problem.tooHigh => _l10n.catalogSearchRangeTooHigh,
    _Problem.reversed => _l10n.catalogSearchRangeReversed,
  };

  /// Once a problem has been shown, follows the typing, so it goes as soon
  /// as it is fixed.
  void _recheck() {
    if (!_checked) return;
    final read = _read();
    setState(() {
      _fromProblem = read.fromProblem;
      _toProblem = read.toProblem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final theme = Theme.of(context);

    Widget field({
      required Key? key,
      required TextEditingController controller,
      required FocusNode focusNode,
      required String label,
      required _Problem? problem,
      required TextInputAction action,
    }) => TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.numberWithOptions(
        signed: widget.allowNegative,
      ),
      textInputAction: action,
      // A number, not prose (docs/design/STYLE_GUIDE.md).
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: widget.allowNegative
          ? [
              // A whole-text check: an edit that would leave anything but an
              // optional minus and digits is refused, not stripped.
              TextInputFormatter.withFunction(
                (previous, next) =>
                    _signedBound.hasMatch(next.text) ? next : previous,
              ),
            ]
          : [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(_maxDigits),
            ],
      decoration: InputDecoration(
        labelText: label,
        errorText: _message(problem),
        errorMaxLines: 3,
      ),
      onChanged: (_) => _recheck(),
      onSubmitted: (_) => _commit(),
    );

    final from = field(
      key: widget.fromKey,
      controller: _from,
      focusNode: _fromFocus,
      label: l10n.catalogSearchRangeFrom,
      problem: _fromProblem,
      action: TextInputAction.next,
    );
    final to = field(
      key: widget.toKey,
      controller: _to,
      focusNode: _toFocus,
      label: l10n.catalogSearchRangeTo,
      problem: _toProblem,
      action: TextInputAction.done,
    );
    final helper = widget.helper;
    final problem = _message(_fromProblem ?? _toProblem);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final half = (constraints.maxWidth - tokens.spaceMd) / 2;
            final sideBySide =
                half >= MediaQuery.textScalerOf(context).scale(_minFieldWidth);
            return sideBySide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: from),
                      const BgeGap.md(axis: Axis.horizontal),
                      Expanded(child: to),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [from, const BgeGap.sm(), to],
                  );
          },
        ),
        // The field's own error is read only when the user moves back onto
        // it, so a live region says it as it appears.
        if (problem != null)
          Semantics(
            liveRegion: true,
            label: problem,
            child: SizedBox.square(dimension: tokens.spaceXs),
          )
        else
          const BgeGap.xs(),
        if (helper != null) ...[
          Text(
            helper,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
