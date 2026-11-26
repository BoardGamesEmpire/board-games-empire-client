import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/widgets/api_key_scope_list.dart';
import 'package:api_keys/src/widgets/read_only_focusable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The permissions a key is to hold, as the scope picker gives them (#1028).
@immutable
sealed class ScopeSelection {
  const ScopeSelection();
}

/// The scopes the user picked, in the order they were picked, with any
/// pinned scope the key already holds kept as it was.
final class PickedScopes extends ScopeSelection {
  const PickedScopes(this.scopes);

  final List<ApiKeyScope> scopes;

  @override
  bool operator ==(Object other) =>
      other is PickedScopes && listEquals(other.scopes, scopes);

  @override
  int get hashCode => Object.hashAll(scopes);

  @override
  String toString() => 'PickedScopes($scopes)';
}

/// "Everything I can do": every permission the user may give, sent as the
/// server's preset. Only a new key can have it.
final class EverythingScopes extends ScopeSelection {
  const EverythingScopes();

  @override
  bool operator ==(Object other) => other is EverythingScopes;

  @override
  int get hashCode => (EverythingScopes).hashCode;

  @override
  String toString() => 'EverythingScopes()';
}

/// The Critical permissions in [selection], in [grantable]'s order: the
/// ones that must be confirmed before a key is given them (#1028).
///
/// The preset adds every grantable permission, so it holds every Critical
/// one. Picked scopes are matched by slug, pinned or not. A scope whose slug
/// [grantable] doesn't have is never counted: it can't be sent.
List<GrantablePermission> criticalIn(
  ScopeSelection selection,
  List<GrantablePermission> grantable,
) {
  final critical = grantable.where(
    (permission) => permission.riskLevel == RiskLevel.critical,
  );
  return switch (selection) {
    EverythingScopes() => critical.toList(),
    PickedScopes(:final scopes) => [
      for (final permission in critical)
        if (scopes.any((scope) => scope.slug == permission.slug)) permission,
    ],
  };
}

/// Picks the permissions an API key holds (#1028).
///
/// It holds no selection of its own: it shows [selection], and asks for a
/// new one through [onChanged].
///
/// ## Rows
///
/// First, when [offerEverything] is set, an "Everything I can do" switch. While
/// it is on, every row shows ticked and read-only, and a line under it says
/// how many permissions it includes: the preset shows what it will add.
///
/// Then a row for each of [grantable], in the server's order: its
/// description, its risk level in words and its code, read with its checkbox
/// as one. Ticking it adds its scope unpinned; unticking takes that out.
///
/// Then a row for each of [held] that isn't already a grantable row, in the
/// key's order. Each is read-only, for the user can't change it here:
///
/// - a pinned scope whose permission may still be given is its own row,
///   ticked while [selection] keeps it, with "Limited to one record". A
///   scope is a slug and a record together, so it sits apart from the
///   slug's unpinned row, which may be ticked or not beside it. It stays in
///   [PickedScopes] as it was: no pin is made or changed here.
/// - a scope whose slug [grantable] doesn't have shows its code and "No
///   longer available", ticked, as the key still holds it. Once the picks
///   differ from what the key holds, it reads "No longer available; saving
///   removes it", unticked: an edit that sends scopes can't send it back,
///   so it is never put in [PickedScopes].
///
/// With nothing picked, a warning under the rows says the key will work
/// nowhere. It sits under them so that its coming moves no row. It is said
/// as it appears unless [announceNoneWarning] is cleared, as a form does
/// until the user has changed the picks: on a form nobody has touched, the
/// warning is how the form starts, not something that happened, and said
/// then it would be the first thing a screen reader hears of the page.
///
/// A refusal that names a permission ([refusedSlug]) shows [refusedMessage]
/// under each row of that slug, in the error style, read with the row.
///
/// ## Read-only, not disabled
///
/// While [readOnly], as while a save is on its way, and for the rows above
/// that can't be changed, a row stays drawn enabled, in the focus order and
/// read, while nothing ticks it (STYLE_GUIDE, "In-flight forms"). It reads
/// as `BgeSwitchField`'s read-only switch does: read-only and focusable,
/// with no tap to offer.
class ScopePicker extends StatelessWidget {
  const ScopePicker({
    required this.grantable,
    required this.selection,
    required this.onChanged,
    this.held = const [],
    this.offerEverything = true,
    this.readOnly = false,
    this.refusedSlug,
    this.refusedMessage,
    this.announceNoneWarning = true,
    super.key,
  });

  /// Keys the "Everything I can do" switch's row.
  static const Key everythingKey = ValueKey('scope_picker.everything');

  /// Keys the row of [scope]: a grantable permission's by its unpinned
  /// scope, a held scope's by itself.
  static Key rowKey(ApiKeyScope scope) =>
      ValueKey(('scope_picker.row', scope.slug, scope.resourceId));

  /// The permissions the user may give a key, in the server's order.
  final List<GrantablePermission> grantable;

  final ScopeSelection selection;
  final ValueChanged<ScopeSelection> onChanged;

  /// The scopes the key holds, when editing one, for its pinned and no
  /// longer available rows.
  final List<ApiKeyScope> held;

  /// Whether the "Everything I can do" switch is offered: only a new key
  /// can be given the preset.
  final bool offerEverything;

  /// Whether nothing changes the picks, as while a save is on its way.
  final bool readOnly;

  /// The slug of the permission a refusal named, if any.
  final String? refusedSlug;

  /// Why [refusedSlug] was refused, shown on its rows.
  final String? refusedMessage;

  /// Whether the nothing-picked warning is said as it appears. It is drawn,
  /// and read in its place, either way.
  final bool announceNoneWarning;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final selection = this.selection;
    final everything = selection is EverythingScopes;
    final picks = switch (selection) {
      PickedScopes(:final scopes) => scopes,
      EverythingScopes() => const <ApiKeyScope>[],
    };
    final bySlug = {
      for (final permission in grantable) permission.slug: permission,
    };
    // An unpinned held scope that may still be given is its grantable row.
    final heldRows = {
      for (final scope in held)
        if (scope.pinned || !bySlug.containsKey(scope.slug)) scope,
    };
    final keptPins = [
      for (final scope in heldRows)
        if (bySlug.containsKey(scope.slug)) scope,
    ];
    final changed =
        everything ||
        !setEquals(
          picks.toSet(),
          held.where((scope) => bySlug.containsKey(scope.slug)).toSet(),
        );

    void toggle(ApiKeyScope scope, {required bool on}) => onChanged(
      PickedScopes([
        for (final pick in picks)
          if (pick != scope) pick,
        if (on) scope,
      ]),
    );

    Widget? refusal(String slug) {
      final message = refusedMessage;
      if (slug != refusedSlug || message == null) return null;
      final theme = Theme.of(context);
      return Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (offerEverything)
          _PickerRow(
            key: everythingKey,
            readOnly: readOnly,
            builder: (context, row) => SwitchListTile(
              focusNode: row.focusNode,
              onFocusChange: row.onFocusChange,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.apiKeyScopeEverything),
              subtitle: everything
                  ? Text(l10n.apiKeyScopeEverythingIncludes(bySlug.length))
                  : null,
              value: everything,
              // Set while read-only too, so the tile stays enabled and
              // focusable; a change then does nothing.
              onChanged: readOnly
                  ? _ignoreWhileReadOnly
                  : (on) => onChanged(
                      on ? const EverythingScopes() : PickedScopes(keptPins),
                    ),
            ),
          ),
        for (final permission in bySlug.values)
          _ScopeCheckRow(
            key: rowKey(ApiKeyScope(slug: permission.slug)),
            title: permission.description,
            lines: [
              ...scopeLines(
                context,
                ApiKeyScope(slug: permission.slug),
                permission: permission,
              ),
              ?refusal(permission.slug),
            ],
            checked:
                everything ||
                picks.contains(ApiKeyScope(slug: permission.slug)),
            readOnly: readOnly || everything,
            onChanged: (on) =>
                toggle(ApiKeyScope(slug: permission.slug), on: on),
          ),
        for (final scope in heldRows)
          _ScopeCheckRow(
            key: rowKey(scope),
            title: bySlug[scope.slug]?.description ?? scope.slug,
            lines: [
              ...scopeLines(
                context,
                scope,
                permission: bySlug[scope.slug],
                unavailable: bySlug.containsKey(scope.slug)
                    ? null
                    : changed
                    ? l10n.apiKeyScopeNoLongerAvailableRemoved
                    : l10n.apiKeyScopeNoLongerAvailable,
              ),
              ?refusal(scope.slug),
            ],
            checked: bySlug.containsKey(scope.slug)
                ? everything || picks.contains(scope)
                : !changed,
            readOnly: true,
            onChanged: (_) {},
          ),
        if (selection case PickedScopes(scopes: [])) ...[
          const BgeGap.md(),
          BgeInlineBanner(
            message: l10n.apiKeyScopesNoneWarning,
            tone: BgeBannerTone.warning,
            announce: announceNoneWarning,
            // Furniture while nothing is picked, not news: it isn't brought
            // into view.
            reveal: false,
          ),
        ],
      ],
    );
  }
}

/// The change a read-only row takes, and does nothing with: a null one
/// would disable the row, taking it out of the focus order.
void _ignoreWhileReadOnly(Object? _) {}

/// A row with its checkbox, its [title] and its [lines] read as one.
class _ScopeCheckRow extends StatelessWidget {
  const _ScopeCheckRow({
    required this.title,
    required this.lines,
    required this.checked,
    required this.readOnly,
    required this.onChanged,
    super.key,
  });

  final String title;
  final List<Widget> lines;
  final bool checked;
  final bool readOnly;

  /// Asked with whether the row is to be ticked.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _PickerRow(
    readOnly: readOnly,
    builder: (context, row) => CheckboxListTile(
      focusNode: row.focusNode,
      onFocusChange: row.onFocusChange,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: lines.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: lines,
            ),
      value: checked,
      onChanged: readOnly
          ? _ignoreWhileReadOnly
          : (on) => onChanged(on ?? false),
    ),
  );
}

/// A ringed row that reads as one node, and that stays focusable while
/// [readOnly], as `BgeSwitchField` does: see [ReadOnlyFocusable].
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.readOnly,
    required this.builder,
    super.key,
  });

  final bool readOnly;
  final Widget Function(BuildContext context, BgeRowFocus row) builder;

  @override
  Widget build(BuildContext context) => ReadOnlyFocusable(
    readOnly: readOnly,
    debugLabel: 'ScopePicker row',
    builder: (context, focusNode) => BgeRowFocusRing(
      outsideSides: true,
      focusNode: focusNode,
      builder: builder,
    ),
  );
}
