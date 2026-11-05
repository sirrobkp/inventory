import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = s.dash;
    final low = s.products.where((p) => p.low).take(3).toList();
    final name = (s.cfg['biz_name'] ?? '').isNotEmpty ? s.cfg['biz_name']! : 'Kibo Trade';
    return ListView(padding: const EdgeInsets.only(bottom: 130), children: [
      Header(title: name),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(children: [
          Glass(
            radius: 30,
            padding: const EdgeInsets.all(20),
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1B2E27), Color(0xFF13201C), Color(0xFF17271D)]),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 8, height: 8, decoration: const BoxDecoration(color: K.lime, shape: BoxShape.circle, boxShadow: [BoxShadow(color: K.lime, blurRadius: 10)])),
                      const SizedBox(width: 8),
                      Text("TODAY'S REVENUE", style: t(10, w: FontWeight.w800, c: const Color(0xFF91A099), ls: 1.8)),
                    ]),
                    const SizedBox(height: 12),
                    Text(money(d.todayRevenue), style: t(29, w: FontWeight.w800, ls: -1.6)),
                    const SizedBox(height: 4),
                    Text('${d.todayCount} completed transactions', style: t(12, w: FontWeight.w600, c: const Color(0xFF8C9C95))),
                  ]),
                ),
                IconBtn(Ic.plus, filled: true, size: 48, onTap: () => s.setTab(2)),
              ]),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: _Quick(Ic.scan, 'New sale', () => s.setTab(2))),
                const SizedBox(width: 8),
                Expanded(child: _Quick(Ic.packageSearch, 'Check stock', () => s.setTab(1))),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: MetricCard(label: 'Gross profit', value: '${d.grossMargin.toStringAsFixed(1)}%', note: 'this month', icon: Ic.barChart, accent: true)),
            const SizedBox(width: 12),
            Expanded(child: MetricCard(label: 'Stock value', value: compact(d.stockValue), note: '${d.productCount} active items', icon: Ic.bag)),
          ]),
          const SizedBox(height: 16),
          _SalesChart(week: d.week),
          const SizedBox(height: 12),
          SectionTitle('Needs attention', action: 'View all', onAction: () => s.setTab(1)),
          Glass(
            padding: EdgeInsets.zero,
            child: low.isEmpty
                ? const Empty('Stock levels look healthy.')
                : Column(children: [
                    for (var i = 0; i < low.length; i++)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(border: i < low.length - 1 ? const Border(bottom: BorderSide(color: Color(0x0FFFFFFF))) : null),
                        child: Row(children: [
                          Avatar(low[i], size: 44),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(low[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12)),
                              const SizedBox(height: 4),
                              Text(low[i].sku, style: mono(9, c: K.dim)),
                            ]),
                          ),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('${low[i].stock.toStringAsFixed(low[i].stock % 1 == 0 ? 0 : 1)} left', style: t(12, w: FontWeight.w800, c: low[i].stock <= 5 ? const Color(0xFFFF8066) : K.amber)),
                            const SizedBox(height: 4),
                            Text('Reorder soon', style: t(9, w: FontWeight.w500, c: K.dim)),
                          ]),
                        ]),
                      ),
                  ]),
          ),
        ]),
      ),
    ]);
  }
}

class _Quick extends StatelessWidget {
  const _Quick(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(color: K.glass2, borderRadius: BorderRadius.circular(16)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 17, color: K.lime), const SizedBox(width: 8), Text(label, style: t(12))]),
        ),
      );
}

class _SalesChart extends StatelessWidget {
  const _SalesChart({required this.week});
  final List<double> week;
  @override
  Widget build(BuildContext context) {
    final maxV = week.fold<double>(0, (a, b) => b > a ? b : a);
    final total = week.fold<double>(0, (a, b) => a + b);
    final now = DateTime.now();
    final days = [for (var i = 6; i >= 0; i--) DateFormat('E').format(now.subtract(Duration(days: i))).substring(0, 1)];
    return Glass(
      radius: 26,
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SALES PULSE - 7 DAYS', style: t(10, w: FontWeight.w800, c: const Color(0xFF82918B), ls: 1.8)),
            const SizedBox(height: 6),
            Text(money(total), style: t(20, w: FontWeight.w800, ls: -0.8)),
          ]),
        ]),
        const SizedBox(height: 20),
        SizedBox(
          height: 96,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < week.length; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: maxV == 0 ? .04 : (week[i] / maxV).clamp(.04, 1.0)),
                    duration: Duration(milliseconds: 450 + i * 50),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, __) => Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(heightFactor: v, child: Container(decoration: BoxDecoration(color: i == 6 ? K.lime : const Color(0x17FFFFFF), borderRadius: const BorderRadius.vertical(top: Radius.circular(6))))),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Row(children: [for (final d in days) Expanded(child: Center(child: Text(d.toUpperCase(), style: t(9, w: FontWeight.w600, c: const Color(0xFF61716A)))))]),
      ]),
    );
  }
}
