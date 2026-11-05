import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'icons.dart';
import 'theme.dart';

/// Camera barcode scanner. [onCode] returns a message to show (e.g. "Added: Rice") or null.
/// With [continuous] the camera stays open so a cashier can scan many items in a row.
/// (USB / Bluetooth "keyboard wedge" scanners also work: focus any search field and scan.)
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, required this.onCode, this.continuous = false, this.title = 'Scan barcode'});
  final Future<String?> Function(String code) onCode;
  final bool continuous;
  final String title;
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _ctl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates, facing: CameraFacing.back);
  String? _last;
  DateTime _lastAt = DateTime(2000);
  String _msg = 'Point the camera at a barcode';
  bool _busy = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _detect(BarcodeCapture cap) async {
    if (_busy) return;
    final code = cap.barcodes.firstOrNull?.rawValue;
    if (code == null || code.isEmpty) return;
    if (code == _last && DateTime.now().difference(_lastAt).inMilliseconds < 1500) return;
    _busy = true;
    _last = code;
    _lastAt = DateTime.now();
    final m = await widget.onCode(code);
    if (!mounted) return;
    if (widget.continuous) {
      setState(() => _msg = m ?? code);
    } else {
      Navigator.pop(context, code);
    }
    _busy = false;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          MobileScanner(controller: _ctl, onDetect: _detect),
          Center(child: Container(width: 260, height: 160, decoration: BoxDecoration(border: Border.all(color: K.lime, width: 2.5), borderRadius: BorderRadius.circular(22)))),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Ic.close, color: Colors.white)),
                Expanded(child: Text(widget.title, style: t(16, w: FontWeight.w800))),
                IconButton(onPressed: _ctl.toggleTorch, icon: const Icon(Ic.flashlight, color: Colors.white)),
              ]),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: K.sheet, borderRadius: BorderRadius.circular(20)), child: Text(_msg, textAlign: TextAlign.center, style: t(13))),
          ),
        ]),
      );
}
