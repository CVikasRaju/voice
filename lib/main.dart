import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'ml/stt_engine.dart';
import 'ml/tts_engine.dart';
import 'net/transport.dart';
import 'state/battery_monitor.dart';
import 'state/transceiver_controller.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const iTantraApp());
}

class iTantraApp extends StatelessWidget {
  const iTantraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final controller = TransceiverController(
              stt: SttEngine(),
              tts: TtsEngine(),
              transport: LoopbackTransport(),
            );
            controller.loadLog();
            return controller;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final monitor = BatteryMonitor();
            monitor.startMonitoring();
            return monitor;
          },
        ),
      ],
      child: MaterialApp(
        title: 'iTantra',
        debugShowCheckedModeBanner: false,
        theme: iTantraTheme.dark,
        home: const HomeScreen(),
      ),
    );
  }
}
