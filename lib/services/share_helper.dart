import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Shares a file. iOS (and iPad especially) REQUIRES a non-zero source rectangle inside the screen,
/// otherwise share_plus throws "sharePositionOrigin: argument must be set, {{x, y}, {w, h}} must be non-zero...".
Future<void> shareFile(BuildContext context, String path, {String? text}) async {
  // Desktop: no system share sheet for files - let the user choose where to save it.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final name = path.split(Platform.pathSeparator).last;
    final dest = await FilePicker.platform.saveFile(dialogTitle: 'Save file', fileName: name);
    if (dest != null) await File(path).copy(dest);
    return;
  }
  final screen = MediaQuery.of(context).size;
  Rect origin = Rect.fromLTWH(screen.width / 2 - 1, screen.height / 2 - 1, 2, 2);
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize && box.size.width > 0 && box.size.height > 0) {
    final r = box.localToGlobal(Offset.zero) & box.size;
    final inside = r.left >= 0 && r.top >= 0 && r.right <= screen.width + 1 && r.bottom <= screen.height + 1;
    if (inside) origin = r;
  }
  await Share.shareXFiles([XFile(path)], text: text, sharePositionOrigin: origin);
}
