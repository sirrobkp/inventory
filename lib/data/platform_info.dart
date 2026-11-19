import 'dart:io' show Platform;

/// Phones have a camera + Bluetooth printers; desktops use USB scanners (keyboard mode) and system printers.
bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
bool get hasCamera => Platform.isAndroid || Platform.isIOS;
