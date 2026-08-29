import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

enum AuthFormMode { login, register }

class AuthFormScreen extends StatefulWidget {
  const AuthFormScreen({required this.services, required this.mode, super.key});

  final AppServices services;
  final AuthFormMode mode;

  @override
  State<AuthFormScreen> createState() => _AuthFormScreenState();
}

class _AuthFormScreenState extends State<AuthFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();
  late final AuthController _auth = widget.services.auth!;
  bool _obscurePassword = true;

  bool get _registering => widget.mode == AuthFormMode.register;

  @override
  void initState() {
    super.initState();
    _auth.clearError();
    _auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) {
      return;
    }
    if (_auth.status == AuthStatus.authenticated) {
      Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_registering ? 'Create account' : 'Sign in')),
    body: PageBody(
      maxWidth: 520,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              _registering ? 'Build your FinGuard account' : 'Welcome back',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              _registering
                  ? 'Your password is hashed before storage. FinGuard never asks for a bank password, UPI PIN or OTP.'
                  : 'Sign in to restore your FinGuard identity. Payment authorization still happens only in your UPI app.',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 28),
            if (_registering) ...<Widget>[
              TextFormField(
                key: const Key('display_name_field'),
                controller: _nameController,
                enabled: !_auth.busy,
                textInputAction: TextInputAction.next,
                autofillHints: const <String>[AutofillHints.name],
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (String? value) => (value?.trim().length ?? 0) < 2
                    ? 'Enter at least 2 characters.'
                    : null,
              ),
              const SizedBox(height: 16),
            ],
            TextFormField(
              key: const Key('email_field'),
              controller: _emailController,
              enabled: !_auth.busy,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const <String>[AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email address'),
              validator: _validateEmail,
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('password_field'),
              controller: _passwordController,
              enabled: !_auth.busy,
              obscureText: _obscurePassword,
              textInputAction: _registering
                  ? TextInputAction.next
                  : TextInputAction.done,
              autofillHints: <String>[
                _registering
                    ? AutofillHints.newPassword
                    : AutofillHints.password,
              ],
              onFieldSubmitted: _registering ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: _registering
                    ? 'At least 10 characters, including a letter and number.'
                    : null,
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: _validatePassword,
            ),
            if (_registering) ...<Widget>[
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('confirm_password_field'),
                controller: _confirmationController,
                enabled: !_auth.busy,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const <String>[AutofillHints.newPassword],
                onFieldSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
                ),
                validator: (String? value) => value != _passwordController.text
                    ? 'Passwords do not match.'
                    : null,
              ),
            ],
            if (_auth.error != null) ...<Widget>[
              const SizedBox(height: 18),
              ErrorNotice(message: _auth.error!, onRetry: _auth.clearError),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('submit_auth_button'),
              onPressed: _auth.busy ? null : _submit,
              child: _auth.busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : Text(_registering ? 'Create account' : 'Sign in'),
            ),
            const SizedBox(height: 16),
            const PrivacyNote(
              text:
                  'Account credentials go only to the FinGuard server over HTTPS. Passwords are never placed in payment links or sent to Gemini.',
            ),
          ],
        ),
      ),
    ),
  );

  String? _validateEmail(String? value) {
    final String email = value?.trim() ?? '';
    final int at = email.indexOf('@');
    if (at <= 0 ||
        at == email.length - 1 ||
        !email.substring(at + 1).contains('.')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final String password = value ?? '';
    if (!_registering && password.isEmpty) {
      return 'Enter your password.';
    }
    if (_registering &&
        (password.length < 10 ||
            !password.contains(RegExp('[A-Za-z]')) ||
            !password.contains(RegExp('[0-9]')))) {
      return 'Use 10+ characters with at least one letter and number.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_registering) {
      await _auth.register(
        email: _emailController.text,
        password: _passwordController.text,
        displayName: _nameController.text,
      );
    } else {
      await _auth.login(
        email: _emailController.text,
        password: _passwordController.text,
      );
    }
  }
}
