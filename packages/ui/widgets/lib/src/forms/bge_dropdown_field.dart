import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'live_error_announcer.dart';

/// One choice a [BgeDropdownField] offers: the [value] a pick sets on the
/// control, and the [label] the field and its menu show for it.
@immutable
class BgeDropdownItem<T> {
  const BgeDropdownItem({required this.value, required this.label});

  final T value;
  final String label;
}

/// The standard single-choice form field: a closed field showing the chosen
/// item's label, and a menu of [items] that opens under it.
///
/// ## Why the binding is this package's own
///
/// reactive_forms' `ReactiveDropdownField` takes Flutter's Material types,
/// and upstream has stalled, so its call sites could never move to
/// `material_ui` (#637). The binding builds on `ReactiveFocusableFormField`,
/// which is Material-free at runtime, so the Material types stay in this
/// package (#649). Its state registers the `FocusController` that lets
/// `control.focus()` reach the field, which is how a rejected submit lands on
/// the first invalid one (#230).
///
/// ## Surviving a `FormGroup` swap
///
/// As `BgeTextField` does, and for the reasons its class doc gives (#186):
/// `ReactiveFormField` resolves its control once, so this resolves it, with a
/// dependency on the group, and keys the binding on it. A swapped group, or a
/// different [formControl], rebuilds the binding on the new control. The
/// dependency fires on every value change in the form, so the binding is
/// cached and rebuilt only when the control changes.
///
/// ## Why a popover, not a route
///
/// `DropdownButton`'s menu was a route that opened over the field and put the
/// chosen item where the field was. At 320dp and 2.0 text it covered the
/// field's value and the top of the next field, leaving only the label in
/// view (#648). A [MenuAnchor] opens under the field instead, as wide as it,
/// and above it when there's no room below, so the field stays in view. As on
/// #487's filter, `crossAxisUnconstrained: false` holds the panel to the
/// field's width, where left unconstrained a long item clips at its edge, and
/// each item wraps.
///
/// The menu reads [items] from this widget on every build, so items that
/// change while it is open are the ones offered. `DropdownButton` copied
/// them into its route on opening, and a pick could land a value the new
/// items no longer held (#499).
///
/// ## Why a value missing from the items keeps the control's value
///
/// The field shows [hint] for it, and the control keeps the value, as
/// `ReactiveDropdownField` did. Only a pick changes the control: whether a
/// value that left the items should be cleared is the form's call, and a form
/// that clears it does so knowing what it sends (#499).
///
/// ## Why read-only doesn't open, and isn't disabled
///
/// [readOnly] is the in-flight state: the value was captured at submit, and a
/// pick would be dropped, so the menu doesn't open. The field is otherwise
/// left alone, drawn enabled and in the focus order, as a read-only
/// `BgeTextField` is, and read as read-only. A disabled field leaves the
/// focus order, so a keyboard or screen-reader user would have it vanish
/// mid-form, and the in-flight signal is the submit button's, not a
/// greyed-out form (STYLE_GUIDE, "In-flight forms"). `ReactiveDropdownField`
/// drew it disabled. Only a disabled control is drawn disabled and takes no
/// focus. A menu open when the field becomes either is closed, and takes no
/// pick meanwhile.
class BgeDropdownField<T> extends StatefulWidget {
  /// Creates a field bound to [formControlName] in the enclosing
  /// `ReactiveForm`, or to [formControl].
  const BgeDropdownField({
    required this.label,
    required this.items,
    this.hint,
    this.readOnly = false,
    this.validationMessages = const {},
    this.formControlName,
    this.formControl,
    super.key,
  });

  /// Visible label. Also the field's accessible name.
  final String label;

  /// The choices, in the menu's order.
  final List<BgeDropdownItem<T>> items;

  /// Shown in the closed field while the control's value matches no item.
  final String? hint;

  /// Whether the field takes no pick: the menu doesn't open. It stays focusable
  /// and isn't drawn disabled; see the class doc.
  final bool readOnly;

  /// The error text for each validation error key.
  final Map<String, String Function(Object)> validationMessages;

  /// The name of the control in the enclosing `ReactiveForm`.
  final String? formControlName;

  /// The control, when it is passed rather than named.
  final FormControl<T>? formControl;

  @override
  State<BgeDropdownField<T>> createState() => _BgeDropdownFieldState<T>();
}

class _BgeDropdownFieldState<T> extends State<BgeDropdownField<T>> {
  Widget? _cached;
  FormControl<T>? _cachedControl;

  @override
  void didUpdateWidget(BgeDropdownField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The cached binding was built from the old configuration.
    _cached = null;
  }

  @override
  void reassemble() {
    super.reassemble();
    _cached = null;
  }

  /// The named control, with a dependency on the group so a swap is seen.
  /// Null when it can't be found, so the binding is given the name and
  /// reactive_forms raises its own error.
  FormControl<T>? _resolve() {
    final name = widget.formControlName;
    if (name == null) return null;
    final form = ReactiveForm.of(context);
    final resolved = form is FormGroup ? form.findControl(name) : null;
    return resolved is FormControl<T> ? resolved : null;
  }

  @override
  Widget build(BuildContext context) {
    final control = widget.formControl ?? _resolve();
    final cached = _cached;
    if (cached != null && identical(control, _cachedControl)) return cached;

    _cachedControl = control;
    return _cached = _BgeDropdownBinding<T>(
      // A new control is a new binding: `initState` is the only place
      // `ReactiveFormField` resolves one that takes effect.
      key: control == null ? null : ObjectKey(control),
      field: widget,
      formControl: control,
      formControlName: control == null ? widget.formControlName : null,
    );
  }
}

class _BgeDropdownBinding<T> extends ReactiveFocusableFormField<T, T> {
  _BgeDropdownBinding({
    required this.field,
    super.formControl,
    super.formControlName,
    super.key,
  }) : super(
         validationMessages: field.validationMessages,
         builder: (state) => (state as _BgeDropdownBindingState<T>)._build(),
       );

  final BgeDropdownField<T> field;

  @override
  ReactiveFormFieldState<T, T> createState() => _BgeDropdownBindingState<T>();
}

/// A value set on the control in code needs no hook of its own here: the
/// control reports a status with every value (reactive_forms 18.2.2,
/// `models.dart:701-704`), and the base class rebuilds on each status, touched
/// or not.
class _BgeDropdownBindingState<T>
    extends ReactiveFocusableFormFieldState<T, T> {
  final _menu = MenuController();

  /// The menu's width: the field's, measured as the menu opens.
  double? _menuWidth;

  /// Enter and Space, which the app's shortcuts send as these intents to
  /// whatever holds focus.
  late final Map<Type, Action<Intent>> _activate = {
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _toggle()),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: (_) => _toggle(),
    ),
  };

  BgeDropdownField<T> get _field => (widget as _BgeDropdownBinding<T>).field;

  void _toggle() => _menu.isOpen ? _menu.close() : _open();

  void _open() {
    // Measured here rather than by a LayoutBuilder around the field, which
    // can't report an intrinsic size: the field would throw under an
    // AlertDialog's IntrinsicWidth. The menu closes when the view changes
    // size (`RawMenuAnchor`), which is when the field's width would.
    final box = context.findRenderObject() as RenderBox?;
    setState(() => _menuWidth = box?.size.width);
    _menu.open();
  }

  Widget _build() {
    final field = _field;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = BgeTokens.of(context);
    final disabled = control.disabled;
    // Takes no pick, so the menu doesn't open.
    final inert = field.readOnly || disabled;
    if (inert && _menu.isOpen) {
      // Turned inert under an open menu, by a submit or by the control being
      // disabled. Closed after this frame: closing hides the menu's overlay,
      // which isn't this field's to rebuild mid-build. Its items take no pick
      // meanwhile.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _menu.close();
      });
    }
    final menuWidth = _menuWidth;

    final value = this.value;
    // A null value matches an item whose value is null, which is how a
    // "none" choice reads as chosen.
    final chosen = field.items.where((item) => item.value == value).firstOrNull;
    // Where focus lands when the menu opens, so the arrows start from the
    // choice the field shows.
    final landing = chosen ?? field.items.firstOrNull;

    // The closed field's text is drawn as `DropdownButton` drew it, so the
    // field looks as it did before the menu changed (#648). The hint takes
    // the color text fields' hints take.
    final valueStyle = theme.textTheme.titleMedium?.copyWith(
      color: disabled ? theme.disabledColor : null,
    );
    final hintStyle = valueStyle?.copyWith(
      color: disabled ? theme.disabledColor : scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuAnchor(
          controller: _menu,
          // Opening the menu focuses the field first (`RawMenuAnchor.open`),
          // so however it was opened, the page's focus scope has the field
          // to give focus back to after Escape, a pick or a tap outside.
          // Keyboard traversal can also move off the menu back to it.
          childFocusNode: focusNode,
          // As wide as the field that opens it. Left unconstrained, the
          // panel takes its widest item's width and clips a long one.
          crossAxisUnconstrained: false,
          style: MenuStyle(
            minimumSize: menuWidth == null
                ? null
                : WidgetStatePropertyAll(Size(menuWidth, 0)),
            maximumSize: menuWidth == null
                ? null
                : WidgetStatePropertyAll(Size(menuWidth, double.infinity)),
            backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(tokens.radiusMd),
              ),
            ),
          ),
          menuChildren: [
            for (final item in field.items)
              MenuItemButton(
                // An empty icon on the others keeps their labels in line.
                leadingIcon: Icon(identical(item, chosen) ? Icons.check : null),
                overflowAxis: Axis.vertical,
                autofocus: identical(item, landing),
                style: MenuItemButton.styleFrom(
                  foregroundColor: scheme.onSurface,
                ),
                onPressed: inert
                    ? null
                    : () {
                        didChange(item.value);
                        control.markAsTouched();
                      },
                // The check is only drawn, so the label says it is chosen.
                // Inside the item, where it merges into the item's own
                // node; around it, it would stand as a node of its own.
                child: Semantics(
                  selected: identical(item, chosen),
                  child: Text(item.label),
                ),
              ),
          ],
          // One node, read as a button that says whether its menu is open,
          // as `DropdownButton` was and as #487's filter is. The label, the
          // choice and any error merge into it.
          builder: (context, menu, _) => MergeSemantics(
            child: Semantics(
              button: true,
              enabled: !disabled,
              readOnly: field.readOnly,
              // Only a field that opens says whether its menu is open:
              // "collapsed" promises a menu a double tap won't open.
              expanded: inert ? null : menu.isOpen,
              child: Actions(
                actions: inert ? const {} : _activate,
                // Focus is held here, not by the InkWell, which can't
                // take focus without a tap to offer: a read-only field
                // keeps its place in the focus order.
                child: Focus(
                  focusNode: focusNode,
                  canRequestFocus: !disabled,
                  child: InkWell(
                    canRequestFocus: false,
                    borderRadius: BorderRadius.circular(tokens.radiusSm),
                    onTap: inert ? null : _toggle,
                    child: ListenableBuilder(
                      listenable: focusNode,
                      builder: (context, _) => InputDecorator(
                        decoration: InputDecoration(
                          labelText: field.label,
                          errorText: errorText,
                          enabled: !disabled,
                          suffixIcon: Icon(
                            menu.isOpen
                                ? Icons.arrow_drop_up
                                : Icons.arrow_drop_down,
                          ),
                        ),
                        // A hint holds the label up, as a chosen item
                        // does.
                        isEmpty: chosen == null && field.hint == null,
                        // The border is the focus indicator, as on a text
                        // field.
                        isFocused: focusNode.hasFocus || menu.isOpen,
                        child: Text(
                          chosen?.label ?? field.hint ?? '',
                          style: chosen == null ? hintStyle : valueStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // From the error text the field shows, so what is announced is what
        // is drawn; the state already rebuilds on status and touch.
        LiveErrorRegion(message: errorText),
      ],
    );
  }
}
