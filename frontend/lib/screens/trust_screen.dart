import 'package:flutter/material.dart';

import '../models/payee_trust.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/trust_report.dart';

/// Look up a UPI ID's standing before any payment request exists.
///
/// This is the "check them before you deal with them" surface: a seller sends
/// their UPI ID over chat, and the buyer can read its reputation without a QR,
/// without an amount, and without handing anything to a UPI app.
class TrustScreen extends StatefulWidget {
  const TrustScreen({required this.services, super.key, this.initialVpa});

  final AppServices services;
  final String? initialVpa;

  @override
  State<TrustScreen> createState() => _TrustScreenState();
}

class _TrustScreenState extends State<TrustScreen> {
  late final TextEditingController _controller;
  bool _loading = false;
  String? _error;
  PayeeTrust? _trust;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialVpa);
    if ((widget.initialVpa ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookup());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Check a UPI ID')),
    body: PageBody(
      maxWidth: 820,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'PAYEE REPUTATION',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.tealDark,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Who is behind this UPI ID?',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'Paste a UPI ID to see how long the FinGuard network has known it, how '
            'many people have paid it, and what the address itself gives away. '
            'Nothing is paid and no UPI app is opened.',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const Key('trust_vpa_field'),
            controller: _controller,
            enabled: !_loading,
            autofocus: widget.initialVpa == null,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _lookup(),
            decoration: const InputDecoration(
              labelText: 'UPI ID',
              hintText: 'name@handle',
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 16),
            ErrorNotice(message: _error!, onRetry: _loading ? null : _lookup),
          ],
          const SizedBox(height: 20),
          AsyncFilledButton(
            buttonKey: const Key('lookup_trust_button'),
            loading: _loading,
            onPressed: _lookup,
            icon: Icons.travel_explore_outlined,
            label: 'Check reputation',
            loadingLabel: 'Checking…',
            loadingSemanticsLabel: 'Checking reputation',
          ),
          if (_trust case final PayeeTrust trust) ...<Widget>[
            const SizedBox(height: 26),
            TrustReportCard(trust: trust, initiallyExpanded: true),
          ],
          const SizedBox(height: 18),
          const PrivacyNote(
            text:
                'A lookup is a read. It does not add to the address’s record, so '
                'nobody can build a reputation for a scam ID by querying it repeatedly.',
          ),
        ],
      ),
    ),
  );

  Future<void> _lookup() async {
    if (_loading) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PayeeTrust trust = await widget.services.api.lookupPayeeTrust(
        _controller.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _trust = trust;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.toString();
      });
    }
  }
}
