import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../services/license_service.dart';
import 'icons.dart';
import 'reports_screen.dart';
import 'responsive.dart';
import 'theme.dart';
import 'widgets.dart';

/// Shown instead of the app when the subscription is expired, switched off, or cannot be verified for too long.
/// The customer can still open the reports and export their own data.
class LicenseGate extends StatefulWidget {
  const LicenseGate({super.key});
  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> {
  bool busy = false;
  String note = '';

  Future<void> _check(AppState s) async {
    setState(() { busy = true; note = ''; });
    await s.maybeLicenseSync(force: true);
    if (mounted) {
      setState(() {
        busy = false;
        note = s.license.locked ? (s.licenseError ?? 'Your subscription is still not active. If you have just paid, please wait a moment and try again.') : '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final c = s.cfg;
    final st = s.license.state;
    final title = st == LicenseState.suspended ? 'Subscription switched off' : (st == LicenseState.needsCheck ? 'Please connect to verify' : 'Subscription expired');
    final body = st == LicenseState.suspended
        ? 'Your subscription has been switched off. Please contact support.'
        : st == LicenseState.needsCheck
            ? 'The app has not been able to confirm your subscription for a while. Connect to the internet and tap Check again.'
            : 'Your subscription period has ended. Renew to continue selling. Your data is safe on this device.';
    final price = int.tryParse(c['lic_price'] ?? '') ?? 50000;
    final msg = c['lic_msg'] ?? '';
    final instr = c['lic_instr'] ?? '';
    final support = c['lic_support'] ?? '';
    final name = (c['biz_name'] ?? '').isNotEmpty ? c['biz_name']! : (c['name'] ?? '');
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [K.bg2, K.bg])),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
                Container(width: 64, height: 64, decoration: BoxDecoration(color: const Color(0x26FFC85A), borderRadius: BorderRadius.circular(22)), child: const Icon(Ic.warn, color: K.amber, size: 28)),
                const SizedBox(height: 18),
                Text(title, style: t(24, w: FontWeight.w800, ls: -0.8)),
                const SizedBox(height: 8),
                Text(body, style: t(13, w: FontWeight.w500, c: K.muted, h: 1.5)),
                if (msg.isNotEmpty) ...[const SizedBox(height: 14), Glass(radius: 18, padding: const EdgeInsets.all(14), child: Text(msg, style: t(12, w: FontWeight.w600, c: K.amber, h: 1.4)))],
                const SizedBox(height: 16),
                Glass(
                  radius: 22,
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('MONTHLY SUBSCRIPTION', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.6)),
                    const SizedBox(height: 6),
                    Text(money(price), style: t(22, w: FontWeight.w800, c: K.lime, ls: -0.6)),
                    if (instr.isNotEmpty) ...[const SizedBox(height: 10), Text(instr, style: t(12, w: FontWeight.w500, h: 1.5))],
                    if (support.isNotEmpty) ...[const SizedBox(height: 8), Text('Support: $support', style: t(11, w: FontWeight.w600, c: K.muted))],
                    const SizedBox(height: 12),
                    Text('When you pay, quote this installation ID${name.isEmpty ? '' : ' and your business name ($name)'}:', style: t(10, w: FontWeight.w500, c: K.muted, h: 1.4)),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(text: c['lic_uid'] ?? ''));
                        if (context.mounted) toast(context, 'Installation ID copied');
                      },
                      child: Text((c['lic_uid'] ?? '').isEmpty ? 'Not registered yet - connect to the internet and tap Check again' : '${c['lic_uid']}   (tap to copy)', style: mono(11, c: K.lime)),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                LimeButton("I've paid - check again", icon: Ic.refresh, busy: busy, onTap: () => _check(s)),
                if (note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(note, style: t(11, w: FontWeight.w600, c: K.danger, h: 1.4))),
                const SizedBox(height: 10),
                LimeButton('Open reports & export my data', icon: Ic.fileText, outline: true, onTap: () => Navigator.push(context, pageRoute(const ReportsScreen()))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Renewal reminder on the Home screen (expiring within 7 days, in grace period, or a message from the admin).
class LicenseBanner extends StatelessWidget {
  const LicenseBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final l = s.license;
    final now = DateTime.now();
    final days = l.daysLeft(now);
    final msg = s.cfg['lic_msg'] ?? '';
    final price = int.tryParse(s.cfg['lic_price'] ?? '') ?? 50000;
    String? text;
    if (l.state == LicenseState.grace) {
      final grace = int.tryParse(s.cfg['lic_grace'] ?? '') ?? 3;
      final left = (l.paidUntil!.add(Duration(days: grace)).difference(now).inHours / 24).ceil();
      text = 'Your subscription has expired. The app will lock in $left day${left == 1 ? '' : 's'}. Renew now: ${money(price)} per month.';
    } else if ((l.state == LicenseState.ok || l.state == LicenseState.trial) && days != null && days <= 7) {
      text = '${l.state == LicenseState.trial ? 'Your free trial' : 'Your subscription'} ends ${days <= 0 ? 'today' : 'in $days day${days == 1 ? '' : 's'}'} (${DateFormat('d MMM yyyy').format(l.paidUntil!)}). Renew: ${money(price)} per month.';
    }
    if (text == null && msg.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Glass(
        radius: 20,
        padding: const EdgeInsets.all(14),
        color: const Color(0x1AFFC85A),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Ic.warn, size: 18, color: K.amber),
          const SizedBox(width: 10),
          Expanded(child: Text([if (text != null) text, if (msg.isNotEmpty) msg].join('\n'), style: t(11, w: FontWeight.w600, c: K.amber, h: 1.45))),
        ]),
      ),
    );
  }
}

/// Settings > Subscription: state, expiry, installation ID and exactly what is shared.
class SubscriptionPanel extends StatefulWidget {
  const SubscriptionPanel({super.key});
  @override
  State<SubscriptionPanel> createState() => _SubscriptionPanelState();
}

class _SubscriptionPanelState extends State<SubscriptionPanel> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final c = s.cfg;
    if (!LicenseService.configured) {
      return Text('Subscription checks are not enabled in this build.', style: t(11, w: FontWeight.w500, c: K.muted));
    }
    final l = s.license;
    final label = {
      LicenseState.ok: 'Active',
      LicenseState.trial: 'Free trial',
      LicenseState.grace: 'Expired - grace period',
      LicenseState.expired: 'Expired',
      LicenseState.suspended: 'Switched off',
      LicenseState.needsCheck: 'Needs verification',
      LicenseState.disabled: 'Not enabled',
    }[l.state]!;
    final color = (l.state == LicenseState.ok || l.state == LicenseState.trial) ? K.lime : (l.state == LicenseState.grace ? K.amber : K.danger);
    final checked = DateTime.tryParse(c['lic_checked_at'] ?? '');
    Widget kv(String k, String v) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k, style: t(12, w: FontWeight.w500, c: K.muted)), Flexible(child: Text(v, textAlign: TextAlign.right, style: t(12)))]));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Text('Status', style: t(12, w: FontWeight.w500, c: K.muted)), const Spacer(), Badge2(label, color: color)]),
      const SizedBox(height: 10),
      if (l.paidUntil != null) kv(l.state == LicenseState.trial ? 'Trial ends' : 'Paid until', DateFormat('d MMM yyyy').format(l.paidUntil!.toLocal())),
      kv('Last checked', checked == null ? 'Never' : DateFormat('d MMM yyyy HH:mm').format(checked.toLocal())),
      kv('Monthly price', money(int.tryParse(c['lic_price'] ?? '') ?? 50000)),
      kv('Installation ID', (c['lic_uid'] ?? '').isEmpty ? 'Not registered yet' : '${c['lic_uid']}'),
      if (s.licenseError != null) Text(s.licenseError!, style: t(10, w: FontWeight.w600, c: K.amber)),
      const SizedBox(height: 8),
      LimeButton('Check now', icon: Ic.refresh, outline: true, busy: busy, onTap: () async {
        setState(() => busy = true);
        await s.maybeLicenseSync(force: true);
        if (mounted) setState(() => busy = false);
      }),
      const SizedBox(height: 10),
      Text('What is shared with the subscription server: business name, TIN, device type and OS, app version, fiscal mode, when the app was last used, and five counters (products, sales today, revenue this month, receipts waiting for TRA, low-stock items). No customer names, receipts, product names or prices are sent.', style: t(10, w: FontWeight.w500, c: K.dim, h: 1.5)),
    ]);
  }
}
