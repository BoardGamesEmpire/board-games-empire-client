/// How long the server counts [text] to be.
///
/// The server's validator counts UTF-16 code units, less each surrogate
/// pair and each presentation sequence (a code unit followed by U+FE0E or
/// U+FE0F), so one emoji is 1 there and 2 in a Dart [String.length]. Measure a
/// value with this before sending it, so the server never refuses it for
/// its length.
int serverStringLength(String text) {
  var length = text.length;
  for (var i = 0; i < text.length - 1; i++) {
    final unit = text.codeUnitAt(i);
    final next = text.codeUnitAt(i + 1);
    final isSurrogatePair =
        unit >= 0xD800 && unit <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF;
    final isPresentation =
        unit != 0xFE0E && unit != 0xFE0F && (next == 0xFE0E || next == 0xFE0F);
    if (isSurrogatePair || isPresentation) {
      length--;
    }
  }
  return length;
}
