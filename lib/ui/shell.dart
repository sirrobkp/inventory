import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import 'home_screen.dart';
import 'inventory_screen.dart';
import 'pos_screen.dart';
import 'icons.dart';
import 'theme.dart';
import 'tra_screen.dart';

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    const pages = [HomeScreen(), InventoryScreen(), PosScreen(), TraScreen()];
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [K.bg2, K.bg])),
        child: Stack(children: [
          SafeArea(
            bottom: false,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: KeyedSubtree(key: ValueKey(s.tab), child: pages[s.tab]),
            ),
          ),
          Positioned(left: 14, right: 14, bottom: 16 + MediaQuery.of(context).padding.bottom, child: _BottomNav(active: s.tab, onChange: s.setTab)),
        ]),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.active, required this.onChange});
  final int active;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (Ic.home, 'Home'),
      (Ic.box, 'Stock'),
      (Ic.store, 'Sell'),
      (Ic.fileCheck, 'TRA'),
    ];
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xE6192620),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 40, offset: Offset(0, 20))],
      ),
      child: Row(children: [
        for (var i = 0; i < tabs.length; i++)
          Expanded(
            flex: active == i ? 2 : 1,
            child: GestureDetector(
              onTap: () => onChange(i),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 56,
                decoration: BoxDecoration(color: active == i ? K.lime : Colors.transparent, borderRadius: BorderRadius.circular(19)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(tabs[i].$1, size: 19, color: active == i ? K.ink : const Color(0xFF75857D)),
                  if (active == i) ...[const SizedBox(width: 8), Text(tabs[i].$2, style: t(10, w: FontWeight.w800, c: K.ink))],
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
