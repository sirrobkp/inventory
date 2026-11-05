import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../data/repo.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

class TraScreen extends StatefulWidget {
  const TraScreen({super.key});
  @override
  State<TraScreen> createState() => _TraScreenState();
}

class _TraScreenState extends State<TraScreen> {
  bool _z = false;

  Future<void> _closeDay(AppState s) async {
    if (!s.registered) return toast(context, 'Register the VFD first');
    if (s.dash.pendingCount > 0) return toast(context, 'Upload pending receipts first (tap Sync)');
    final today = dayFmt.format(DateTime.now());
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Submit Z-report?', style: t(16, w: FontWeight.w800)),
        content: Text('This sends the totals for $today to TRA. Receipts issued after this will need a new Z-report.', style: t(12, w: FontWeight.w500, c: K.muted, h: 1.5)),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Cancel', style: t(12, c: K.muted))), TextButton(onPressed: () => Navigator.pop(c, true), child: Text('Submit', style: t(12, c: K.lime)))],
      ),
    );
    if (ok != true) return;
    setState(() => _z = true);
    final r = await s.tra.submitZReport(today);
    setState(() => _z = false);
    if (mounted) toast(context, r.ok ? 'Z-report accepted by TRA' : 'Z-report: ${r.code} ${r.msg}');
    await s.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final d = s.dash;
    final now = DateTime.now();
    final from = dayFmt.format(DateTime(now.year, now.month, 1));
    final to = dayFmt.format(now);
    final fiscal = s.recent.where((e) => e.fiscal).take(6).toList();
    final failed = s.recent.where((e) => e.uploadStatus == 'failed').toList();
    final nextDue = DateFormat('d MMM').format(DateTime(now.year, now.month + 1, 20));

    return ListView(padding: const EdgeInsets.only(bottom: 130), children: [
      Header(title: 'TRA Connect', subtitle: 'Tax & fiscal center', actions: [IconBtn(Ic.settings, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())))]),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // VFD card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: s.registered ? K.lime : K.card, borderRadius: BorderRadius.circular(30), border: s.registered ? null : Border.all(color: K.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Container(width: 44, height: 44, decoration: BoxDecoration(color: s.registered ? const Color(0x1A000000) : K.glass2, borderRadius: BorderRadius.circular(16)), child: Icon(Ic.fileCheck, color: s.registered ? K.ink : K.lime)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: s.registered ? const Color(0x1A000000) : const Color(0x26FFC85A), borderRadius: BorderRadius.circular(30)),
                  child: Row(children: [Icon(s.registered ? Ic.checkCircle : Ic.warn, size: 12, color: s.registered ? K.ink : K.amber), const SizedBox(width: 6), Text(s.registered ? 'Registered' : 'Not registered', style: t(10, w: FontWeight.w800, c: s.registered ? K.ink : K.amber))]),
                ),
              ]),
              const SizedBox(height: 28),
              Text('VIRTUAL FISCAL DEVICE', style: t(10, w: FontWeight.w800, c: s.registered ? Colors.black54 : K.muted, ls: 1.8)),
              const SizedBox(height: 4),
              Text(s.registered ? (s.online ? 'Connected & fiscalising' : 'Registered - offline') : 'Setup required', style: t(21, w: FontWeight.w800, ls: -0.8, c: s.registered ? K.ink : Colors.white)),
              if (!s.registered) ...[
                const SizedBox(height: 8),
                Text('Import your TRA certificate and register in Settings. Until then sales are non-fiscal.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
                const SizedBox(height: 14),
                LimeButton('Open setup', icon: Ic.settings, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
              ] else ...[
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.only(top: 14),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x1A000000)))),
                  child: Row(children: [
                    _Kv('TIN', s.cfg['tin'] ?? '-'),
                    _Kv('VRN', s.cfg['vrn'] ?? '-'),
                    _Kv('SERIAL', s.cfg['serial'] ?? '-'),
                  ]),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          FutureBuilder<Statement>(
            future: s.repo.statement(from, to),
            builder: (_, snap) {
              final st = snap.data;
              return Row(children: [
                Expanded(child: MetricCard(label: 'Fiscal sales', value: compact(st?.revenueGross ?? d.monthGross), note: DateFormat('MMMM yyyy').format(now), icon: Ic.receipt)),
                const SizedBox(width: 12),
                Expanded(child: MetricCard(label: 'VAT payable', value: compact(st?.vatPayable ?? d.monthOutputVat), note: 'Due $nextDue', icon: Ic.clipboardCheck)),
              ]);
            },
          ),
          const SizedBox(height: 14),
          // queue
          Glass(
            radius: 26,
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Fiscal queue', style: t(14, w: FontWeight.w800)), const SizedBox(height: 4), Text('Uploads run automatically after every sale', style: t(10, w: FontWeight.w500, c: const Color(0xFF74837C)))]),
                Container(width: 40, height: 40, decoration: BoxDecoration(color: s.online ? const Color(0x1AC9FF55) : const Color(0x1AFFC85A), borderRadius: BorderRadius.circular(16)), child: Icon(s.online ? Ic.wifi : Ic.wifiOff, size: 17, color: s.online ? K.lime : K.amber)),
              ]),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: const Color(0x33000000), borderRadius: BorderRadius.circular(18)),
                child: Row(children: [
                  Container(width: 36, height: 36, decoration: BoxDecoration(color: K.glass2, borderRadius: BorderRadius.circular(12)), child: const Icon(Ic.receipt, size: 16)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(d.pendingCount == 0 ? 'All receipts synced' : '${d.pendingCount} receipt${d.pendingCount == 1 ? '' : 's'} pending', style: t(12)), const SizedBox(height: 2), Text('${money(d.pendingTotal).toUpperCase()} TOTAL', style: mono(9, c: const Color(0xFF66776F)))])),
                ]),
              ),
              if (s.lastSyncMsg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.lastSyncMsg!, style: t(10, w: FontWeight.w500, c: K.muted))),
              const SizedBox(height: 14),
              LimeButton(s.syncing ? 'Syncing with TRA...' : d.pendingCount == 0 ? 'Sync fiscal records' : 'Sync now', icon: Ic.zap, outline: true, busy: s.syncing, onTap: s.registered ? () => s.syncNow() : null),
              if (failed.isNotEmpty) ...[
                const SizedBox(height: 10),
                LimeButton('Retry ${failed.length} rejected', icon: Ic.refresh, outline: true, onTap: () async {
                  await s.retryFailed();
                }),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          Glass(
            radius: 26,
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Daily Z-report', style: t(14, w: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Past days are submitted automatically once all receipts are uploaded. Close today early if you finish trading.', style: t(10, w: FontWeight.w500, c: const Color(0xFF74837C), h: 1.5)),
              const SizedBox(height: 14),
              LimeButton("Close today's day (Z-report)", icon: Ic.calendarCheck, outline: true, busy: _z, onTap: () => _closeDay(s)),
            ]),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsScreen())),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: K.card, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0x40C9FF55))),
              child: Row(children: [
                const Icon(Ic.fileText, color: K.lime),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Financial statements', style: t(13)), const SizedBox(height: 3), Text('Income statement, VAT return schedules, Z-reports', style: t(10, w: FontWeight.w500, c: K.muted))])),
                const Icon(Ic.chevron, color: K.dim),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          SectionTitle('Recent fiscal receipts'),
          Glass(
            radius: 24,
            padding: EdgeInsets.zero,
            child: fiscal.isEmpty
                ? const Empty('No fiscal receipts yet.')
                : Column(children: [
                    for (var i = 0; i < fiscal.length; i++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async => showSheet(context, _ReceiptDetail(await s.repo.getSale(fiscal[i].id!))),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(border: i < fiscal.length - 1 ? const Border(bottom: BorderSide(color: Color(0x0FFFFFFF))) : null),
                          child: Row(children: [
                            Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0x1AC9FF55), borderRadius: BorderRadius.circular(14)), child: const Icon(Ic.receipt, size: 16, color: K.lime)),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('#${fiscal[i].number}', style: mono(10, w: FontWeight.w700)), const SizedBox(height: 4), Text('${DateFormat('d MMM h:mm a').format(fiscal[i].createdAt)} - ${_label(fiscal[i])}', style: t(9, w: FontWeight.w500, c: const Color(0xFF65766E)))])),
                            Text(money(fiscal[i].totalIncl), style: t(11, w: FontWeight.w800)),
                          ]),
                        ),
                      ),
                  ]),
          ),
        ]),
      ),
    ]);
  }

  String _label(Sale e) => e.uploaded ? 'TRA accepted' : e.uploadStatus == 'failed' ? 'TRA rejected' : 'Queued';
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v);
  final String k, v;
  @override
  Widget build(BuildContext context) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(k, style: t(9, w: FontWeight.w800, c: Colors.black45, ls: 1)), const SizedBox(height: 4), Text(v, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11, w: FontWeight.w700, c: K.ink))]));
}

class _ReceiptDetail extends StatelessWidget {
  const _ReceiptDetail(this.sale);
  final Sale sale;
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Receipt #${sale.number}', style: t(18, w: FontWeight.w800)), Badge2(sale.uploaded ? 'Accepted' : sale.uploadStatus == 'failed' ? 'Rejected' : 'Queued', color: sale.uploaded ? K.lime : sale.uploadStatus == 'failed' ? K.danger : K.amber)]),
      const SizedBox(height: 4),
      Text('${DateFormat('d MMM yyyy HH:mm').format(sale.createdAt)}  -  ${sale.paymentType}', style: t(11, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 14),
      for (final i in sale.items) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text('${fmtQ(i.qty)} x ${i.name}', style: t(12, w: FontWeight.w500))), Text(num0(i.amount), style: t(12))])),
      const Divider(color: Color(0x1AFFFFFF)),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Net ${num0(sale.totalExcl)}  -  VAT ${num0(sale.totalVat)}', style: t(11, w: FontWeight.w500, c: K.muted)), Text(money(sale.totalIncl), style: t(15, w: FontWeight.w800))]),
      const SizedBox(height: 10),
      Text('Verification: ${sale.rctvnum}', style: mono(10, c: K.muted)),
      if (sale.ackMsg != null) Text('TRA: ${sale.ackCode} ${sale.ackMsg}', style: mono(10, c: K.muted)),
      if (sale.lastError != null && !sale.uploaded) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Last error: ${sale.lastError}', style: t(11, w: FontWeight.w600, c: K.danger))),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: LimeButton('Reprint', icon: Ic.printer, onTap: () async => toast(context, await s.printReceipt(sale)))),
        const SizedBox(width: 10),
        Expanded(child: LimeButton('PDF', icon: Ic.pdf, outline: true, onTap: () => s.printer.printPdf(sale, s.cfg))),
      ]),
    ]);
  }
}

String fmtQ(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();
