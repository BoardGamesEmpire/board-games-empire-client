import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/servers/server_list_state.dart';
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One registered server in the manager (#134): its name, its state with
/// the state's icon, and a check when it is the one in use.
///
/// ## While a switch runs, every row keeps its place
///
/// A pick makes every row ignore a tap until its switch ends: the row
/// picked, through its own press, and its siblings with it, so the group
/// reads the same whichever row a user is on, as the auth screen's provider
/// buttons do (#583). Each stays enabled and focusable, through
/// [BgeInertButton], rather than going `enabled: false`, which would drop
/// a keyboard or screen-reader user's place mid-switch. To a screen reader
/// it reads as not available, with no tap action, under the same name, and
/// the row being switched to adds that it is switching. A tap or a hover on
/// it draws nothing; the focus highlight stays.
///
/// Outside a switch every row is an ordinary enabled row, the one in use
/// included: it is the selected item of the list, not an unavailable one.
/// A tap on it is a pick the cubit ignores.
///
/// The row is one node, named by its name and its state, and selected when
/// it is the server in use, so the check and the highlight are not the only
/// signs.
class ServerTile extends StatelessWidget {
  const ServerTile({
    required this.row,
    required this.switchingTo,
    required this.onTap,
    super.key,
  });

  final ServerListRow row;

  /// The id of the server a pick is making active now, or null while none
  /// is. With one, every row ignores a tap, and this row says it is
  /// switching when the id is its own.
  final String? switchingTo;

  /// Picks this server.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final inUse = row.state == ServerRowState.inUse;
    final ignoresTap = switchingTo != null;
    final switching = switchingTo == row.server.id;
    final name = row.server.displayName;
    final stateText = switch (row.state) {
      ServerRowState.inUse => l10n.shellServerStateInUse,
      ServerRowState.dormant => l10n.shellServerStateDormant,
      ServerRowState.notConnected => l10n.shellServerStateNotConnected,
    };

    return BgeInertButton(
      inert: ignoresTap,
      label: [
        name,
        stateText,
        if (switching) l10n.shellServerSwitching,
      ].join('\n'),
      selected: inUse,
      onPressed: onTap,
      builder: (context, focusNode, onPressed) {
        final quiet = Theme.of(context).hoverColor.withValues(alpha: 0);
        return BgeRowFocusRing(
          focusNode: focusNode,
          builder: (context, ring) => ListTile(
            focusNode: ring.focusNode,
            onFocusChange: ring.onFocusChange,
            focusColor: ring.focusColor,
            onTap: ring.onTap(onPressed),
            selected: inUse,
            mouseCursor: ignoresTap ? SystemMouseCursors.basic : null,
            enableFeedback: !ignoresTap,
            splashColor: ignoresTap ? quiet : null,
            hoverColor: ignoresTap ? quiet : null,
            title: Text(name),
            subtitle: _StateLine(state: row.state, text: stateText),
            trailing: inUse
                ? const Icon(Icons.check)
                : switching
                ? const _Spinner()
                : null,
          ),
        );
      },
    );
  }
}

/// A row's state: its words after the state's status icon, which says the
/// same thing without colour.
class _StateLine extends StatelessWidget {
  const _StateLine({required this.state, required this.text});

  final ServerRowState state;
  final String text;

  /// Connected, in use or not, or not connected: the connection is what the
  /// icon shows, and the words say which of the connected two.
  BgeStatus get _status => switch (state) {
    ServerRowState.inUse || ServerRowState.dormant => BgeStatus.synced,
    ServerRowState.notConnected => BgeStatus.offline,
  };

  @override
  Widget build(BuildContext context) {
    final fontSize = DefaultTextStyle.of(context).style.fontSize ?? 0;
    return Row(
      children: [
        Icon(
          BgeStatusColors.iconFor(_status),
          // Sized as its words are, and scaled with them.
          size: MediaQuery.textScalerOf(context).scale(fontSize),
          color: BgeStatusColors.of(context).colorFor(_status),
        ),
        const BgeGap.sm(axis: Axis.horizontal),
        // Flexible, so the words wrap within the row at large text.
        Flexible(child: Text(text)),
      ],
    );
  }
}

/// The trailing spinner while the row's server is being switched to, the
/// size of the check it stands in for.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    return SizedBox.square(
      dimension: icon.size,
      child: CircularProgressIndicator(strokeWidth: 2, color: icon.color),
    );
  }
}
