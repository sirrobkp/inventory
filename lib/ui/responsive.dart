import 'package:flutter/material.dart';

import '../data/platform_info.dart';
import 'theme.dart';

/// Wide layout (sidebar, two panes, dialogs) for desktops and tablets. Phones keep the original layout.
bool isWide(BuildContext c) {
  final w = MediaQuery.of(c).size.width;
  return w >= 1000 || (isDesktop && w >= 820);
}

double bottomPad(BuildContext c) => isWide(c) ? 32 : 130; // phone: room for the floating nav bar
double hPad(BuildContext c) => isWide(c) ? 28 : 20;

/// Phone: one column (left then right). Wide: two columns side by side.
Widget twoPane(BuildContext c, {required List<Widget> left, required List<Widget> right, CrossAxisAlignment crossAxis = CrossAxisAlignment.start, int leftFlex = 6, int rightFlex = 5, double gap = 24}) {
  if (!isWide(c)) return Column(crossAxisAlignment: crossAxis, children: [...left, ...right]);
  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Expanded(flex: leftFlex, child: Column(crossAxisAlignment: crossAxis, children: left)),
    SizedBox(width: gap),
    Expanded(flex: rightFlex, child: Column(crossAxisAlignment: crossAxis, children: right)),
  ]);
}

/// Pushed full-screen pages (Settings, Reports, SDL) stay a readable width on wide screens.
Route<T> pageRoute<T>(Widget page) => MaterialPageRoute<T>(builder: (c) => WidePage(child: page));

class WidePage extends StatelessWidget {
  const WidePage({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).size.width < 900) return child;
    return ColoredBox(color: K.bg, child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: child)));
  }
}
