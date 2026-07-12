import 'package:flutter/widgets.dart';
import 'package:interfaces/services.dart';

/// Holds the application's active (negotiated) locale (#33).
///
/// The concrete [ActiveLocaleReader]: `runBgeApp` constructs one seeded
/// with the raw OS locale (the best available value before the first
/// frame), registers it app-scope in the root container, and hands it to
/// `BgeApp`, whose [ActiveLocaleCapture] keeps [value] in sync with the
/// locale `MaterialApp` actually resolved. Non-widget consumers (gateway
/// `locale` hints, feedback environment stamps) read [languageTag]
/// lazily via the interface; widgets needing reactivity can listen to
/// the [ValueNotifier] surface.
///
/// Note: [ActiveLocaleCapture] assigns [value] from within the build
/// phase (`didChangeDependencies`), so any future widget listener must
/// tolerate build-phase notifications (defer with a post-frame callback
/// on the listening side, or add deferral here when such a consumer
/// lands). [ValueNotifier] already dedupes — assigning an equal [Locale]
/// does not notify.
class ActiveLocaleController extends ValueNotifier<Locale>
    implements ActiveLocaleReader {
  ActiveLocaleController(super.value);

  @override
  String get languageTag => value.toLanguageTag();
}

/// Mirrors the ambient negotiated locale into an [ActiveLocaleController].
///
/// Placed by `BgeApp` inside `MaterialApp.router`'s `builder` — that
/// context sits below the app's `Localizations` widget, so
/// [Localizations.maybeLocaleOf] returns the locale Flutter resolved
/// against `supportedLocales` (with the shell's `en`-first list, the
/// framework's default chain — exact match → languageCode match → first
/// supported — yields the `en` fallback with no custom resolution
/// callback). Reading it in [State.didChangeDependencies] registers the
/// inherited-widget dependency, so a runtime OS locale change re-fires
/// the capture automatically.
class ActiveLocaleCapture extends StatefulWidget {
  const ActiveLocaleCapture({
    required this.controller,
    required this.child,
    super.key,
  });

  final ActiveLocaleController controller;
  final Widget child;

  @override
  State<ActiveLocaleCapture> createState() => _ActiveLocaleCaptureState();
}

class _ActiveLocaleCaptureState extends State<ActiveLocaleCapture> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _capture();
  }

  @override
  void didUpdateWidget(ActiveLocaleCapture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _capture();
    }
  }

  void _capture() {
    final locale = Localizations.maybeLocaleOf(context);
    if (locale != null) {
      widget.controller.value = locale;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
