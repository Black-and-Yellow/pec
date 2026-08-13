import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final AuthController _auth = widget.services.auth!;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool guest = _auth.status == AuthStatus.guest;
    final user = _auth.user;
    return Scaffold(
      appBar: AppBar(title: const Text('Account & privacy')),
      body: PageBody(
        maxWidth: 680,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              guest
                  ? 'Private guest mode'
                  : user?.displayName ?? 'FinGuard account',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              guest
                  ? 'Payment checks and local history remain available without attaching your identity.'
                  : user?.email ?? '',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 26),
            if (_auth.error != null) ...<Widget>[
              ErrorNotice(message: _auth.error!, onRetry: _auth.clearError),
              const SizedBox(height: 20),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Privacy boundary',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'FinGuard never requests your UPI PIN, bank password, OTP or payment-app credentials. An account identifies your FinGuard session; it does not grant access to your bank.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (guest)
              FilledButton(
                key: const Key('leave_guest_button'),
                onPressed: _auth.busy ? null : _leaveGuest,
                child: const Text('Create or sign in to an account'),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('logout_button'),
                    onPressed: _auth.busy ? null : _signOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out on this device'),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    key: const Key('delete_account_button'),
                    onPressed: _auth.busy ? null : _confirmDelete,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete account permanently'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _leaveGuest() async {
    await _auth.leaveGuestMode();
    if (mounted) {
      Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
    }
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (mounted) {
      Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
    }
  }

  Future<void> _confirmDelete() async {
    String confirmationInput = '';
    String passwordInput = '';
    final bool needsPassword = _auth.user?.authProvider == 'password';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'This permanently removes your FinGuard identity and active sessions. Local payment history can still be cleared separately on this device.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('delete_confirmation_field'),
              onChanged: (String value) => confirmationInput = value,
              decoration: const InputDecoration(labelText: 'Type DELETE'),
            ),
            if (needsPassword) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                key: const Key('delete_password_field'),
                onChanged: (String value) => passwordInput = value,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            key: const Key('confirm_delete_account_button'),
            onPressed: () => Navigator.of(dialogContext).pop(
              confirmationInput.trim() == 'DELETE' &&
                  (!needsPassword || passwordInput.isNotEmpty),
            ),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final bool deleted = await _auth.deleteAccount(
      password: needsPassword ? passwordInput : null,
    );
    if (deleted && mounted) {
      Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
    }
  }
}
