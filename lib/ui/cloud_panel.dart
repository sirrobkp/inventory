import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/secret_store.dart';
import '../services/cloud_service.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// Firebase cloud backup / restore (Firestore + Email/Password), no native Firebase plugins.
class CloudPanel extends StatefulWidget {
  const CloudPanel({super.key});
  @override
  State<CloudPanel> createState() => _CloudPanelState();
}

class _CloudPanelState extends State<CloudPanel> {
  late final AppState s = context.read<AppState>();
  late final project = TextEditingController(text: s.cfg['cloud_project'] ?? '');
  late final apiKey = TextEditingController(text: s.cfg['cloud_api_key'] ?? '');
  late final email = TextEditingController(text: s.cfg['cloud_email'] ?? '');
  final password = TextEditingController();
  bool busy = false;
  String status = '';

  @override
  void initState() {
    super.initState();
    SecretStore.read('cloud_password').then((v) {
      if (mounted && v != null) setState(() => password.text = v);
    });
  }

  Future<void> _save() async {
    await s.saveCfg({'cloud_project': project.text.trim(), 'cloud_api_key': apiKey.text.trim(), 'cloud_email': email.text.trim()});
    await SecretStore.write('cloud_password', password.text);
    s.cloud.forgetLogin();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() { busy = true; status = ''; });
    try {
      await _save();
      await job();
    } on StateError catch (e) {
      status = e.message;
    } catch (e) {
      status = 'Failed: $e';
    }
    await s.refresh();
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final last = DateTime.tryParse(s.cfg['cloud_last_backup'] ?? '');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Glass(
        radius: 18,
        padding: const EdgeInsets.all(14),
        child: Text('Keeps a full copy of your data in your own Google Firebase project. The app still works offline and stores data on this device; the cloud copy lets you recover or move to a new device. Steps: create a Firebase project, enable Authentication > Email/Password and add a user, create a Firestore database, paste the rules below, then enter the details here.', style: t(11, w: FontWeight.w500, c: K.muted, h: 1.5)),
      ),
      const SizedBox(height: 12),
      for (final f in [(project, 'Firebase project ID', false), (apiKey, 'Web API key (Project settings)', false), (email, 'Firebase user email', false), (password, 'Firebase user password', true)])
        Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: f.$1, obscureText: f.$3, autocorrect: false, enableSuggestions: false, style: t(13, w: FontWeight.w500), decoration: dec(f.$2))),
      Row(children: [
        Expanded(child: LimeButton('Save & test', icon: Ic.zap, outline: true, busy: busy, onTap: () => _run(() async {
          final r = await s.cloud.test();
          status = r;
        }))),
        const SizedBox(width: 10),
        Expanded(child: LimeButton('Back up now', icon: Ic.upload, busy: busy, onTap: () => _run(() async {
          await s.cloud.backup((m) {
            if (mounted) setState(() => status = m);
          });
        }))),
      ]),
      const SizedBox(height: 10),
      LimeButton('Restore from cloud', icon: Ic.download, outline: true, onTap: busy ? null : () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Restore from cloud?', style: t(16, w: FontWeight.w800)),
            content: Text('This REPLACES all data on this device (products, sales, purchases, books) with the latest cloud backup. Printer and cloud login settings are kept. This cannot be undone.', style: t(12, w: FontWeight.w500, c: K.muted, h: 1.5)),
            actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Cancel', style: t(12, c: K.muted))), TextButton(onPressed: () => Navigator.pop(c, true), child: Text('Restore', style: t(12, c: K.danger)))],
          ),
        );
        if (ok == true) await _run(() => s.cloud.restore((m) {
          if (mounted) setState(() => status = m);
        }));
      }),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Automatic backup every 6 hours', style: t(13)),
        subtitle: Text(last == null ? 'No backup yet' : 'Last: ${DateFormat('d MMM yyyy HH:mm').format(last)}', style: t(10, w: FontWeight.w500, c: K.muted)),
        value: s.cfg['cloud_auto'] == '1',
        onChanged: (v) => s.saveCfg({'cloud_auto': v ? '1' : '0'}),
      ),
      if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(status, style: t(11, w: FontWeight.w600, c: K.lime, h: 1.4))),
      GestureDetector(
        onTap: () async {
          await Clipboard.setData(const ClipboardData(text: CloudService.rules));
          if (mounted) toast(context, 'Security rules copied - paste them in Firestore > Rules > Publish');
        },
        child: Text('Copy Firestore security rules', style: t(11, c: K.lime)),
      ),
    ]);
  }
}
