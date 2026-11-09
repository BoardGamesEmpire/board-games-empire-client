import 'package:models/domain.dart';
import 'package:test/test.dart';

typedef _G = ({String id, List<ExpansionLink> links, ContentType type});

_G _g(
  String id, {
  List<ExpansionLink> links = const [],
  ContentType type = ContentType.baseGame,
}) => (id: id, links: links, type: type);

ExpansionLink _link(String id, {bool standalone = false}) =>
    ExpansionLink(gameId: id, isStandalone: standalone);

List<PlacedGame<_G>> _place(List<_G> items, {bool complete = true}) =>
    placeExpansions<_G>(
      items,
      gameIdOf: (g) => g.id,
      baseGamesOf: (g) => g.links,
      contentTypeOf: (g) => g.type,
      complete: complete,
    );

void main() {
  group('placeExpansions', () {
    test('a game with no links is top level and unmarked', () {
      final g = _g('a');
      expect(_place([g]), [PlacedGame(g)]);
    });

    test('an expansion nests under its base game, after it, whatever their '
        'order', () {
      final base = _g('base');
      final exp = _g(
        'exp',
        links: [_link('base')],
        type: ContentType.expansion,
      );
      expect(_place([exp, base]), [
        PlacedGame(base, expansions: [exp]),
      ]);
    });

    test('an expansion nests under each base game shown', () {
      final a = _g('a');
      final b = _g('b');
      final exp = _g('exp', links: [_link('a'), _link('b')]);
      expect(_place([a, b, exp]), [
        PlacedGame(a, expansions: [exp]),
        PlacedGame(b, expansions: [exp]),
      ]);
    });

    test('a standalone link puts it at top level too', () {
      final base = _g('base');
      final exp = _g('exp', links: [_link('base', standalone: true)]);
      expect(_place([base, exp]), [
        PlacedGame(base, expansions: [exp]),
        PlacedGame(exp),
      ]);
    });

    test('a StandaloneExpansion content type counts as standalone without a '
        'standalone link', () {
      final base = _g('base');
      final exp = _g(
        'exp',
        links: [_link('base')],
        type: ContentType.standaloneExpansion,
      );
      expect(_place([base, exp]), [
        PlacedGame(base, expansions: [exp]),
        PlacedGame(exp),
      ]);
    });

    test('an expansion whose base games are all absent is held while the '
        'list is incomplete', () {
      final exp = _g(
        'exp',
        links: [_link('gone')],
        type: ContentType.expansion,
      );
      expect(_place([exp], complete: false), isEmpty);
    });

    test('the same expansion is released, marked, once the list is '
        'complete', () {
      final exp = _g(
        'exp',
        links: [_link('gone')],
        type: ContentType.expansion,
      );
      expect(_place([exp]), [PlacedGame(exp, missingBase: true)]);
    });

    test('a standalone expansion with no base shown is top level, unmarked, '
        'even while incomplete', () {
      final exp = _g('exp', links: [_link('gone', standalone: true)]);
      expect(_place([exp], complete: false), [PlacedGame(exp)]);
      final typed = _g(
        'typed',
        links: [_link('gone')],
        type: ContentType.standaloneExpansion,
      );
      expect(_place([typed], complete: false), [PlacedGame(typed)]);
    });

    test('an unlinked Expansion is top level and marked', () {
      final exp = _g('exp', type: ContentType.expansion);
      expect(_place([exp]), [PlacedGame(exp, missingBase: true)]);
    });

    test('an unlinked DLC is top level and marked', () {
      final dlc = _g('dlc', type: ContentType.dlc);
      expect(_place([dlc]), [PlacedGame(dlc, missingBase: true)]);
    });

    test('an unlinked Port is an ordinary game', () {
      final port = _g('port', type: ContentType.port);
      expect(_place([port]), [PlacedGame(port)]);
    });

    test('an expansion whose only shown base is itself nested stays top '
        'level, unmarked', () {
      final a = _g('a');
      final b = _g('b', links: [_link('a')], type: ContentType.expansion);
      final c = _g('c', links: [_link('b')], type: ContentType.expansion);
      expect(_place([a, b, c]), [
        PlacedGame(a, expansions: [b]),
        PlacedGame(c),
      ]);
    });

    group('a chain of expansions', () {
      // a ← b ← c ← d ← e: each an expansion of the one before.
      final a = _g('a');
      final b = _g('b', links: [_link('a')], type: ContentType.expansion);
      final c = _g('c', links: [_link('b')], type: ContentType.expansion);
      final d = _g('d', links: [_link('c')], type: ContentType.expansion);
      final e = _g('e', links: [_link('d')], type: ContentType.expansion);

      test('nests an expansion under a top-level base that is itself an '
          'expansion', () {
        expect(_place([a, b, c, d]), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [d]),
        ]);
      });

      test('alternates top level and nested along its length', () {
        expect(_place([a, b, c, d, e]), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [d]),
          PlacedGame(e),
        ]);
      });

      test('is placed the same whatever the order', () {
        expect(_place([e, d, c, b, a]), [
          PlacedGame(e),
          PlacedGame(c, expansions: [d]),
          PlacedGame(a, expansions: [b]),
        ]);
      });

      test('is placed the same while the list is incomplete, when every base '
          'is loaded', () {
        expect(_place([a, b, c, d], complete: false), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [d]),
        ]);
      });

      test('nests an expansion only under the bases shown at top level', () {
        final both = _g(
          'both',
          links: [_link('b'), _link('c')],
          type: ContentType.expansion,
        );
        expect(_place([a, b, c, both]), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [both]),
        ]);
      });

      test('nests an expansion under a top-level base that is itself an '
          'expansion while another of its bases is absent', () {
        final x = _g(
          'x',
          links: [_link('c'), _link('later')],
          type: ContentType.expansion,
        );
        final later = _g('later');
        expect(_place([a, b, c, x], complete: false), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [x]),
        ]);
        expect(_place([a, b, c, x, later], complete: false), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [x]),
          PlacedGame(later, expansions: [x]),
        ]);
      });

      test('nests an expansion under a top-level base that is itself an '
          'expansion while another of its shown bases is held', () {
        final held = _g(
          'held',
          links: [_link('later')],
          type: ContentType.expansion,
        );
        final x = _g(
          'x',
          links: [_link('c'), _link('held')],
          type: ContentType.expansion,
        );
        expect(_place([a, b, c, held, x], complete: false), [
          PlacedGame(a, expansions: [b]),
          PlacedGame(c, expansions: [x]),
        ]);
      });
    });

    test('a link to itself is ignored', () {
      final g = _g('a', links: [_link('a')], type: ContentType.expansion);
      expect(_place([g]), [PlacedGame(g, missingBase: true)]);
    });

    test('a base game listed twice nests the expansion once', () {
      final base = _g('base');
      final exp = _g(
        'exp',
        links: [_link('base'), _link('base', standalone: true)],
      );
      expect(_place([base, exp]), [
        PlacedGame(base, expansions: [exp]),
        PlacedGame(exp),
      ]);
    });

    test('an expansion whose shown base is held is held too while the list '
        'is incomplete', () {
      final x = _g('x', links: [_link('b')], type: ContentType.expansion);
      final y = _g('y', links: [_link('x')], type: ContentType.expansion);
      expect(_place([x, y], complete: false), isEmpty);
    });

    test('a held chain is released together once the list is complete', () {
      final x = _g('x', links: [_link('b')], type: ContentType.expansion);
      final y = _g('y', links: [_link('x')], type: ContentType.expansion);
      expect(_place([x, y]), [
        PlacedGame(x, expansions: [y], missingBase: true),
      ]);
    });

    test("a held chain waits for its root's base game", () {
      final b = _g('b');
      final x = _g('x', links: [_link('b')], type: ContentType.expansion);
      final y = _g('y', links: [_link('x')], type: ContentType.expansion);
      expect(_place([b, x, y], complete: false), [
        PlacedGame(b, expansions: [x]),
        PlacedGame(y),
      ]);
    });

    group('an expansion with a nested base shown and another base absent', () {
      // Y links X1, nested under A, and X2, on a later page (#711).
      final a = _g('A');
      final x1 = _g('X1', links: [_link('A')], type: ContentType.expansion);
      final y = _g(
        'Y',
        links: [_link('X1'), _link('X2')],
        type: ContentType.expansion,
      );
      final x2 = _g('X2');

      test('is held while the list is incomplete', () {
        expect(_place([a, x1, y], complete: false), [
          PlacedGame(a, expansions: [x1]),
        ]);
      });

      test('nests under the absent base once it arrives, never top level in '
          'between', () {
        final page2 = [
          PlacedGame(a, expansions: [x1]),
          PlacedGame(x2, expansions: [y]),
        ];
        expect(_place([a, x1, y, x2], complete: false), page2);
        expect(_place([a, x1, y, x2]), page2);
      });

      test('is top level, unmarked, when the list ends without the absent '
          'base', () {
        expect(_place([a, x1, y]), [
          PlacedGame(a, expansions: [x1]),
          PlacedGame(y),
        ]);
      });

      test('holds an expansion whose only shown base it is', () {
        final z = _g('Z', links: [_link('Y')], type: ContentType.expansion);
        expect(_place([a, x1, y, z], complete: false), [
          PlacedGame(a, expansions: [x1]),
        ]);
      });
    });

    test('an expansion nested under a shown base is not held for another '
        'absent base', () {
      final a = _g('a');
      final exp = _g(
        'exp',
        links: [_link('a'), _link('gone')],
        type: ContentType.expansion,
      );
      expect(_place([a, exp], complete: false), [
        PlacedGame(a, expansions: [exp]),
      ]);
    });

    test('a cycle of expansions is top level, unmarked', () {
      final a = _g('a', links: [_link('b')], type: ContentType.expansion);
      final b = _g('b', links: [_link('a')], type: ContentType.expansion);
      expect(_place([a, b], complete: false), [PlacedGame(a), PlacedGame(b)]);
    });

    test('an expansion hanging from a cycle is top level, unmarked, holding '
        'nothing', () {
      final a = _g('a', links: [_link('b')], type: ContentType.expansion);
      final b = _g('b', links: [_link('a')], type: ContentType.expansion);
      final c = _g('c', links: [_link('a')], type: ContentType.expansion);
      final d = _g('d', links: [_link('c')], type: ContentType.expansion);
      expect(_place([a, b, c, d]), [
        PlacedGame(a),
        PlacedGame(b),
        PlacedGame(c),
        PlacedGame(d),
      ]);
    });
  });
}
