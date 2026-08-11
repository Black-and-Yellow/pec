import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'home_screen.dart';
import 'welcome_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({required this.services, super.key});

  final AppServices services;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final AuthController _auth = widget.services.auth!;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _auth.initialize();
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => switch (_auth.status) {
    AuthStatus.loading => const _AuthLoadingScreen(),
    AuthStatus.signedOut => WelcomeScreen(services: widget.services),
    AuthStatus.guest ||
    AuthStatus.authenticated => HomeScreen(services: widget.services),
  };
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: PageBody(
      maxWidth: 520,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FinGuardBrand(),
            SizedBox(height: 28),
            CircularProgressIndicator(color: AppColors.teal),
            SizedBox(height: 14),
            Text('Restoring your secure session…'),
          ],
        ),
      ),
    ),
  );
}
