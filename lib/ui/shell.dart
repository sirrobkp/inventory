import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import 'home_screen.dart';
import 'icons.dart';
import 'inventory_screen.dart';
import 'license_ui.dart';
import 'pos_screen.dart';
import 'responsive.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'tra_screen.dart';
import 'widgets.dart';

const _tabs = [
  (Ic.home, 'Home'),
  (Ic.box, 'Stock'),
  (Ic.store, 'Sell'),
  (Ic.fileCheck, 'TRA'),
];

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    if (s.license.locked) return const LicenseGate(); // expired / switched off / unverifiable subscription
    const pages = [HomeScreen(), InventoryScreen(), PosScreen(), TraScreen()];
    final wide = isWide(context);
    final page = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: KeyedSubtree(key: ValueKey(s.tab), child: pages[s.tab]),
    );
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [K.bg2, K.bg])),
        child: wide
            ? Row(children: [
                const _Sidebar(),
                Expanded(child: SafeArea(child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1500), child: page)))),
              ])
            : Stack(children: [
                SafeArea(bottom: false, child: page),
                Positioned(left: 14, right: 14, bottom: 16 + MediaQuery.of(context).padding.bottom, child: _BottomNav(active: s.tab, onChange: s.setTab)),
              ]),
      ),
    );
  }
}

// ----------------------------------------------------------------------- desktop sidebar
class _Sidebar extends StatelessWidget {
  const _Sidebar();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final pending = s.dash.pendingCount;
    return Container(
      width: 236,
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 18),
      decoration: const BoxDecoration(color: Color(0x73081210), border: Border(right: BorderSide(color: K.border))),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              const LogoMark(),
              const SizedBox(width: 12),
              Expanded(child: Text((s.cfg['biz_name'] ?? '').isNotEmpty ? s.cfg['biz_name']! : 'Kibo Trade', maxLines: 2, overflow: TextOverflow.ellipsis, style: t(15, w: FontWeight.w800, ls: -0.4))),
            ]),
          ),
          const SizedBox(height: 30),
          for (var i = 0; i < _tabs.length; i++) _SideItem(icon: _tabs[i].$1, label: _tabs[i].$2, selected: s.tab == i, badge: i == 3 && pending > 0 ? '$pending' : null, onTap: () => s.setTab(i)),
          const Spacer(),
          Glass(
            radius: 18,
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: s.online ? K.lime : K.amber, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(s.online ? 'Online' : 'Offline', style: t(11, c: Colors.white)),
              ]),
              const SizedBox(height: 6),
              Text(!s.registered ? 'Fiscal device not set up' : (pending == 0 ? 'All receipts synced' : '$pending receipt${pending == 1 ? '' : 's'} waiting for TRA'), style: t(10, w: FontWeight.w500, c: K.muted, h: 1.4)),
              if (s.registered) ...[
                const SizedBox(height: 10),
                MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: s.syncing ? null : () => s.syncNow(), child: Text(s.syncing ? 'Syncing...' : 'Sync now', style: t(11, c: K.lime)))),
              ],
            ]),
          ),
          const SizedBox(height: 10),
          _SideItem(icon: Ic.settings, label: 'Settings', selected: false, onTap: () => Navigator.push(context, pageRoute(const SettingsScreen()))),
        ]),
      ),
    );
  }
}

class _SideItem extends StatefulWidget {
  const _SideItem({required this.icon, required this.label, required this.selected, required this.onTap, this.badge});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  @override
  State<_SideItem> createState() => _SideItemState();
}

class _SideItemState extends State<_SideItem> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(color: sel ? K.lime : (hover ? K.glass2 : Colors.transparent), borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            Icon(widget.icon, size: 19, color: sel ? K.ink : const Color(0xFF9AA9A2)),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.label, style: t(13, w: FontWeight.w700, c: sel ? K.ink : const Color(0xFFC3CEC8)))),
            if (widget.badge != null) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: K.amber, borderRadius: BorderRadius.circular(20)), child: Text(widget.badge!, style: t(10, w: FontWeight.w800, c: K.ink))),
          ]),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------- phone bottom nav (unchanged)
class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.active, required this.onChange});
  final int active;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xE6192620),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 40, offset: Offset(0, 20))],
      ),
      child: Row(children: [
        for (var i = 0; i < _tabs.length; i++)
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
                  Icon(_tabs[i].$1, size: 19, color: active == i ? K.ink : const Color(0xFF75857D)),
                  if (active == i) ...[const SizedBox(width: 8), Text(_tabs[i].$2, style: t(10, w: FontWeight.w800, c: K.ink))],
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
