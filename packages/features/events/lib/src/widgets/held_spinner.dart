import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A held button's icon while its write is out, Take back's, Offer games',
/// Nominate's or a nomination row's: scaled with the label beside it, in the
/// button's icon colour, as the screen's other held buttons'.
class HeldSpinner extends StatelessWidget {
  const HeldSpinner({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: BgeTextScale.clampedOf(
      context,
    ).scale(BgeTokens.of(context).spaceMd),
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: IconTheme.of(context).color,
    ),
  );
}
