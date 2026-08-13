import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/google_web_button.dart';
import 'auth_form_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final AuthController _auth = widget.services.auth!;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
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
  Widget build(BuildContext context) => Scaffold(
    body: PageBody(
      maxWidth: 1060,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= 780;
          final Widget introduction = const _WelcomeIntroduction();
          final Widget actions = _WelcomeActions(
            services: widget.services,
            auth: _auth,
          );
          return Center(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(flex: 6, child: introduction),
                      const SizedBox(width: 72),
                      Expanded(flex: 5, child: actions),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      introduction,
                      const SizedBox(height: 36),
                      actions,
                    ],
                  ),
          );
        },
      ),
    ),
  );
}

class _WelcomeIntroduction extends StatelessWidget {
  const _WelcomeIntroduction();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      const FinGuardBrand(),
      const SizedBox(height: 34),
      Text(
        'Check before you pay.',
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 18),
      Text(
        'FinGuard explains warning signals in a UPI request before handing it to your payment app. You stay in control of every action.',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: AppColors.inkMuted,
          height: 1.55,
        ),
      ),
      const SizedBox(height: 28),
      const Wrap(
        spacing: 18,
        runSpacing: 12,
        children: <Widget>[
          _TrustPoint(icon: Icons.rule_outlined, label: 'Deterministic score'),
          _TrustPoint(
            icon: Icons.visibility_outlined,
            label: 'Explainable evidence',
          ),
          _TrustPoint(icon: Icons.lock_outline, label: 'No bank credentials'),
        ],
      ),
    ],
  );
}

class _TrustPoint extends StatelessWidget {
  const _TrustPoint({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(icon, size: 19, color: AppColors.tealDark),
      const SizedBox(width: 7),
      Text(label),
    ],
  );
}

class _WelcomeActions extends StatelessWidget {
  const _WelcomeActions({required this.services, required this.auth});

  final AppServices services;
  final AuthController auth;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Start with FinGuard',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 7),
          Text(
            'Create an account for a persistent identity, or continue privately for a one-device safety check.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          if (auth.error != null) ...<Widget>[
            const SizedBox(height: 16),
            ErrorNotice(
              message: auth.error!,
              onRetry: auth.canRetrySessionRestore
                  ? () => auth.initialize()
                  : auth.clearError,
            ),
          ],
          const SizedBox(height: 22),
          FilledButton(
            key: const Key('create_account_button'),
            onPressed: auth.busy
                ? null
                : () => _openForm(context, AuthFormMode.register),
            child: const Text('Create account'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('sign_in_button'),
            onPressed: auth.busy
                ? null
                : () => _openForm(context, AuthFormMode.login),
            child: const Text('Sign in'),
          ),
          if (auth.googleEnabled) ...<Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 15),
              child: Row(
                children: <Widget>[
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('OR'),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.android)
              OutlinedButton.icon(
                key: const Key('google_sign_in_button'),
                onPressed: auth.busy ? null : auth.signInWithGoogle,
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('Continue with Google'),
              )
            else
              Center(child: buildGoogleWebButton()),
          ],
          const SizedBox(height: 10),
          TextButton(
            key: const Key('continue_guest_button'),
            onPressed: auth.busy ? null : auth.continueAsGuest,
            child: const Text('Continue privately without an account'),
          ),
          const SizedBox(height: 4),
          Text(
            'Guest mode keeps the useful assessment list on this device. It does not weaken payment checks.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    ),
  );

  Future<void> _openForm(BuildContext context, AuthFormMode mode) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            AuthFormScreen(services: services, mode: mode),
      ),
    );
  }
}
