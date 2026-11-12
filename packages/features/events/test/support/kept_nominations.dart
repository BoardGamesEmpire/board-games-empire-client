import 'package:models/domain.dart';

/// The nominations a fake server has answered a write or a single read with,
/// so its list reads serve them as a real server would (#517): the screen
/// reads the whole list after each of the viewer's own writes, and a fake
/// whose list ignored them would take each write back.
final class KeptNominations {
  final Map<String, EventNomination> _kept = {};

  /// Keeps [row] as the server's word on it, and answers it.
  EventNomination keep(EventNomination row) => _kept[row.id] = row;

  /// [read] as the server would serve it after the writes kept: each kept row
  /// in place of the one with its id, and those it lacks at the head, newest
  /// kept first.
  List<EventNomination> over(List<EventNomination> read) {
    final ids = {for (final row in read) row.id};
    return [
      for (final row in _kept.values.toList().reversed)
        if (!ids.contains(row.id)) row,
      for (final row in read) _kept[row.id] ?? row,
    ];
  }

  void clear() => _kept.clear();
}
