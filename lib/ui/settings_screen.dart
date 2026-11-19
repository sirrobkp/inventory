import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:provider/provider.dart';
import '../services/share_helper.dart';

import '../data/app_state.dart';
import '../data/secret_store.dart';
import '../data/db.dart';
import '../services/tra_service.dart';
import 'icons.dart';
import '../data/platform_info.dart';
import 'supplier_panel.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppState s = context.read<AppState>();
  late final bizName = TextEditingController(text: s.cfg['biz_name'] ?? s.cfg['name'] ?? '');
  late final bizAddr = TextEditingController(text: s.cfg['biz_address'] ?? s.cfg['address'] ?? '');
  late final bizPhone = TextEditingController(text: s.cfg['biz_phone'] ?? s.cfg['mobile'] ?? '');
  late final footer = TextEditingController(text: s.cfg['receipt_footer'] ?? 'Thank you for shopping with us');
  late final po = TextEditingController(text: s.cfg['po_box'] ?? '');
  late final regNo = TextEditingController(text: s.cfg['reg_no'] ?? '');
  late final directors = TextEditingController(text: s.cfg['directors'] ?? '');
  late final activity = TextEditingController(text: s.cfg['principal_activity'] ?? '');
  late final auditor = TextEditingController(text: s.cfg['auditor_name'] ?? '');
  late final auditorAddr = TextEditingController(text: s.cfg['auditor_address'] ?? '');
  late final financeHead = TextEditingController(text: s.cfg['finance_head'] ?? '');
  late final taxRate = TextEditingController(text: s.cfg['income_tax_rate'] ?? '30');
  late String entity = s.cfg['entity_type'] ?? 'company';
  late String fiscalMode = s.cfg['fiscal_mode'] ?? 'direct';
  late final tin = TextEditingController(text: s.cfg['tin'] ?? '');
  late final certKey = TextEditingController(text: s.cfg['cert_key'] ?? '');
  late final base = TextEditingController(text: s.cfg['tra_base'] ?? TraService.defaultBase);
  final pfxPass = TextEditingController();
  bool _busy = false;
  String? _certInfo;
  List<BluetoothInfo> _printers = [];

  @override
  void initState() {
    super.initState();
    s.tra.hasCert.then((h) => mounted ? setState(() => _certInfo = h ? 'Certificate imported' : null) : null);
  }

  Future<void> _saveBiz() async {
    await s.saveCfg({
      'biz_name': bizName.text.trim(),
      'biz_address': bizAddr.text.trim(),
      'biz_phone': bizPhone.text.trim(),
      'receipt_footer': footer.text.trim(),
      'po_box': po.text.trim(),
      'reg_no': regNo.text.trim(),
      'directors': directors.text.trim(),
      'principal_activity': activity.text.trim(),
      'auditor_name': auditor.text.trim(),
      'auditor_address': auditorAddr.text.trim(),
      'finance_head': financeHead.text.trim(),
      'income_tax_rate': taxRate.text.trim().isEmpty ? '30' : taxRate.text.trim(),
      'entity_type': entity,
    });
    if (mounted) toast(context, 'Saved');
  }

  Future<void> _importPfx() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = r?.files.single.path;
    if (path == null) return;
    if (pfxPass.text.isEmpty) return toast(context, 'Enter the certificate password first, then pick the file');
    setState(() => _busy = true);
    try {
      await File(path).copy(await s.tra.pfxPath);
      await SecretStore.write('pfx_password', pfxPass.text);
      final serial = await s.tra.certSerialHex();
      setState(() => _certInfo = 'Certificate OK - serial $serial');
    } catch (e) {
      try {
        final f = File(await s.tra.pfxPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      setState(() => _certInfo = null);
      if (mounted) toast(context, 'Could not read certificate (wrong password?): $e');
    }
    setState(() => _busy = false);
  }

  Future<void> _register() async {
    if (tin.text.trim().isEmpty || certKey.text.trim().isEmpty) return toast(context, 'Enter TIN and certificate key');
    if (!await s.tra.hasCert) return toast(context, 'Import the .pfx certificate first');
    setState(() => _busy = true);
    await s.saveCfg({'tra_base': base.text.trim(), 'tin': tin.text.trim()});
    final r = await s.tra.register(tin: tin.text.trim(), certKey: certKey.text.trim());
    await s.refresh();
    setState(() => _busy = false);
    if (mounted) toast(context, r.ok ? 'VFD registered: ${r.msg}' : 'Registration failed: ${r.code} ${r.msg}');
  }

  Future<void> _findPrinters() async {
    final p = await s.printer.paired();
    setState(() => _printers = p);
    if (p.isEmpty && mounted) toast(context, 'No paired Bluetooth printers. Pair it in Android settings first.');
  }

  Future<void> _backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final dst = File('${dir.path}/kibo_trade_backup_${DateTime.now().millisecondsSinceEpoch}.db');
    await File(await Db.path).copy(dst.path);
    if (!mounted) return;
    await shareFile(context, dst.path, text: 'Kibo Trade database backup');
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    Widget f(TextEditingController c, String l, {bool obscure = false, TextInputType? k}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, obscureText: obscure, keyboardType: k, style: t(13, w: FontWeight.w500), decoration: dec(l)));
    Widget h(String t1) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 12), child: Text(t1.toUpperCase(), style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.8)));
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text('Settings', style: t(18, w: FontWeight.w800)), elevation: 0),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
        h('Business & receipt'),
        f(bizName, 'Business name'),
        f(bizAddr, 'Address'),
        f(bizPhone, 'Phone', k: TextInputType.phone),
        f(footer, 'Receipt footer'),
        h('Company profile & tax (financial statements)'),
        Wrap(spacing: 8, children: [Chip2('Company (Ltd)', selected: entity == 'company', onTap: () => setState(() => entity = 'company')), Chip2('Sole proprietor', selected: entity == 'sole', onTap: () => setState(() => entity = 'sole'))]),
        const SizedBox(height: 12),
        f(po, 'P.O. Box'),
        f(regNo, 'Registration / incorporation number'),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: directors, minLines: 2, maxLines: 5, style: t(13, w: FontWeight.w500), decoration: dec('Directors - one per line: Name, Nationality'))),
        Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: activity, minLines: 1, maxLines: 3, style: t(13, w: FontWeight.w500), decoration: dec('Principal activity'))),
        f(auditor, 'Auditor firm name'),
        f(auditorAddr, 'Auditor address'),
        f(financeHead, 'Head of finance / accountant name'),
        f(taxRate, 'Income tax rate % (company 30)', k: const TextInputType.numberWithOptions(decimal: true)),
        LimeButton('Save business info', icon: Ic.check, outline: true, onTap: _saveBiz),
        h('Fiscal device (VFD)'),
        if (!isDesktop) ...[
        Wrap(spacing: 8, runSpacing: 8, children: [
          Chip2('Supplier API (any VFD supplier)', selected: fiscalMode == 'supplier', onTap: () { setState(() => fiscalMode = 'supplier'); s.saveCfg({'fiscal_mode': 'supplier'}); }),
          Chip2('Direct TRA (own certificate)', selected: fiscalMode == 'direct', onTap: () { setState(() => fiscalMode = 'direct'); s.saveCfg({'fiscal_mode': 'direct'}); }),
        ]),
        const SizedBox(height: 14),
        ],
        if (isDesktop) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('On desktop, connect through your VFD supplier\'s API (direct certificate signing is available on Android/iOS only).', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5))),
        if (fiscalMode == 'supplier' || isDesktop) const SupplierPanel() else ...[
        Glass(radius: 18, padding: const EdgeInsets.all(14), child: Text(
          'You need a TRA-issued VFD certificate (.pfx), its password and the certificate key, obtained through TRA VFD onboarding. '
          'Start with the TEST environment URL TRA gives you.',
          style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5))),
        const SizedBox(height: 12),
        f(base, 'EFDMS base URL', k: TextInputType.url),
        f(tin, 'Business TIN'),
        f(certKey, 'Certificate key (CERTKEY)'),
        f(pfxPass, 'Certificate (.pfx) password', obscure: true),
        LimeButton(_certInfo ?? 'Import .pfx certificate', icon: Ic.upload, outline: true, busy: _busy, onTap: _importPfx),
        const SizedBox(height: 10),
        LimeButton(s.registered ? 'Re-register VFD' : 'Register VFD with TRA', icon: Ic.verified, busy: _busy, onTap: _register),
        if (s.registered) Padding(padding: const EdgeInsets.only(top: 10), child: Text('Registered: ${s.cfg['name'] ?? ''}  -  REGID ${s.cfg['regid']}  -  UIN ${s.cfg['uin']}', style: mono(10, c: K.muted))),
        ],
        h('Printer'),
        Row(children: [
          Expanded(child: Chip2('58 mm', selected: (s.cfg['paper'] ?? '58') == '58', onTap: () => s.saveCfg({'paper': '58'}))),
          const SizedBox(width: 8),
          Expanded(child: Chip2('80 mm', selected: s.cfg['paper'] == '80', onTap: () => s.saveCfg({'paper': '80'}))),
        ]),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Auto-print after every sale', style: t(13)),
          value: s.cfg['auto_print'] == '1',
          onChanged: (v) => s.saveCfg({'auto_print': v ? '1' : '0'}),
        ),
        if (isDesktop) Text('Printing uses your computer\'s printers: when you tap Print, pick the receipt/thermal printer and its paper size in the print dialog. 58/80 mm above sets the Bluetooth layout on phones.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)) else ...[
        Text(s.cfg['printer_mac'] == null || s.cfg['printer_mac']!.isEmpty ? 'No printer selected' : 'Selected: ${s.cfg['printer_name'] ?? ''} (${s.cfg['printer_mac']})', style: t(11, w: FontWeight.w500, c: K.muted)),
        const SizedBox(height: 10),
        LimeButton('Find paired Bluetooth printers', icon: Ic.bluetooth, outline: true, onTap: _findPrinters),
        for (final p in _printers)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Glass(radius: 16, padding: const EdgeInsets.all(12), onTap: () async {
              await s.saveCfg({'printer_mac': p.macAdress, 'printer_name': p.name});
              if (mounted) toast(context, 'Printer set: ${p.name}');
            }, child: Row(children: [const Icon(Ic.printer, size: 18, color: K.lime), const SizedBox(width: 10), Expanded(child: Text(p.name, style: t(12))), Text(p.macAdress, style: mono(9, c: K.dim))])),
          ),
        ],
        h('Data'),
        Text('All data is stored on this device (SQLite). Back it up regularly - if the phone is lost, so is your fiscal history.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
        const SizedBox(height: 10),
        LimeButton('Export database backup', icon: Ic.download, outline: true, onTap: _backup),
      ]),
    );
  }
}
