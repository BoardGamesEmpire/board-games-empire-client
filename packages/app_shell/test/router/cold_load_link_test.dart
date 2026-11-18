import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// `coldLoadLinkFor` (#83): which web cold-load locations are held through
/// bootstrap and sign-in, and how they are carried.
void main() {
  group('coldLoadLinkFor', () {
    test('holds a declared location under the web sentinel', () {
      final link = coldLoadLinkFor(Uri.parse('/household/h1'));

      expect(link, isNotNull);
      expect(link!.location, '/household/h1');
      expect(link.serverId, webColdLoadServerId);
    });

    test('keeps the query', () {
      final link = coldLoadLinkFor(
        Uri.parse('/server/s1/event/e1/rsvp/tok?c=1'),
      );

      expect(link!.location, '/server/s1/event/e1/rsvp/tok?c=1');
    });

    for (final location in [
      AppRoutes.splash,
      AppRoutes.home,
      AppRoutes.auth,
      AppRoutes.serverAdd,
      AppRoutes.error,
    ]) {
      test('holds nothing for $location', () {
        expect(coldLoadLinkFor(Uri.parse(location)), isNull);
      });
    }

    test('holds nothing for home with a query', () {
      expect(coldLoadLinkFor(Uri.parse('/home?tab=1')), isNull);
    });

    test('logs a held token link redacted', () {
      final link = coldLoadLinkFor(
        Uri.parse('/server/s1/event/e1/rsvp/tok?c=1'),
      )!;

      expect(link.toString(), isNot(contains('tok')));
      expect(link.toString(), isNot(contains('c=1')));
    });
  });
}
