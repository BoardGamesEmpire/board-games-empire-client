import 'package:data_gateway/src/widgets/data_gateway_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  testWidgets('announces the title and body as one live region, and not the '
      'icon', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        home: const Scaffold(
          body: Center(
            child: DataGatewayMessage(
              icon: Icons.lock_outline,
              title: "You can't manage data gateways",
              body: 'Ask an admin of this server.',
            ),
          ),
        ),
      ),
    );

    final title = tester.getSemantics(
      find.text("You can't manage data gateways"),
    );
    expect(
      title,
      isSemantics(
        isLiveRegion: true,
        label: "You can't manage data gateways\nAsk an admin of this server.",
      ),
    );
    expect(
      tester.getSemantics(find.text('Ask an admin of this server.')),
      same(title),
      reason: 'one announcement, not a title followed by a fragment',
    );
    handle.dispose();
  });
}
