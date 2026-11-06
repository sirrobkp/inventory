import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Listens for an external barcode scanner (USB / Bluetooth in "keyboard" / HID mode).
/// Scanners type the code very fast and finish with Enter (or Tab). When no text field is focused
/// and this screen is the top route, the code is delivered to [onScan].
class ScannerListener extends StatefulWidget {
  const ScannerListener({super.key, required this.child, required this.onScan});
  final Widget child;
  final void Function(String code) onScan;
  @override
  State<ScannerListener> createState() => _ScannerListenerState();
}

class _ScannerListenerState extends State<ScannerListener> {
  final _buf = StringBuffer();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _typingInField() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false; // a sheet / scanner page is open
    if (_typingInField()) {
      _buf.clear();
      return false; // let the text field receive the scan
    }
    final now = DateTime.now();
    if (now.difference(_last).inMilliseconds > 250) _buf.clear(); // human typing is slower than a scanner
    _last = now;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.tab) {
      final code = _buf.toString().trim();
      _buf.clear();
      if (code.length >= 3) {
        widget.onScan(code);
        return true;
      }
      return false;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 32) _buf.write(ch);
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
