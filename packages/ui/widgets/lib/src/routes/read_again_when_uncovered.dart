import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Calls [onUncovered] when the screen holding [child] comes back into view,
/// for a screen that reads the server again then (#41, #455).
///
/// Watches [TickerMode], which turns off while an opaque route covers the
/// screen and back on as that route starts to leave. So it covers a route
/// this screen pushed and one it did not, such as a form a deep link built
/// this screen beneath. Dialogs and menus are not opaque, so they never turn
/// it off.
class ReadAgainWhenUncovered extends StatefulWidget {
  const ReadAgainWhenUncovered({
    required this.onUncovered,
    required this.child,
    super.key,
  });

  final VoidCallback onUncovered;
  final Widget child;

  @override
  State<ReadAgainWhenUncovered> createState() => _ReadAgainWhenUncoveredState();
}

class _ReadAgainWhenUncoveredState extends State<ReadAgainWhenUncovered> {
  ValueListenable<TickerModeData>? _tickerMode;
  bool _covered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watch();
  }

  @override
  void activate() {
    super.activate();
    // Moved in the tree, maybe under another TickerMode.
    _watch();
  }

  void _watch() {
    final tickerMode = TickerMode.getValuesNotifier(context);
    if (identical(tickerMode, _tickerMode)) return;
    _tickerMode?.removeListener(_changed);
    _tickerMode = tickerMode..addListener(_changed);
    _covered = !tickerMode.value.enabled;
  }

  void _changed() {
    final visible = _tickerMode!.value.enabled;
    if (_covered && visible) widget.onUncovered();
    _covered = !visible;
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
