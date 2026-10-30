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
/// `material_ui` (#637). This builds on `ReactiveFocusableFormField`, which
/// is Material-free at runtime, so the Material types stay in this package
/// (#649). Its state registers the `FocusController` that lets
/// `control.focus()` reach the field, which is how a rejected submit lands on
/// the first invalid one (#230).
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
/// ## Why read-only doesn't open
///
/// [readOnly] is the in-flight state: the value was captured at submit, and a
/// pick would be dropped. The field is drawn disabled and takes no focus, as
/// `ReactiveDropdownField` drew it, and as it draws a disabled control.
class BgeDropdownField<T> extends ReactiveFocusableFormField<T, T> {
  /// Creates a field bound to [formControlName] in the enclosing
  /// `ReactiveForm`, or to [formControl].
  BgeDropdownField({
    required this.label,
    required this.items,
    this.hint,
    this.readOnly = false,
    Map<String, String Function(Object)> validationMessages = const {},
    super.formControlName,
    super.formControl,
    super.key,
  }) : super(
         validationMessages: validationMessages,
         builder: (field) => (field as _BgeDropdownFieldState<T>)._build(),
       );

  /// Visible label. Also the field's accessible name.
  final String label;

  /// The choices, in the menu's order.
  final List<BgeDropdownItem<T>> items;

  /// Shown in the closed field while the control's value matches no item.
  final String? hint;

  /// Whether the field takes no pick: the menu doesn't open.
  final bool readOnly;

  @override
  ReactiveFormFieldState<T, T> createState() => _BgeDropdownFieldState<T>();
}

class _BgeDropdownFieldState<T> extends ReactiveFocusableFormFieldState<T, T> {
  final _menu = MenuController();

  // A value set on the control in code needs no hook of its own here: the
  // control reports a status with every value (reactive_forms 18.2.2,
  // `models.dart:701-704`), and the base class rebuilds on each status,
  // touched or not.
  BgeDropdownField<T> get _field => widget as BgeDropdownField<T>;

  Widget _build() {
    final field = _field;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = BgeTokens.of(context);
    final closed = field.readOnly || control.disabled;
    final value = this.value;
    // A null value matches an item whose value is null, which is how a
    // "none" choice reads as chosen.
    final chosen = field.items.where((item) => item.value == value).firstOrNull;

    // The closed field's text is drawn as `DropdownButton` drew it, so the
    // field looks as it did before the menu changed (#648). The hint takes
    // the color text fields' hints take.
    final valueStyle = theme.textTheme.titleMedium?.copyWith(
      color: closed ? theme.disabledColor : null,
    );
    final hintStyle = valueStyle?.copyWith(
      color: closed ? theme.disabledColor : scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => MenuAnchor(
            controller: _menu,
            childFocusNode: focusNode,
            // As wide as the field that opens it. Left unconstrained, the
            // panel takes its widest item's width and clips a long one.
            crossAxisUnconstrained: false,
            style: MenuStyle(
              minimumSize: WidgetStatePropertyAll(
                Size(constraints.maxWidth, 0),
              ),
              maximumSize: WidgetStatePropertyAll(
                Size(constraints.maxWidth, double.infinity),
              ),
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
                  leadingIcon: Icon(
                    identical(item, chosen) ? Icons.check : null,
                  ),
                  overflowAxis: Axis.vertical,
                  style: MenuItemButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                  ),
                  onPressed: () {
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
            builder: (context, menu, _) => InkWell(
              focusNode: focusNode,
              borderRadius: BorderRadius.circular(tokens.radiusSm),
              onTap: closed
                  ? null
                  : () => menu.isOpen ? menu.close() : menu.open(),
              child: ListenableBuilder(
                listenable: focusNode,
                builder: (context, _) => InputDecorator(
                  decoration: InputDecoration(
                    labelText: field.label,
                    errorText: errorText,
                    enabled: !closed,
                    suffixIcon: Icon(
                      menu.isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    ),
                  ),
                  // A hint holds the label up, as a chosen item does.
                  isEmpty: chosen == null && field.hint == null,
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
        LiveErrorAnnouncer(
          control: control,
          validationMessages: field.validationMessages ?? const {},
        ),
      ],
    );
  }
}
