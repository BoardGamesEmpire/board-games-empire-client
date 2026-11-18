import 'package:game_catalog/src/widgets/game_description.dart';
import 'package:markdown/markdown.dart' as md;

/// A DataGateway result's [markdown] summary as one line of plain text
/// (#558).
///
/// A search row has room for a line, not for formatting, so the summary is
/// parsed with the rules of the detail screen's description (#472: GitHub's
/// extensions, inline HTML not parsed) and only its words are kept. Blocks
/// (paragraphs, headings, list items, quoted blocks, table cells) are
/// separated by one space; inline formatting and a link's address are
/// dropped. Escapes and character references show the character they stand
/// for, and a tag typed in the text stays as text, which is why the document
/// is built with `encodeHtml: false`: the line is drawn by a plain `Text`,
/// where `&lt;` would show as written.
String summaryPlainText(String markdown) {
  final document = md.Document(
    extensionSet: GameDescription.extensions,
    encodeHtml: false,
  );
  final nodes = document.parseLines(markdown.split(RegExp(r'\r\n?|\n')));
  final out = StringBuffer();
  _collect(nodes, out);
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The elements whose text runs on within the line around them.
const Set<String> _inline = {
  'a',
  'em',
  'strong',
  'del',
  'code',
  'span',
  'sub',
  'sup',
  'u',
};

void _collect(List<md.Node> nodes, StringBuffer out) {
  for (final node in nodes) {
    if (node is md.Text) {
      out.write(node.text);
    } else if (node is md.Element) {
      switch (node.tag) {
        case 'br':
          out.write(' ');
        case 'img':
          out.write(node.attributes['alt'] ?? '');
        case 'input':
          break;
        case final tag when _inline.contains(tag):
          _collect(node.children ?? const [], out);
        default:
          out.write(' ');
          _collect(node.children ?? const [], out);
          out.write(' ');
      }
    }
  }
}
