import 'package:flutter/material.dart';

import '../models/trusted_contact.dart';
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
  TrustedContact? _trustedContact;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onChanged);
    _loadTrustedContact();
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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Trusted contact',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    if (_trustedContact
                        case final TrustedContact contact) ...<Widget>[
                      Text(
                        contact.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        contact.maskedPhone,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.inkMuted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          OutlinedButton(
                            key: const Key('edit_trusted_contact_button'),
                            onPressed: _editTrustedContact,
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            key: const Key('remove_trusted_contact_button'),
                            onPressed: _removeTrustedContact,
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    ] else ...<Widget>[
                      const Text(
                        'Save one person you trust for a faster, user-confirmed WhatsApp or SMS handoff during a suspicious payment.',
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: const Key('add_trusted_contact_button'),
                        onPressed: _editTrustedContact,
                        child: const Text('Save a trusted contact'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const PrivacyNote(
                      text:
                          'The name and phone number stay on this device and are never sent to the FinGuard API.',
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

  Future<void> _loadTrustedContact() async {
    final TrustedContact? contact = await widget.services.store
        .trustedContact();
    if (!mounted) {
      return;
    }
    setState(() => _trustedContact = contact);
  }

  Future<void> _editTrustedContact() async {
    final TrustedContact? contact = await showTrustedContactEditor(
      context,
      initial: _trustedContact,
    );
    if (contact == null || !mounted) {
      return;
    }
    await widget.services.store.setTrustedContact(contact);
    if (!mounted) {
      return;
    }
    setState(() => _trustedContact = contact);
  }

  Future<void> _removeTrustedContact() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Remove trusted contact?',
      message:
          'This removes the locally stored name and phone number from this device.',
      confirmLabel: 'Remove contact',
      isDanger: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await widget.services.store.clearTrustedContact();
    if (!mounted) {
      return;
    }
    setState(() => _trustedContact = null);
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
    bool attempted = false;
    final bool needsPassword = _auth.user?.authProvider == 'password';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          final bool phraseValid = confirmationInput.trim() == 'DELETE';
          final bool passwordValid = !needsPassword || passwordInput.isNotEmpty;
          return AlertDialog(
            scrollable: true,
            title: const Text('Delete your account?'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'This permanently removes your FinGuard identity and active sessions. Local payment history can still be cleared separately on this device.',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('delete_confirmation_field'),
                  onChanged: (String value) =>
                      setDialogState(() => confirmationInput = value),
                  decoration: InputDecoration(
                    labelText: 'Type DELETE',
                    errorText:
                        (attempted || confirmationInput.isNotEmpty) &&
                            !phraseValid
                        ? 'Type DELETE exactly to continue.'
                        : null,
                  ),
                ),
                if (needsPassword) ...<Widget>[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('delete_password_field'),
                    onChanged: (String value) =>
                        setDialogState(() => passwordInput = value),
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      errorText: attempted && !passwordValid
                          ? 'Enter your password to continue.'
                          : null,
                    ),
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
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: () {
                  if (confirmationInput.trim() == 'DELETE' &&
                      (!needsPassword || passwordInput.isNotEmpty)) {
                    Navigator.of(dialogContext).pop(true);
                    return;
                  }
                  setDialogState(() => attempted = true);
                },
                child: const Text('Delete permanently'),
              ),
            ],
          );
        },
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
