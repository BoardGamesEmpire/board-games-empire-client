import 'package:events/src/create/event_create_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// Pins the create form's basics (#499) as [buildEventCreateForm] checks
/// them, and the draft [draftOf] reads from the whole form.
void main() {
  FormControl<String> textOf(FormGroup form, String name) =>
      form.control(name) as FormControl<String>;
  FormArray<Map<String, Object?>> datesOf(FormGroup form) =>
      form.control(EventCreateControls.dates)
          as FormArray<Map<String, Object?>>;
  FormControl<DateTime> startOf(FormGroup form, int index) =>
      (datesOf(form).controls[index] as FormGroup).control(
        EventCreateControls.start,
      ) as FormControl<DateTime>;

  // Local, as the pickers give it.
  final start = DateTime(2026, 11, 14, 19, 30);

  /// A form whose other sections are filled in, so that its basics alone
  /// decide whether it is valid.
  FormGroup dated() {
    final form = buildEventCreateForm();
    startOf(form, 0).value = start;
    return form;
  }

  group('the title', () {
    test('is required once trimmed', () {
      final form = dated();
      final title = textOf(form, EventCreateControls.title);

      for (final blank in [null, '', '   ', '\n\t']) {
        title.value = blank;
        expect(
          title.hasError(ValidationMessage.required),
          isTrue,
          reason: '"$blank"',
        );
        expect(form.valid, isFalse, reason: '"$blank"');
      }

      title.value = '  Game night  ';
      expect(title.errors, isEmpty);
      expect(form.valid, isTrue);
    });
  });

  group('the link', () {
    bool taken(String? link) {
      final form = dated();
      textOf(form, EventCreateControls.title).value = 'Game night';
      final url = textOf(form, EventCreateControls.url)..value = link;
      final refused = url.hasError(EventCreateErrors.fullLink);
      expect(form.valid, !refused, reason: '"$link"');
      return !refused;
    }

    test('may be left empty', () {
      for (final empty in [null, '', '   ']) {
        expect(taken(empty), isTrue, reason: '"$empty"');
      }
    });

    test('takes a full http or https link', () {
      for (final link in [
        'https://example.com/night',
        'http://example.com',
        '  https://example.com/night  ',
        'HTTPS://Example.COM/Night?table=2#rules',
        'https://games.example.co.uk:8080/night',
        'https://a-b.example.com',
        'http://192.168.1.10/games',
        'https://user:secret@example.com',
        // The server takes a name outside ASCII as typed, and its
        // international forms.
        'https://bücher.de',
        'https://example.рф',
        'https://xn--bcher-kva.de',
        'https://example.xn--p1ai',
        // At the server's limit.
        'https://example.com/${'a' * (2084 - 'https://example.com/'.length)}',
      ]) {
        expect(taken(link), isTrue, reason: link);
      }
    });

    test('refuses what the server refuses', () {
      for (final link in [
        // No top-level domain.
        'https://localhost',
        'https://games',
        // An underscore, or a top-level domain that isn't letters.
        'https://my_site.com',
        'https://example.c0m',
        'http://999.1.1.1',
        // Whitespace, or angle brackets, anywhere.
        'https://exa mple.com',
        'https://example.com/game night',
        'https://example.com/<b>',
        // A label empty, with a hyphen at either end, too long, or holding
        // what a name can't.
        'https://example..com',
        'https://example.com.',
        'https://-games.com',
        'https://games-.com',
        'https://${'a' * 64}.com',
        'https://ex!ample.com',
        'https://x%41.org',
        'https://b%C3%BCcher.de',
        'https://ＥＸ.com',
        r'https://example.com\night',
        // Credentials with no one named, or with too many colons.
        'https://@example.com',
        'https://:@example.com',
        'https://a:b:c@example.com',
        // A port out of range.
        'https://example.com:0',
        'https://example.com:65536',
        // No host.
        'https:///night',
        // A backslash for either slash after the scheme, which Dart's
        // parser reads as one.
        r'https:\\example.com',
        r'https:/\example.com',
        r'https:\/example.com',
        r'HTTPS:\\Example.com/night',
        // Past the server's limit.
        'https://example.com/${'a' * (2085 - 'https://example.com/'.length)}',
      ]) {
        expect(taken(link), isFalse, reason: link);
      }
    });

    test('refuses a link the app cannot open', () {
      // The server takes these, but the app opens only full http and https
      // links.
      for (final link in [
        'example.com',
        'www.example.com/night',
        'ftp://x.org',
        'https:example.com',
      ]) {
        expect(taken(link), isFalse, reason: link);
      }
    });
  });

  group('draftOf', () {
    test('sends what the form holds, trimmed, an empty one as none', () {
      final form = dated();
      textOf(form, EventCreateControls.title).value = '  Game night ';
      textOf(form, EventCreateControls.household).value = 'h_1';
      form.control(EventCreateControls.type).value = EventType.strategyNight;
      form.control(EventCreateControls.reach).value = Reach.public;
      textOf(form, EventCreateControls.description).value = ' Bring snacks ';
      textOf(form, EventCreateControls.location).value = '   ';
      textOf(form, EventCreateControls.url).value =
          ' https://example.com/night ';
      form.control(EventCreateControls.invitees).value = const [
        UserSummary(id: 'u_2', username: 'bo'),
        UserSummary(id: 'u_1', username: 'ana'),
      ];
      expect(form.valid, isTrue);

      expect(
        draftOf(form),
        EventDraft(
          title: 'Game night',
          householdId: 'h_1',
          description: 'Bring snacks',
          url: 'https://example.com/night',
          type: EventType.strategyNight,
          reach: Reach.public,
          occurrences: [EventOccurrenceDraft(startDate: start.toUtc())],
          inviteUserIds: const ['u_2', 'u_1'],
        ),
      );
    });

    test('an untouched form leaves the server its defaults', () {
      final form = dated();
      textOf(form, EventCreateControls.title).value = 'Game night';

      final draft = draftOf(form);

      expect(draft.householdId, isNull);
      expect(draft.type, isNull);
      expect(draft.reach, isNull);
      expect(draft.policy, isNull);
      expect(draft.inviteUserIds, isEmpty);
      expect(draft.schedulingMode, EventSchedulingMode.fixed);
      expect(() => draft.checkSendable(), returnsNormally);
    });
  });
}
