import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/app_state.dart';
import 'ui/theme.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: K.bg,
  ));
  final state = AppState();
  await state.init();
  runApp(ChangeNotifierProvider.value(value: state, child: const KiboApp()));
}

class KiboApp extends StatelessWidget {
  const KiboApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Kibo Trade',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const Shell(),
      );
}
