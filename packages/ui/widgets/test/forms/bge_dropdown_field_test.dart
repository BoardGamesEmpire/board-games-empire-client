import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _fruit = <BgeDropdownItem<String>>[
  BgeDropdownItem(value: 'a', label: 'Apple'),
  BgeDropdownItem(value: 'b', label: 'Banana'),
  BgeDropdownItem(value: 'c', label: 'Cherry'),
];

const _long = 'Invite only — members can add guests';

/// A group holding [control] as `fruit`, disposed when the test ends.
FormGroup _form(FormControl<Object?> control) {
  final form = FormGroup({'fruit': control});
  addTearDown(form.dispose);
  return form;
}

Widget _host<T>(
  FormGroup form,
  List<BgeDropdownItem<T>> items, {
  String? hint,
  bool readOnly = false,
  Map<String, String Function(Object)> validationMessages = const {},
  ThemeData? theme,
  double scale = 1,
  bool atBottom = false,
  bool intrinsic = false,
}) {
  final field = BgeDropdownField<T>(
    formControlName: 'fruit',
    label: 'Fruit',
    items: items,
    hint: hint,
    readOnly: readOnly,
    validationMessages: validationMessages,
  );

  return MaterialApp(
    theme: theme ?? BgeTheme.light(),
    // Inside the app, so the menu's overlay is scaled too.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: ReactiveForm(
        formGroup: form,
        // A form's padding, as `BgePage` gives it. A menu keeps 8dp off the
        // screen's edges, so it can't match a field that runs edge to edge.
        child: Padding(
          padding: EdgeInsets.all(BgeTokens.standard.spaceLg),
          child: Align(
            alignment: atBottom ? Alignment.bottomCenter : Alignment.topCenter,
            // An AlertDialog sizes its content this way.
            child: intrinsic ? IntrinsicWidth(child: field) : field,
          ),
        ),
      ),
    ),
  );
}

/// Sets the test view to [size] at a device pixel ratio of 1.
void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder get _field => find.byType(InputDecorator);
Finder get _items => find.byType(MenuItemButton);

/// The menu's surface: the nearest [Material] above its first item.
Finder get _panel =>
    find.ancestor(of: _items.first, matching: find.byType(Material)).first;

Finder _closedText(String text) =>
    find.descendant(of: _field, matching: find.text(text));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(_field);
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String label) async {
  await _open(tester);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Every semantics node, walking down from the root.
Iterable<SemanticsNode> _semanticsNodes(WidgetTester tester) sync* {
  final root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final pending = [root];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    yield node;
    node.visitChildren((child) {
      pending.add(child);
      return true;
    });
  }
}

/// The deepest semantics node whose label is [label] (a [String] matches the
/// whole label, a [RegExp] any part), preferring one flagged as a button.
///
/// Walked from the root because `tester.getSemantics` walks *up* from a
/// widget, and returns an ancestor's node for a widget whose own node sits
/// deeper.
SemanticsNode nodeLabelled(WidgetTester tester, Pattern label) {
  bool matches(String text) =>
      label is RegExp ? label.hasMatch(text) : text == label;

  final found = _semanticsNodes(tester).where((n) => matches(n.label)).toList()
    ..sort((a, b) {
      final button =
          (b.flagsCollection.isButton ? 1 : 0) -
          (a.flagsCollection.isButton ? 1 : 0);
      return button != 0 ? button : b.depth - a.depth;
    });
  expect(found, isNotEmpty, reason: 'no semantics node labelled $label');
  return found.first;
}

/// The closed field's focus node: the one `control.focus()` moves, and the
/// one the menu hands focus back to.
FocusNode _fieldFocus(WidgetTester tester) =>
    tester.widget<MenuAnchor>(find.byType(MenuAnchor)).childFocusNode!;

/// The label of the menu item holding primary focus, or null if none does.
String? _focusedItem(WidgetTester tester) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return null;
  for (final item in _items.evaluate()) {
    var inside = identical(focused, item);
    focused.visitAncestorElements((element) {
      if (identical(element, item)) inside = true;
      return !inside;
    });
    if (inside) {
      return tester
          .widget<Text>(
            find.descendant(
              of: find.byElementPredicate((e) => identical(e, item)),
              matching: find.byType(Text),
            ),
          )
          .data;
    }
  }
  return null;
}

final _platforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.macOS,
});

/// Pumps the field holding 'b' (Banana) and focuses it the way a rejected
/// submit does.
Future<FormControl<String>> _pumpFocused(WidgetTester tester) async {
  final control = FormControl<String>(value: 'b');
  await tester.pumpWidget(_host(_form(control), _fruit));
  control.focus();
  await tester.pumpAndSettle();
  return control;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  group('BgeDropdownField binding', () {
    testWidgets("shows the chosen item's label in the closed field", (
      tester,
    ) async {
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit));

      expect(_closedText('Banana'), findsOneWidget);
    });

    testWidgets('a pick sets the control and touches it', (tester) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(_host(_form(control), _fruit));

      await _pick(tester, 'Cherry');

      expect(control.value, 'c');
      expect(control.touched, isTrue);
      expect(_closedText('Cherry'), findsOneWidget);
    });

    testWidgets('shows a value set on the untouched control', (tester) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(_host(_form(control), _fruit));

      control.value = 'a';
      await tester.pumpAndSettle();

      expect(control.touched, isFalse);
      expect(_closedText('Apple'), findsOneWidget);
    });

    testWidgets('a value missing from the items shows the hint and keeps the '
        'value', (tester) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(_host(_form(control), _fruit, hint: 'Pick one'));

      control.value = 'zzz';
      await tester.pumpAndSettle();

      expect(_closedText('Pick one'), findsOneWidget);
      expect(control.value, 'zzz');
    });

    testWidgets('a null value matches an item whose value is null', (
      tester,
    ) async {
      final form = _form(FormControl<String?>());
      await tester.pumpWidget(
        _host<String?>(form, const [
          BgeDropdownItem(value: null, label: 'None'),
          BgeDropdownItem(value: 'a', label: 'Apple'),
        ], hint: 'Pick one'),
      );

      expect(_closedText('None'), findsOneWidget);
      expect(find.text('Pick one'), findsNothing);
    });

    testWidgets('read-only does not open', (tester) async {
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit, readOnly: true));

      await tester.tap(_field, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(_items, findsNothing);
    });

    // The in-flight state: read-only, never disabled (STYLE_GUIDE, "In-flight
    // forms"). A keyboard or screen-reader user keeps the field, as they keep
    // a read-only text field, and the form isn't greyed out.
    testWidgets('read-only stays in the focus order and is not drawn '
        'disabled', (tester) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(_host(_form(control), _fruit, readOnly: true));

      control.focus();
      await tester.pumpAndSettle();

      expect(_fieldFocus(tester).hasFocus, isTrue);
      expect(tester.widget<InputDecorator>(_field).decoration.enabled, isTrue);

      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.space);

      expect(_items, findsNothing);
      expect(control.value, 'b');
    }, variant: _platforms);

    testWidgets('a disabled control does not open and takes no focus', (
      tester,
    ) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(_host(_form(control), _fruit));

      control.markAsDisabled();
      await tester.pumpAndSettle();
      await tester.tap(_field, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(_items, findsNothing);
      expect(tester.widget<InputDecorator>(_field).decoration.enabled, isFalse);

      control.focus();
      await tester.pumpAndSettle();

      expect(_fieldFocus(tester).hasFocus, isFalse);
    });

    // The create event form turns read-only on submit, and when the
    // households it offers are read again, neither of which waits for the
    // menu.
    testWidgets('an open menu closes when the field turns read-only, and '
        'takes no pick meanwhile', (tester) async {
      final control = FormControl<String>(value: 'b');
      final form = _form(control);
      await tester.pumpWidget(_host(form, _fruit));
      await _open(tester);

      await tester.pumpWidget(_host(form, _fruit, readOnly: true));
      expect(_items, findsWidgets, reason: 'open until after this frame');
      await tester.tap(find.text('Cherry').last, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(_items, findsNothing);
      expect(control.value, 'b');
    });

    testWidgets('an open menu closes when the control is disabled', (
      tester,
    ) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(_host(_form(control), _fruit));
      await _open(tester);

      control.markAsDisabled();
      // The status arrives on a stream, so it is in before the next frame.
      await tester.idle();
      await tester.pump();
      expect(_items, findsWidgets, reason: 'open until after this frame');
      await tester.tap(find.text('Cherry').last, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(_items, findsNothing);
      expect(control.value, 'b');
    });

    // #186: a form reset by handing ReactiveForm a new group, with the field
    // left mounted.
    testWidgets('follows a swapped form group', (tester) async {
      final old = _form(FormControl<String>(value: 'a'));
      final control = FormControl<String>(
        value: 'b',
        validators: [Validators.required],
      );
      await tester.pumpWidget(_host(old, _fruit));

      await tester.pumpWidget(
        _host(
          _form(control),
          _fruit,
          validationMessages: {ValidationMessage.required: (_) => 'Choose one'},
        ),
      );
      await tester.pumpAndSettle();

      expect(_closedText('Banana'), findsOneWidget);

      await _pick(tester, 'Cherry');

      expect(control.value, 'c');
      expect(old.control('fruit').value, 'a');

      final handle = tester.ensureSemantics();
      control.value = null;
      await tester.pumpAndSettle();

      expect(find.text('Choose one'), findsOneWidget);
      expect(
        _semanticsNodes(tester).where(
          (node) =>
              node.label == 'Choose one' && node.flagsCollection.isLiveRegion,
        ),
        hasLength(1),
      );
      handle.dispose();
    });

    testWidgets('an error with no message of its own is announced as it is '
        'shown', (tester) async {
      final handle = tester.ensureSemantics();
      final control = FormControl<String>(validators: [Validators.required]);
      await tester.pumpWidget(_host(_form(control), _fruit));

      control.markAsTouched();
      await tester.pumpAndSettle();

      // reactive_forms shows the error's key when nothing names it.
      expect(find.text(ValidationMessage.required), findsOneWidget);
      expect(
        _semanticsNodes(tester).where(
          (node) =>
              node.label == ValidationMessage.required &&
              node.flagsCollection.isLiveRegion,
        ),
        hasLength(1),
      );
      handle.dispose();
    });

    testWidgets('a required error shows and is announced once touched', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final control = FormControl<String>(validators: [Validators.required]);
      await tester.pumpWidget(
        _host(
          _form(control),
          _fruit,
          validationMessages: {ValidationMessage.required: (_) => 'Choose one'},
        ),
      );

      expect(find.text('Choose one'), findsNothing);

      control.markAsTouched();
      await tester.pumpAndSettle();

      expect(find.text('Choose one'), findsOneWidget);
      // The live region BgeTextField announces through, not just the drawn
      // error: a screen reader would otherwise learn of it only by coming
      // back to the field.
      expect(
        _semanticsNodes(tester).where(
          (node) =>
              node.label == 'Choose one' && node.flagsCollection.isLiveRegion,
        ),
        hasLength(1),
      );
      handle.dispose();
    });

    testWidgets('reset shows the hint again', (tester) async {
      final control = FormControl<String>();
      await tester.pumpWidget(_host(_form(control), _fruit, hint: 'Pick one'));

      await _pick(tester, 'Cherry');
      expect(_closedText('Cherry'), findsOneWidget);

      control.reset();
      await tester.pumpAndSettle();

      expect(_closedText('Pick one'), findsOneWidget);
      expect(control.value, isNull);
    });

    testWidgets('a server error set on the control shows', (tester) async {
      final control = FormControl<String>(value: 'b');
      await tester.pumpWidget(
        _host(
          _form(control),
          _fruit,
          validationMessages: {'server': (error) => error as String},
        ),
      );

      control.setErrors({'server': 'Taken'});
      control.markAsTouched();
      await tester.pumpAndSettle();

      expect(find.text('Taken'), findsOneWidget);
    });

    testWidgets('items changed while the menu is open are the ones offered', (
      tester,
    ) async {
      final control = FormControl<String>(value: 'b');
      final form = _form(control);
      await tester.pumpWidget(_host(form, _fruit));
      await _open(tester);

      await tester.pumpWidget(_host(form, [_fruit[0], _fruit[2]]));
      await tester.pumpAndSettle();

      expect(find.text('Banana'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Cherry').last);
      await tester.pumpAndSettle();

      expect(control.value, 'c');
    });
  });

  group('BgeDropdownField popover', () {
    testWidgets('opens under the field, as wide as the field, with the field '
        'in view', (tester) async {
      _view(tester, const Size(390, 844));
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit));

      await _open(tester);

      final field = tester.getRect(_field);
      final panel = tester.getRect(_panel);
      expect(field.top, greaterThanOrEqualTo(0));
      expect(panel.top, greaterThanOrEqualTo(field.bottom));
      expect(panel.width, moreOrLessEquals(field.width));
    });

    testWidgets('lays out under an intrinsic width, as in a dialog, and '
        'opens as wide as the field', (tester) async {
      _view(tester, const Size(390, 844));
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit, intrinsic: true));

      expect(tester.takeException(), isNull);

      await _open(tester);

      expect(
        tester.getRect(_panel).width,
        moreOrLessEquals(tester.getRect(_field).width),
      );
    });

    testWidgets('flips above the field near the bottom of the screen', (
      tester,
    ) async {
      _view(tester, const Size(390, 844));
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit, atBottom: true));

      await _open(tester);

      final field = tester.getRect(_field);
      final panel = tester.getRect(_panel);
      expect(field.bottom, lessThanOrEqualTo(844));
      expect(panel.bottom, lessThanOrEqualTo(field.top));
    });

    testWidgets('the panel is rounded at radiusMd', (tester) async {
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit));

      await _open(tester);

      final shape = tester.widget<Material>(_panel).shape;
      expect(shape, isA<RoundedRectangleBorder>());
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(BgeTokens.standard.radiusMd),
      );
    });

    testWidgets('items are at least minTapTarget tall', (tester) async {
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit));

      await _open(tester);

      expect(_items, findsNWidgets(_fruit.length));
      for (final item in _items.evaluate()) {
        expect(
          item.size!.height,
          greaterThanOrEqualTo(BgeTokens.standard.minTapTarget),
        );
      }
    });

    testWidgets('a long choice wraps in the closed field and in the menu at '
        '320dp × 2.0', (tester) async {
      _view(tester, const Size(320, 844));
      final form = _form(FormControl<String>(value: 'long'));
      await tester.pumpWidget(
        _host(form, const [
          BgeDropdownItem(value: 'long', label: _long),
          BgeDropdownItem(value: 'a', label: 'Apple'),
        ], scale: 2),
      );

      final closed = _closedText(_long);
      expect(
        tester.getRect(_field).contains(tester.getTopLeft(closed)),
        isTrue,
      );
      expect(
        tester
            .getRect(_field)
            .contains(tester.getBottomRight(closed) - const Offset(1, 1)),
        isTrue,
      );
      final rich = tester.widget<RichText>(
        find.descendant(of: closed, matching: find.byType(RichText)),
      );
      final oneLine = TextPainter(
        text: TextSpan(text: 'X', style: rich.text.style),
        textScaler: rich.textScaler,
        textDirection: TextDirection.ltr,
      )..layout();
      addTearDown(oneLine.dispose);
      expect(tester.getSize(closed).height, greaterThan(oneLine.height * 1.5));

      await _open(tester);

      final panel = tester.getRect(_panel);
      final item = find.descendant(
        of: _items.first,
        matching: find.text(_long),
      );
      expect(panel.contains(tester.getTopLeft(item)), isTrue);
      expect(
        panel.contains(tester.getBottomRight(item) - const Offset(1, 1)),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('menu text meets contrast in every theme', (tester) async {
      final control = FormControl<String>(value: 'b');
      final form = _form(control);
      final themes = [
        (name: 'light', theme: BgeTheme.light(), floor: Wcag.aaNormalText),
        (name: 'dark', theme: BgeTheme.dark(), floor: Wcag.aaNormalText),
        (
          name: 'high-contrast light',
          theme: BgeTheme.highContrastLight(),
          floor: Wcag.aaaNormalText,
        ),
        (
          name: 'high-contrast dark',
          theme: BgeTheme.highContrastDark(),
          floor: Wcag.aaaNormalText,
        ),
      ];

      for (final (:name, :theme, :floor) in themes) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_host(form, _fruit, theme: theme));
        await _open(tester);

        final label = tester.widget<RichText>(
          find.descendant(
            of: _items.first,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is RichText && widget.text.toPlainText() == 'Apple',
            ),
          ),
        );
        final foreground = label.text.style!.color!;
        final background = tester.widget<Material>(_panel).color!;
        expect(
          Wcag.contrastRatio(foreground, background),
          greaterThanOrEqualTo(floor),
          reason: name,
        );
      }
    });
  });

  // #648's list, measured on the old menu on Android and macOS: it must not
  // regress on either.
  group('BgeDropdownField keyboard and screen reader', () {
    testWidgets('is a button with an expanded state', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpFocused(tester);

      var node = nodeLabelled(tester, RegExp('Fruit'));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isExpanded, Tristate.isFalse);

      await _key(tester, LogicalKeyboardKey.enter);

      node = nodeLabelled(tester, RegExp('Fruit'));
      expect(node.flagsCollection.isExpanded, Tristate.isTrue);
      handle.dispose();
    }, variant: _platforms);

    // A read-only text field says so; this one must too, and must not
    // promise a menu a double tap won't open.
    testWidgets('read-only reads as read-only, with no menu to expand', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final form = _form(FormControl<String>(value: 'b'));
      await tester.pumpWidget(_host(form, _fruit, readOnly: true));

      final node = nodeLabelled(tester, RegExp('Fruit'));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isReadOnly, isTrue);
      expect(node.flagsCollection.isEnabled, Tristate.isTrue);
      expect(node.flagsCollection.isExpanded, Tristate.none);
      handle.dispose();
    });

    testWidgets('a disabled control reads as disabled, with no menu to '
        'expand', (tester) async {
      final handle = tester.ensureSemantics();
      final control = FormControl<String>(value: 'b', disabled: true);
      await tester.pumpWidget(_host(_form(control), _fruit));

      final node = nodeLabelled(tester, RegExp('Fruit'));
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
      expect(node.flagsCollection.isExpanded, Tristate.none);
      handle.dispose();
    });

    testWidgets('Enter opens it', (tester) async {
      await _pumpFocused(tester);

      await _key(tester, LogicalKeyboardKey.enter);

      expect(_items, findsWidgets);
    }, variant: _platforms);

    testWidgets('Space opens it', (tester) async {
      await _pumpFocused(tester);

      await _key(tester, LogicalKeyboardKey.space);

      expect(_items, findsWidgets);
    }, variant: _platforms);

    testWidgets('focus starts on the chosen item', (tester) async {
      await _pumpFocused(tester);

      await _key(tester, LogicalKeyboardKey.enter);

      expect(_focusedItem(tester), 'Banana');
    }, variant: _platforms);

    testWidgets('the arrows move through it', (tester) async {
      await _pumpFocused(tester);
      await _key(tester, LogicalKeyboardKey.enter);

      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedItem(tester), 'Cherry');

      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusedItem(tester), 'Banana');
    }, variant: _platforms);

    testWidgets('Enter picks', (tester) async {
      final control = await _pumpFocused(tester);
      await _key(tester, LogicalKeyboardKey.enter);

      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);

      expect(control.value, 'c');
      expect(_items, findsNothing);
    }, variant: _platforms);

    testWidgets('Escape closes it and leaves the value', (tester) async {
      final control = await _pumpFocused(tester);
      await _key(tester, LogicalKeyboardKey.enter);

      await _key(tester, LogicalKeyboardKey.escape);

      expect(_items, findsNothing);
      expect(control.value, 'b');
    }, variant: _platforms);

    testWidgets('focus returns to the field after Escape, and after a pick', (
      tester,
    ) async {
      await _pumpFocused(tester);

      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(_fieldFocus(tester).hasFocus, isTrue, reason: 'after Escape');

      await _key(tester, LogicalKeyboardKey.enter);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(_fieldFocus(tester).hasFocus, isTrue, reason: 'after a pick');
    }, variant: _platforms);

    testWidgets('focus returns to the field after a tap outside', (
      tester,
    ) async {
      await _pumpFocused(tester);
      // Blank page, below the field and clear of the menu.
      const outside = Offset(400, 580);

      await _key(tester, LogicalKeyboardKey.enter);
      expect(_focusedItem(tester), 'Banana');
      await tester.tapAt(outside);
      await tester.pumpAndSettle();
      expect(_items, findsNothing);
      expect(_fieldFocus(tester).hasFocus, isTrue, reason: 'keyboard open');

      await _open(tester);
      await tester.tapAt(outside);
      await tester.pumpAndSettle();
      expect(_items, findsNothing);
      expect(_fieldFocus(tester).hasFocus, isTrue, reason: 'tap open');
    }, variant: _platforms);

    testWidgets('the chosen item reads as selected', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpFocused(tester);

      await _key(tester, LogicalKeyboardKey.enter);

      expect(
        nodeLabelled(tester, 'Banana').flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(
        nodeLabelled(tester, 'Apple').flagsCollection.isSelected,
        isNot(Tristate.isTrue),
      );
      handle.dispose();
    }, variant: _platforms);

    testWidgets('control.focus() focuses the field', (tester) async {
      await _pumpFocused(tester);

      expect(_fieldFocus(tester).hasFocus, isTrue);
    }, variant: _platforms);
  });
}
