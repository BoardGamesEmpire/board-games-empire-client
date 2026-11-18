import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/widgets/summary_text.dart';

void main() {
  test('formatting is dropped', () {
    expect(summaryPlainText('**Big** _box_'), 'Big box');
  });

  test('blocks join with one space', () {
    expect(
      summaryPlainText('# Title\n\nFirst para.\n\n- one\n- two'),
      'Title First para. one two',
    );
  });

  test('blocks nested in a quote or a table join with one space', () {
    expect(summaryPlainText('> one\n>\n> two'), 'one two');
    expect(summaryPlainText('| a | b |\n|---|---|\n| c | d |'), 'a b c d');
  });

  test('inline HTML stays as text, never markup', () {
    expect(summaryPlainText('a <b>b</b>'), 'a <b>b</b>');
    expect(summaryPlainText('Tom & Jerry'), 'Tom & Jerry');
  });

  test('a link keeps its text', () {
    expect(summaryPlainText('[BGG](https://x.test)'), 'BGG');
  });

  test('a backslash escape shows the character', () {
    expect(summaryPlainText(r'5 \* 3'), '5 * 3');
  });

  test('a character reference shows the character', () {
    expect(summaryPlainText('Tom &amp; Jerry'), 'Tom & Jerry');
  });

  test('runs of whitespace collapse and ends are trimmed', () {
    expect(summaryPlainText('  a \t  b\n\n\n   c  \n'), 'a b c');
  });
}
