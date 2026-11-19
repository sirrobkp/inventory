/// Called once at startup. Mobile and macOS use the native sqflite plugin, so nothing to do.
/// The Windows/Linux CI scripts overwrite this file with sqflite_common_ffi initialisation.
Future<void> initPlatform() async {}
