import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../services/sdl_service.dart';
import '../services/share_helper.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

class SdlScreen extends StatefulWidget {
  const SdlScreen({super.key});
  @override
  State<SdlScreen> createState() => _SdlScreenState();
}

class _SdlScreenState extends State<SdlScreen> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  bool _busy = false;
  bool? _hasTpl;
  int _rev = 0;
  late final SdlService svc = SdlService(context.read<AppState>().repo);

  String get period => DateFormat('yyyy-MM').format(month);

  @override
  void initState() {
    super.initState();
    _checkTpl();
  }

  Future<void> _checkTpl() async {
    final h = await svc.hasTemplate;
    if (mounted) setState(() => _hasTpl = h);
  }

  Future<void> _importTpl() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = r?.files.single.path;
    if (path == null) return;
    try {
      await svc.importTemplate(path);
      await _checkTpl();
      if (mounted) toast(context, 'Template imported');
    } catch (e) {
      if (mounted) toast(context, 'Not a readable .xlsx file: $e');
    }
  }

  Future<void> _export(AppState s) async {
    setState(() => _busy = true);
    try {
      final res = await svc.export(period, s.cfg);
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('SDL file ready', style: t(16, w: FontWeight.w800)),
          content: SingleChildScrollView(child: Text(res.notes.map((e) => '- $e').join('\n\n'), style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5))),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text('Share / save', style: t(12, c: K.lime)))],
        ),
      );
      if (mounted) await shareFile(context, res.file.path);
    } on StateError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'Export failed: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final rate = SdlService.rateOf(s.cfg);
    final threshold = SdlService.thresholdOf(s.cfg);
    final due = DateTime(month.year, month.month + 1, 7);
    return Scaffold(
      appBar: AppBar(title: Text('SDL return', style: t(18, w: FontWeight.w800))),
      body: FutureBuilder<List<PayLine>>(
        key: ValueKey('$period-$_rev'),
        future: s.repo.payrollFor(period),
        builder: (_, snap) {
          final lines = snap.data ?? [];
          final gross = lines.fold<double>(0, (a, l) => a + l.gross);
          final below = lines.length < threshold;
          return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              IconBtn(Ic.chevron, size: 40, onTap: () => setState(() => month = DateTime(month.year, month.month - 1, 1))),
              Text(DateFormat('MMMM yyyy').format(month), style: t(16, w: FontWeight.w800)),
              IconBtn(Ic.chevron, size: 40, onTap: () => setState(() => month = DateTime(month.year, month.month + 1, 1))),
            ]),
            const SizedBox(height: 14),
            Glass(
              radius: 26,
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SDL DUE', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.8)),
                const SizedBox(height: 6),
                Text(money(below ? 0 : gross * rate), style: t(26, w: FontWeight.w800, ls: -1, c: K.lime)),
                const SizedBox(height: 10),
                Text('${lines.length} employees  -  gross ${money(gross)}  -  rate ${(rate * 100).toStringAsFixed(2)}%', style: t(11, w: FontWeight.w500, c: K.muted)),
                Text('Due by ${DateFormat('d MMM yyyy').format(due)}', style: t(11, w: FontWeight.w500, c: K.muted)),
                if (below) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Below the $threshold-employee threshold, so SDL shows as 0. Change the threshold/rate below if your registration differs (e.g. Zanzibar).', style: t(10, w: FontWeight.w600, c: K.amber, h: 1.4))),
                const SizedBox(height: 10),
                GestureDetector(onTap: () => showSheet(context, const _RateForm()), child: Text('Edit SDL rate / threshold', style: t(11, c: K.lime))),
              ]),
            ),
            const SizedBox(height: 16),
            SectionTitle('Employees', action: '+ Add', onAction: () => showSheet(context, const _EmployeeForm()).then((_) => setState(() => _rev++))),
            if (lines.isEmpty) const Glass(child: Empty('No employees yet. Add your staff to prepare the SDL return.')),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Glass(
                  radius: 20,
                  padding: const EdgeInsets.all(14),
                  onTap: () => showSheet(context, _PayForm(period: period, line: l)).then((_) => setState(() => _rev++)),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(l.emp.name, style: t(13)), const SizedBox(height: 4), Text('${l.emp.kind == 'casual' ? 'Casual' : 'Permanent'}${l.emp.tin.isEmpty ? '' : '  -  TIN ${l.emp.tin}'}', style: t(10, w: FontWeight.w500, c: K.muted))])),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(money(l.gross), style: t(12)), const SizedBox(height: 4), Text('SDL ${money(l.gross * rate)}', style: t(10, w: FontWeight.w500, c: K.dim))]),
                  ]),
                ),
              ),
            const SizedBox(height: 12),
            Text('Tap an employee to change this month\'s pay (bonus, overtime, unpaid leave).', style: t(10, w: FontWeight.w500, c: K.dim)),
            const SizedBox(height: 18),
            Text('TRA SDL TEMPLATE', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.8)),
            const SizedBox(height: 8),
            Text(_hasTpl == true ? 'Template imported. The export fills it in place.' : 'Download the blank SDL return template from the TRA e-filing portal, then import it here so the app can fill it.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
            const SizedBox(height: 10),
            LimeButton(_hasTpl == true ? 'Replace TRA template (.xlsx)' : 'Import TRA SDL template (.xlsx)', icon: Ic.upload, outline: true, onTap: _importTpl),
            if (_hasTpl == true) ...[
              const SizedBox(height: 8),
              GestureDetector(onTap: () async { await svc.removeTemplate(); await _checkTpl(); }, child: Text('Remove template (use standard layout)', style: t(11, c: K.danger))),
            ],
            const SizedBox(height: 14),
            LimeButton(_hasTpl == true ? 'Export filled TRA template' : 'Export SDL return (Excel)', icon: Ic.table, busy: _busy, onTap: () => _export(s)),
          ]);
        },
      ),
    );
  }
}

class _RateForm extends StatefulWidget {
  const _RateForm();
  @override
  State<_RateForm> createState() => _RateFormState();
}

class _RateFormState extends State<_RateForm> {
  late final cfg = context.read<AppState>().cfg;
  late final rate = TextEditingController(text: (SdlService.rateOf(cfg) * 100).toString());
  late final thr = TextEditingController(text: SdlService.thresholdOf(cfg).toString());
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SDL settings', style: t(18, w: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Mainland Tanzania is currently 3.5% for employers with 10 or more employees. Confirm the rate that applies to you with TRA.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
        const SizedBox(height: 14),
        TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: t(13, w: FontWeight.w500), decoration: dec('Rate (%)')),
        const SizedBox(height: 12),
        TextField(controller: thr, keyboardType: TextInputType.number, style: t(13, w: FontWeight.w500), decoration: dec('Minimum employees to be liable')),
        const SizedBox(height: 18),
        LimeButton('Save', icon: Ic.check, onTap: () async {
          await context.read<AppState>().saveCfg({'sdl_rate': rate.text.trim(), 'sdl_threshold': thr.text.trim()});
          if (context.mounted) Navigator.pop(context);
        }),
      ]);
}

class _EmployeeForm extends StatefulWidget {
  const _EmployeeForm();
  @override
  State<_EmployeeForm> createState() => _EmployeeFormState();
}

class _EmployeeFormState extends State<_EmployeeForm> {
  final name = TextEditingController(), tin = TextEditingController(), nida = TextEditingController(), basic = TextEditingController(), allow = TextEditingController(text: '0');
  String kind = 'permanent';
  @override
  Widget build(BuildContext context) {
    Widget f(TextEditingController c, String l, {bool n = false}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, keyboardType: n ? const TextInputType.numberWithOptions(decimal: true) : null, style: t(13, w: FontWeight.w500), decoration: dec(l)));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Add employee', style: t(18, w: FontWeight.w800)),
      const SizedBox(height: 14),
      f(name, 'Full name'),
      Row(children: [Expanded(child: f(tin, 'TIN')), const SizedBox(width: 10), Expanded(child: f(nida, 'NIDA number'))]),
      Row(children: [Expanded(child: f(basic, 'Basic salary / month', n: true)), const SizedBox(width: 10), Expanded(child: f(allow, 'Allowances / month', n: true))]),
      Wrap(spacing: 8, children: [Chip2('Permanent', selected: kind == 'permanent', onTap: () => setState(() => kind = 'permanent')), Chip2('Casual', selected: kind == 'casual', onTap: () => setState(() => kind = 'casual'))]),
      const SizedBox(height: 18),
      LimeButton('Save employee', icon: Ic.check, onTap: () async {
        if (name.text.trim().isEmpty) return toast(context, 'Enter the name');
        await context.read<AppState>().repo.saveEmployee(Employee(name: name.text.trim(), tin: tin.text.trim(), nida: nida.text.trim(), kind: kind, basic: double.tryParse(basic.text.replaceAll(',', '')) ?? 0, allowances: double.tryParse(allow.text.replaceAll(',', '')) ?? 0));
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

class _PayForm extends StatefulWidget {
  const _PayForm({required this.period, required this.line});
  final String period;
  final PayLine line;
  @override
  State<_PayForm> createState() => _PayFormState();
}

class _PayFormState extends State<_PayForm> {
  late final basic = TextEditingController(text: widget.line.basic.toString());
  late final allow = TextEditingController(text: widget.line.allowances.toString());
  late final other = TextEditingController(text: widget.line.other.toString());
  @override
  Widget build(BuildContext context) {
    Widget f(TextEditingController c, String l) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: t(13, w: FontWeight.w500), decoration: dec(l)));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.line.emp.name, style: t(18, w: FontWeight.w800)),
      Text('Pay for ${widget.period}', style: t(11, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 14),
      f(basic, 'Basic salary'),
      f(allow, 'Allowances'),
      f(other, 'Bonus / overtime / other'),
      LimeButton('Save month', icon: Ic.check, onTap: () async {
        final r = context.read<AppState>().repo;
        await r.savePayroll(widget.period, widget.line.emp.id!, double.tryParse(basic.text) ?? 0, double.tryParse(allow.text) ?? 0, double.tryParse(other.text) ?? 0);
        if (context.mounted) Navigator.pop(context);
      }),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: () async {
          await context.read<AppState>().repo.archiveEmployee(widget.line.emp.id!);
          if (context.mounted) Navigator.pop(context);
        },
        child: Center(child: Text('Remove employee', style: t(11, c: K.danger))),
      ),
    ]);
  }
}
