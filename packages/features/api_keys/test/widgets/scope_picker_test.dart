import 'package:api_keys/src/widgets/scope_picker.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

const _noneWarning = 'With no permissions, this key works nowhere.';

final GrantablePermission _read = permission(
  'collection:read',
  description: 'Read your games',
);
final GrantablePermission _write = permission(
  'collection:write',
  riskLevel: RiskLevel.medium,
  description: 'Change your games',
);
final GrantablePermission _users = permission(
  'users:manage',
  riskLevel: RiskLevel.critical,
  description: 'Manage every user',
);
final GrantablePermission _webhooks = permission(
  'webhooks:manage',
  riskLevel: RiskLevel.high,
  description: 'Manage your webhooks',
  pinnable: true,
);

final List<GrantablePermission> _grantable = [_read, _write, _users, _webhooks];

void main() {
  /// What the picker last asked for, or null before it asked.
  ScopeSelection? changed;

  setUp(() => changed = null);

  Future<void> pump(
    WidgetTester tester, {
    List<GrantablePermission>? grantable,
    ScopeSelection selection = const PickedScopes([]),
    List<ApiKeyScope> held = const [],
    bool offerEverything = true,
    bool readOnly = false,
    String? refusedSlug,
    String? refusedMessage,
  }) => pumpOnPage(
    tester,
    ScopePicker(
      grantable: grantable ?? _grantable,
      selection: selection,
      onChanged: (value) => changed = value,
      held: held,
      offerEverything: offerEverything,
      readOnly: readOnly,
      refusedSlug: refusedSlug,
      refusedMessage: refusedMessage,
    ),
  );

  CheckboxListTile tile(WidgetTester tester, String words) =>
      tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text(words),
          matching: find.byType(CheckboxListTile),
        ),
      );

  /// The one node a row reads as, found by words on it.
  SemanticsData rowNode(WidgetTester tester, String words) =>
      tester.getSemantics(find.text(words)).getSemanticsData();

  /// The rows' titles, in the order they are built.
  List<String> rowTitles(WidgetTester tester) => tester
      .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
      .map((tile) => (tile.title! as Text).data!)
      .toList();

  group('ScopePicker', () {
    testWidgets('ticking a row adds its scope unpinned', (tester) async {
      await pump(
        tester,
        selection: const PickedScopes([ApiKeyScope(slug: 'collection:read')]),
      );

      await tester.tap(find.text('Change your games'));
      await tester.pump();

      expect(
        changed,
        const PickedScopes([
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'collection:write'),
        ]),
      );
      final picks = (changed! as PickedScopes).scopes;
      expect(picks.last.resourceId, isNull);
    });

    testWidgets('unticking a row takes its scope out and keeps the rest', (
      tester,
    ) async {
      const pinned = ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1');
      await pump(
        tester,
        held: const [
          pinned,
          ApiKeyScope(slug: 'webhooks:manage'),
        ],
        selection: const PickedScopes([
          pinned,
          ApiKeyScope(slug: 'webhooks:manage'),
          ApiKeyScope(slug: 'collection:read'),
        ]),
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(
            ScopePicker.rowKey(const ApiKeyScope(slug: 'webhooks:manage')),
          ),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();

      expect(
        changed,
        const PickedScopes([pinned, ApiKeyScope(slug: 'collection:read')]),
      );
    });

    testWidgets("the checkbox's name reads description and risk", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        selection: const PickedScopes([ApiKeyScope(slug: 'users:manage')]),
      );

      final node = rowNode(tester, 'Manage every user');

      expect(node.label, contains('Manage every user'));
      expect(node.label, contains('Risk: Critical'));
      expect(node.label, contains('users:manage'));
      // One node: the risk is read with the box it describes, not apart.
      expect(
        tester.getSemantics(find.text('Risk: Critical')).id,
        tester.getSemantics(find.text('Manage every user')).id,
      );
      expect(
        tester.getSemantics(find.text('Manage every user')),
        isSemantics(
          hasCheckedState: true,
          isChecked: true,
          hasTapAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      expect(node.flagsCollection.isReadOnly, isFalse);
      handle.dispose();
    });

    testWidgets('risk is stated in text', (tester) async {
      await pump(tester);

      expect(find.text('Risk: Low'), findsOneWidget);
      expect(find.text('Risk: Medium'), findsOneWidget);
      expect(find.text('Risk: High'), findsOneWidget);
      expect(find.text('Risk: Critical'), findsOneWidget);
      // With the code beside it, in the small style.
      final slug = tester.widget<Text>(find.text('users:manage'));
      expect(
        slug.style?.fontSize,
        Theme.of(
          tester.element(find.text('users:manage')),
        ).textTheme.bodySmall?.fontSize,
      );
    });

    testWidgets('rows come in the server order, then the held ones', (
      tester,
    ) async {
      await pump(
        tester,
        held: const [
          ApiKeyScope(slug: 'events:delete'),
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
        ],
        offerEverything: false,
      );

      expect(rowTitles(tester), [
        'Read your games',
        'Change your games',
        'Manage every user',
        'Manage your webhooks',
        // Held, in the key's order. An unpinned held scope that may still
        // be given is its grantable row.
        'events:delete',
        'Manage your webhooks',
      ]);
    });

    testWidgets('a focused row is ringed (#758)', (tester) async {
      await pump(tester);

      expect(
        await keyboardFocusShowsRing(tester, find.text('Read your games')),
        isTrue,
      );
    });

    group('everything I can do', () {
      testWidgets('turning it on asks for the preset', (tester) async {
        await pump(tester);

        await tester.tap(find.text('Everything I can do'));
        await tester.pump();

        expect(changed, const EverythingScopes());
      });

      testWidgets('turning it off leaves nothing picked', (tester) async {
        await pump(tester, selection: const EverythingScopes());

        await tester.tap(find.text('Everything I can do'));
        await tester.pump();

        expect(changed, const PickedScopes([]));
      });

      testWidgets('everything checks every row read-only', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, selection: const EverythingScopes());

        expect(find.text('Includes 4 permissions'), findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        for (final permission in _grantable) {
          expect(tile(tester, permission.description).value, isTrue);
          final node = rowNode(tester, permission.description);
          expect(node.flagsCollection.isReadOnly, isTrue);
          expect(node.hasAction(SemanticsAction.tap), isFalse);
          expect(node.hasAction(SemanticsAction.focus), isTrue);
        }

        await tester.tap(find.text('Change your games'), warnIfMissed: false);
        await tester.pump();

        expect(changed, isNull);
        handle.dispose();
      });

      testWidgets('is not offered when the screen has no preset', (
        tester,
      ) async {
        await pump(tester, offerEverything: false);

        expect(find.text('Everything I can do'), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
      });
    });

    group('held scopes', () {
      const pinned = ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1');

      testWidgets('a pinned held scope stays and cannot be unticked', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          held: const [
            pinned,
            ApiKeyScope(slug: 'collection:read'),
          ],
          selection: const PickedScopes([
            pinned,
            ApiKeyScope(slug: 'collection:read'),
          ]),
          offerEverything: false,
        );

        final row = find.byKey(ScopePicker.rowKey(pinned));
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: row,
            matching: find.text('Limited to one record'),
          ),
          findsOneWidget,
        );
        final node = tester
            .getSemantics(
              find.descendant(
                of: row,
                matching: find.text('Limited to one record'),
              ),
            )
            .getSemanticsData();
        expect(node.label, contains('Manage your webhooks'));
        expect(node.label, contains('Risk: High'));
        expect(node.label, contains('Limited to one record'));
        expect(node.flagsCollection.isReadOnly, isTrue);
        expect(node.hasAction(SemanticsAction.tap), isFalse);
        expect(node.hasAction(SemanticsAction.focus), isTrue);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.descendant(
                  of: row,
                  matching: find.byType(CheckboxListTile),
                ),
              )
              .value,
          isTrue,
        );

        await tester.tap(
          find.descendant(of: row, matching: find.byType(Checkbox)),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(changed, isNull);

        // Ticking the slug's own row leaves the pin as it was.
        await tester.tap(
          find.descendant(
            of: find.byKey(
              ScopePicker.rowKey(const ApiKeyScope(slug: 'webhooks:manage')),
            ),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.pump();
        expect(
          changed,
          const PickedScopes([
            pinned,
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'webhooks:manage'),
          ]),
        );
        handle.dispose();
      });

      testWidgets(
        'a no-longer-available scope says saving removes it once the picks '
        'change',
        (tester) async {
          const gone = ApiKeyScope(slug: 'events:delete');
          const held = [gone, ApiKeyScope(slug: 'collection:read')];
          await pump(
            tester,
            held: held,
            // As the edit screen opens: what the key holds, but what may no
            // longer be given.
            selection: const PickedScopes([
              ApiKeyScope(slug: 'collection:read'),
            ]),
            offerEverything: false,
          );

          final row = find.byKey(ScopePicker.rowKey(gone));
          expect(
            find.descendant(of: row, matching: find.text('events:delete')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: row,
              matching: find.text('No longer available'),
            ),
            findsOneWidget,
          );
          expect(
            find.text('No longer available; saving removes it'),
            findsNothing,
          );
          // The key still holds it while nothing changed.
          CheckboxListTile goneTile() => tester.widget<CheckboxListTile>(
            find.descendant(of: row, matching: find.byType(CheckboxListTile)),
          );
          expect(goneTile().value, isTrue);

          // It can't be ticked or unticked.
          await tester.tap(
            find.descendant(of: row, matching: find.byType(Checkbox)),
            warnIfMissed: false,
          );
          await tester.pump();
          expect(changed, isNull);

          // The picks change.
          await pump(
            tester,
            held: held,
            selection: const PickedScopes([
              ApiKeyScope(slug: 'collection:read'),
              ApiKeyScope(slug: 'collection:write'),
            ]),
            offerEverything: false,
          );

          expect(
            find.descendant(
              of: row,
              matching: find.text('No longer available; saving removes it'),
            ),
            findsOneWidget,
          );
          expect(find.text('No longer available'), findsNothing);
          expect(goneTile().value, isFalse);
        },
      );

      testWidgets('a pinned scope no longer available says both', (
        tester,
      ) async {
        const gone = ApiKeyScope(slug: 'jobs:manage', resourceId: 'job_1');
        await pump(
          tester,
          held: const [gone],
          offerEverything: false,
        );

        final row = find.byKey(ScopePicker.rowKey(gone));
        expect(
          find.descendant(of: row, matching: find.text('jobs:manage')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.text('No longer available'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.text('Limited to one record'),
          ),
          findsOneWidget,
        );
      });
    });

    testWidgets('no picks warns the key works nowhere', (tester) async {
      await pump(tester);

      final banner = find.ancestor(
        of: find.text(_noneWarning),
        matching: find.byType(BgeInlineBanner),
      );
      expect(banner, findsOneWidget);
      final widget = tester.widget<BgeInlineBanner>(banner);
      expect(widget.tone, BgeBannerTone.warning);
      expect(widget.reveal, isFalse);

      // A pick, or the preset, takes it away.
      await pump(
        tester,
        selection: const PickedScopes([ApiKeyScope(slug: 'collection:read')]),
      );
      expect(find.text(_noneWarning), findsNothing);
      await pump(tester, selection: const EverythingScopes());
      expect(find.text(_noneWarning), findsNothing);
    });

    testWidgets("a refused slug's row says why", (tester) async {
      final handle = tester.ensureSemantics();
      const message = "You can't give a key the permission Manage every user.";
      await pump(
        tester,
        selection: const PickedScopes([ApiKeyScope(slug: 'users:manage')]),
        refusedSlug: 'users:manage',
        refusedMessage: message,
      );

      final row = find.byKey(
        ScopePicker.rowKey(const ApiKeyScope(slug: 'users:manage')),
      );
      expect(
        find.descendant(of: row, matching: find.text(message)),
        findsOneWidget,
      );
      expect(find.text(message), findsOneWidget);
      final text = tester.widget<Text>(find.text(message));
      final theme = Theme.of(tester.element(find.text(message)));
      expect(text.style?.color, theme.colorScheme.error);
      // Read with the row it is about.
      final node = rowNode(tester, message);
      expect(node.label, contains('Manage every user'));
      expect(node.label, contains(message));
      handle.dispose();
    });

    testWidgets('a refused pinned or held row says why', (tester) async {
      const message = "The permission can't be limited to one record.";
      const pinned = ApiKeyScope(slug: 'jobs:manage', resourceId: 'job_1');
      await pump(
        tester,
        held: const [pinned],
        offerEverything: false,
        refusedSlug: 'jobs:manage',
        refusedMessage: message,
      );

      expect(
        find.descendant(
          of: find.byKey(ScopePicker.rowKey(pinned)),
          matching: find.text(message),
        ),
        findsOneWidget,
      );
    });

    testWidgets('read-only ignores ticks and keeps rows focusable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, readOnly: true);

      for (final words in ['Everything I can do', 'Read your games']) {
        final node = rowNode(tester, words);
        expect(node.flagsCollection.isReadOnly, isTrue, reason: words);
        expect(node.hasAction(SemanticsAction.tap), isFalse, reason: words);
        expect(node.hasAction(SemanticsAction.focus), isTrue, reason: words);
      }
      // Never disabled: a disabled tile leaves the focus order.
      expect(tile(tester, 'Read your games').onChanged, isNotNull);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNotNull,
      );

      Focus.of(tester.element(find.text('Read your games'))).requestFocus();
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text('Read your games'))).hasFocus,
        isTrue,
      );

      await tester.tap(find.text('Read your games'), warnIfMissed: false);
      await tester.tap(find.text('Everything I can do'), warnIfMissed: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(changed, isNull);
      handle.dispose();
    });

    testWidgets('320dp at 2.0 lays out without overflow', (tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pump(
        tester,
        grantable: [
          ..._grantable,
          permission(
            'household_bans:manage',
            riskLevel: RiskLevel.critical,
            description:
                'Ban people from your households, and lift bans you set',
          ),
        ],
        held: const [
          ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
          ApiKeyScope(slug: 'notifications:manage_everything'),
        ],
        selection: const PickedScopes([
          ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
          ApiKeyScope(slug: 'household_bans:manage'),
        ]),
        refusedSlug: 'household_bans:manage',
        refusedMessage:
            "You can't give a key the permission Ban people from your "
            'households, and lift bans you set.',
      );

      expect(tester.takeException(), isNull);

      await pump(tester, selection: const EverythingScopes());
      expect(tester.takeException(), isNull);

      await pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(_noneWarning), findsOneWidget);
    });
  });

  group('criticalIn', () {
    test("criticalIn counts the preset's Critical permissions", () {
      final ban = permission('bans:manage', riskLevel: RiskLevel.critical);

      expect(criticalIn(const EverythingScopes(), [..._grantable, ban]), [
        _users,
        ban,
      ]);
      expect(criticalIn(const EverythingScopes(), [_read, _write]), isEmpty);
    });

    test('counts the picked Critical permissions, pinned ones too', () {
      final ban = permission('bans:manage', riskLevel: RiskLevel.critical);

      expect(
        criticalIn(
          const PickedScopes([
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'bans:manage', resourceId: 'ban_1'),
          ]),
          [..._grantable, ban],
        ),
        [ban],
      );
      expect(
        criticalIn(
          const PickedScopes([ApiKeyScope(slug: 'collection:write')]),
          _grantable,
        ),
        isEmpty,
      );
    });

    test('never counts a scope that may no longer be given', () {
      expect(
        criticalIn(
          const PickedScopes([ApiKeyScope(slug: 'users:delete')]),
          _grantable,
        ),
        isEmpty,
      );
    });
  });

  group('ScopeSelection', () {
    test('picks are equal by their scopes, in order', () {
      // A list made at run time, not the same constant.
      final scopes = [
        for (final slug in ['a']) ApiKeyScope(slug: slug),
      ];
      expect(
        const PickedScopes([ApiKeyScope(slug: 'a')]),
        PickedScopes(scopes),
      );
      expect(
        const PickedScopes([ApiKeyScope(slug: 'a')]).hashCode,
        PickedScopes(scopes).hashCode,
      );
      expect(
        const PickedScopes([ApiKeyScope(slug: 'a')]),
        isNot(const PickedScopes([ApiKeyScope(slug: 'b')])),
      );
      expect(const PickedScopes([]), isNot(const EverythingScopes()));
    });
  });
}
