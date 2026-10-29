import 'package:flutter/material.dart';

/// A chip's label that shrinks to fit its chip rather than being cut, as at
/// a large text size on a narrow screen (#474).
///
/// A Material chip holds its label to one line, and it can't grow taller to
/// wrap one: the icon beside a label is as wide as the chip is tall, so a
/// taller chip leaves its label less room. So a label too wide for its row
/// is scaled down just enough to fit, and every other label keeps its size.
class CatalogChipLabel extends StatelessWidget {
  const CatalogChipLabel(this.text, {this.semanticsLabel, super.key});

  final String text;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: AlignmentDirectional.centerStart,
    child: Text(text, semanticsLabel: semanticsLabel),
  );
}
