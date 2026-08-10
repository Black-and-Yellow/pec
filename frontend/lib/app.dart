import 'package:flutter/material.dart';

import 'screens/auth_gate.dart';
import 'screens/home_screen.dart';
import 'services/app_services.dart';
import 'theme/app_theme.dart';

class FinGuardApp extends StatelessWidget {
  const FinGuardApp({required this.services, super.key});

  final AppServices services;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FinGuard',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    home: services.auth == null
        ? HomeScreen(services: services)
        : AuthGate(services: services),
  );
}
