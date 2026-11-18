import 'package:file_picker/file_picker.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../services/generic_vfd_service.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// Connect ANY VFD supplier: import its API profile (JSON), type the credentials, test, done.
class SupplierPanel extends StatefulWidget {
  const SupplierPanel({super.key});
  @override
  State<SupplierPanel> createState() => _SupplierPanelState();
}

class _SupplierPanelState extends State<SupplierPanel> {
  late final AppState s = context.read<AppState>();
  VfdProfile? profile;
  final ctl = <String, TextEditingController>{};
  late final tin = TextEditingController(text: s.cfg['tin'] ?? '');
  bool busy = false;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await s.vfd.profile();
    final creds = p == null ? <String, String>{} : await s.vfd.credentials(p);
    if (!mounted) return;
    setState(() {
      profile = p;
      for (final f in p?.fields ?? <VfdField>[]) {
        ctl[f.key] = TextEditingController(text: creds[f.key] ?? '');
      }
      loaded = true;
    });
  }

  Future<void> _save() async {
    if (profile == null) return toast(context, 'Import a supplier profile first');
    if (tin.text.trim().isEmpty) return toast(context, 'Enter your business TIN');
    setState(() => busy = true);
    await s.vfd.saveCredentials({for (final e in ctl.entries) e.key: e.value.text.trim()});
    await s.saveCfg({'tin': tin.text.trim(), 'fiscal_mode': 'supplier', 'supplier_ready': '1'});
    if (mounted) {
      setState(() => busy = false);
      toast(context, 'Supplier activated - new sales will be fiscalised through ${profile!.name}');
    }
  }

  Future<void> _test() async {
    setState(() => busy = true);
    await s.vfd.saveCredentials({for (final e in ctl.entries) e.key: e.value.text.trim()});
    final r = await s.vfd.test();
    await s.refresh();
    if (mounted) {
      setState(() => busy = false);
      showDialog(context: context, builder: (c) => AlertDialog(title: Text('Test connection', style: t(16, w: FontWeight.w800)), content: Text(r, style: t(12, w: FontWeight.w500, c: K.muted)), actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text('OK', style: t(12, c: K.lime)))]));
    }
  }

  Future<void> _preview() async {
    final recent = await s.repo.recentSales(limit: 1);
    final sale = recent.isEmpty ? Sale.sample() : await s.repo.getSale(recent.first.id!);
    final text = await s.vfd.preview(sale);
    if (!mounted) return;
    showSheet(context, _TextView(title: recent.isEmpty ? 'Request preview (sample sale)' : 'Request preview (last sale)', text: text));
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final last = s.cfg['vfd_last_response'] ?? '';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Glass(
        radius: 18,
        padding: const EdgeInsets.all(14),
        child: Text('Connect any VFD supplier: import the supplier\'s API profile (a small JSON file describing its endpoints), then enter the credentials the supplier gave you. The supplier issues the fiscal receipt number and verification code, and reports to TRA for you.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
      ),
      const SizedBox(height: 12),
      if (!loaded) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(color: K.lime))),
      if (loaded) ...[
        Row(children: [
          Expanded(child: Text(profile == null ? 'No supplier profile imported' : 'Profile: ${profile!.name}', style: t(13, c: profile == null ? K.amber : K.lime))),
        ]),
        const SizedBox(height: 10),
        LimeButton(profile == null ? 'Import supplier profile' : 'Replace supplier profile', icon: Ic.upload, outline: true, onTap: () async {
          final ok = await showSheet<bool>(context, const _ImportSheet());
          if (ok == true) await _load();
        }),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () async {
            await Clipboard.setData(const ClipboardData(text: VfdProfile.example));
            if (mounted) toast(context, 'Example profile copied - send it to your developer/assistant with the supplier\'s API docs');
          },
          child: Text('Copy example profile format', style: t(11, c: K.lime)),
        ),
        if (profile != null) ...[
          const SizedBox(height: 16),
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: tin, style: t(13, w: FontWeight.w500), decoration: dec('Business TIN'))),
          for (final f in profile!.fields)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: ctl[f.key], obscureText: f.secret, enableSuggestions: false, autocorrect: false, style: t(13, w: FontWeight.w500), decoration: dec(f.label))),
          LimeButton('Save credentials & activate', icon: Ic.verified, busy: busy, onTap: _save),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: LimeButton('Test connection', icon: Ic.zap, outline: true, onTap: busy ? null : _test)),
            const SizedBox(width: 10),
            Expanded(child: LimeButton('Preview request', icon: Ic.code, outline: true, onTap: _preview)),
          ]),
        ],
        if (last.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('LAST SUPPLIER RESPONSE', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.6)),
          const SizedBox(height: 6),
          Glass(radius: 14, padding: const EdgeInsets.all(12), child: SelectableText(last, style: mono(10, c: K.muted))),
        ],
      ],
    ]);
  }
}

class _TextView extends StatelessWidget {
  const _TextView({required this.title, required this.text});
  final String title, text;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t(16, w: FontWeight.w800)),
        const SizedBox(height: 12),
        Glass(radius: 14, padding: const EdgeInsets.all(12), child: SelectableText(text, style: mono(10))),
        const SizedBox(height: 12),
        LimeButton('Copy', icon: Ic.check, outline: true, onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) toast(context, 'Copied');
        }),
      ]);
}

class _ImportSheet extends StatefulWidget {
  const _ImportSheet();
  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final text = TextEditingController();
  String? error;

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = r?.files.single.path;
    if (path == null) return;
    text.text = await File(path).readAsString();
    setState(() => error = null);
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) setState(() => text.text = d!.text!);
  }

  Future<void> _save() async {
    try {
      await context.read<AppState>().vfd.saveProfile(text.text.trim());
      if (mounted) Navigator.pop(context, true);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Import supplier profile', style: t(18, w: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Paste the JSON profile, pick a .json file, or load the example to see the format.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
        const SizedBox(height: 12),
        TextField(controller: text, minLines: 6, maxLines: 12, style: mono(10), decoration: dec(null, hint: '{ "name": "...", "baseUrl": "...", ... }')),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: t(11, w: FontWeight.w600, c: K.danger))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: LimeButton('Paste', icon: Ic.fileText, outline: true, onTap: _paste)),
          const SizedBox(width: 8),
          Expanded(child: LimeButton('File', icon: Ic.upload, outline: true, onTap: _pick)),
          const SizedBox(width: 8),
          Expanded(child: LimeButton('Example', icon: Ic.code, outline: true, onTap: () => setState(() => text.text = VfdProfile.example))),
        ]),
        const SizedBox(height: 12),
        LimeButton('Save profile', icon: Ic.check, onTap: _save),
      ]);
}
