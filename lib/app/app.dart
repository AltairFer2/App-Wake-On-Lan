import 'package:flutter/material.dart';

import '../features/devices/presentation/home_screen.dart';
import 'dependencies.dart';
import 'theme.dart';

class AltairWakeApp extends StatelessWidget {
  const AltairWakeApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Altair Wake',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: HomeScreen(dependencies: dependencies),
    );
  }
}
