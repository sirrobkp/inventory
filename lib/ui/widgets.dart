import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import 'icons.dart';
import 'theme.dart';

class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 24, this.color, this.onTap, this.gradient});
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? K.glass) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: K.border),
      ),
      child: child,
    );
    return onTap == null ? box : GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: box);
  }
}

class LogoMark extends StatelessWidget {
  const LogoMark({super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: K.lime,
          borderRadius: BorderRadius.circular(15),
          boxShadow: const [BoxShadow(color: Color(0x2EC9FF55), blurRadius: 28)],
        ),
        child: const Icon(Ic.box, color: K.ink, size: 21),
      );
}

class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, this.onTap, this.dot = false, this.filled = false, this.size = 44});
  final IconData icon;
  final VoidCallback? onTap;
  final bool dot, filled;
  final double size;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: filled ? K.lime : const Color(0x0DFFFFFF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: filled ? K.lime : K.border),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Icon(icon, size: 20, color: filled ? K.ink : Colors.white),
            if (dot)
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: const Color(0xFFFF7A59), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF101A17), width: 2)),
                ),
              ),
          ]),
        ),
      );
}

class Header extends StatelessWidget {
  const Header({super.key, required this.title, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final alerts = s.lowStockCount + s.dash.pendingCount;
    final hour = DateTime.now().hour;
    final greet = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Row(children: [
        const LogoMark(),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((subtitle ?? greet).toUpperCase(), style: t(10, w: FontWeight.w800, c: K.muted, ls: 2)),
            const SizedBox(height: 2),
            Text(title, style: t(19, w: FontWeight.w800, ls: -0.7)),
          ]),
        ),
        for (final a in actions) ...[a, const SizedBox(width: 8)],
        IconBtn(Ic.bell, dot: alerts > 0, onTap: () => _alerts(context, s)),
      ]),
    );
  }

  void _alerts(BuildContext context, AppState s) {
    final lines = <String>[
      if (s.lowStockCount > 0) '${s.lowStockCount} product(s) at or below reorder level',
      if (s.dash.pendingCount > 0) '${s.dash.pendingCount} fiscal receipt(s) not yet confirmed by TRA',
      if (!s.registered) 'VFD is not registered - sales are NON-FISCAL until you register in TRA > Setup',
    ];
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Alerts', style: t(16, w: FontWeight.w800)),
        content: Text(lines.isEmpty ? 'Nothing needs attention.' : lines.map((e) => '- $e').join('\n'), style: t(12, w: FontWeight.w500, c: K.muted, h: 1.6)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('OK', style: t(12, c: K.lime)))],
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({super.key, required this.label, required this.value, required this.note, required this.icon, this.accent = false});
  final String label, value, note;
  final IconData icon;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    final fg = accent ? const Color(0xFF0C1612) : Colors.white;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent ? K.lime : K.glass,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent ? const Color(0x66C9FF55) : K.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: accent ? const Color(0x1A000000) : const Color(0x12FFFFFF), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 17, color: accent ? fg : K.lime),
        ),
        const SizedBox(height: 28),
        Text(label.toUpperCase(), style: t(10, w: FontWeight.w800, c: accent ? Colors.black54 : const Color(0xFF809089), ls: 1.7)),
        const SizedBox(height: 6),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: t(22, w: FontWeight.w800, c: fg, ls: -1))),
        const SizedBox(height: 4),
        Text(note, style: t(11, w: FontWeight.w600, c: accent ? Colors.black54 : const Color(0xFF6F8078))),
      ]),
    );
  }
}

const _grads = [
  [Color(0xFFFCD34D), Color(0xFFF97316)],
  [Color(0xFF67E8F9), Color(0xFF3B82F6)],
  [Color(0xFFC4B5FD), Color(0xFFD946EF)],
  [Color(0xFFFDE047), Color(0xFFF59E0B)],
  [Color(0xFFBAE6FD), Color(0xFF818CF8)],
  [Color(0xFF86EFAC), Color(0xFF14B8A6)],
];

class Avatar extends StatelessWidget {
  const Avatar(this.p, {super.key, this.size = 48});
  final Product p;
  final double size;
  @override
  Widget build(BuildContext context) {
    final i = p.name.codeUnits.fold<int>(0, (a, b) => a + b) % _grads.length;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: _grads[i], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Text(p.initials, style: t(10, w: FontWeight.w900, c: Colors.black54)),
    );
  }
}

class Chip2 extends StatelessWidget {
  const Chip2(this.text, {super.key, this.selected = false, this.onTap});
  final String text;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Colors.white : K.glass,
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: selected ? Colors.white : K.border),
          ),
          child: Text(text, style: t(11, c: selected ? const Color(0xFF101A17) : const Color(0xFF7E8D87))),
        ),
      );
}

class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.color = K.lime});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: color.withAlpha(28), borderRadius: BorderRadius.circular(30)),
        child: Text(text, style: t(10, w: FontWeight.w800, c: color)),
      );
}

class LimeButton extends StatelessWidget {
  const LimeButton(this.label, {super.key, this.icon, this.onTap, this.busy = false, this.outline = false});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool busy, outline;
  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final fg = outline ? K.lime : const Color(0xFF101A17);
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: outline ? const Color(0x12C9FF55) : K.lime,
            borderRadius: BorderRadius.circular(19),
            border: outline ? Border.all(color: const Color(0x4DC9FF55)) : null,
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (busy)
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
            else if (icon != null)
              Icon(icon, size: 17, color: fg),
            const SizedBox(width: 8),
            Text(label, style: t(13, w: FontWeight.w800, c: fg)),
          ]),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(title, style: t(14, w: FontWeight.w800)),
          if (action != null) GestureDetector(onTap: onAction, child: Text(action!, style: t(11, c: K.lime))),
        ]),
      );
}

class Empty extends StatelessWidget {
  const Empty(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(28), child: Center(child: Text(text, textAlign: TextAlign.center, style: t(12, w: FontWeight.w500, c: K.dim, h: 1.5))));
}

Future<T?> showSheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierColor: const Color(0xB3000000),
      backgroundColor: K.sheet,
      // surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 22, 20, 20), child: child)),
      ),
    );

void toast(BuildContext c, String msg) => ScaffoldMessenger.of(c)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg)));
