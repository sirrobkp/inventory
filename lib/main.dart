import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/app_state.dart';
import 'data/platform_init.dart';
import 'ui/theme.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: K.bg,
  ));
  await initPlatform();
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
        // Phone-shaped UI: on a wide desktop window keep it centred and readable
        builder: (context, child) => ColoredBox(
          color: K.bg,
          child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 600), child: child)),
        ),
      );
}
