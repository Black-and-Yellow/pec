import 'package:flutter/material.dart';

import '../models/context_analysis.dart';
import '../models/history_entry.dart';
import '../models/intent_shield.dart';
import '../models/payment.dart';
import '../models/risk.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../services/threat_environment.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'risk_result_screen.dart';

class PasteScreen extends StatefulWidget {
  const PasteScreen({
    required this.services,
    super.key,
    this.initialUri,
    this.contextAnalysis,
    this.consentToExternalAi = false,
    this.analyzeImmediately = false,
  });

  final AppServices services;
  final String? initialUri;
  final ContextAnalysis? contextAnalysis;
  final bool consentToExternalAi;
  final bool analyzeImmediately;

  @override
  State<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends State<PasteScreen> {
  late final TextEditingController _controller;
  bool _loading = false;

  /// What the user says they expect. Optional, and never scored: it is
  /// compared against what the request does, and a mismatch means the person
  /// was told something untrue, not that the payee is a fraudster.
  PaymentIntent? _intent;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUri);
    if (widget.analyzeImmediately) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _analyze());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Check UPI link')),
    body: PageBody(
      maxWidth: 820,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'PAYMENT CHECK  /  1 OF 2',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.tealDark,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Review before handoff',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'FinGuard accepts only standard upi://pay requests. It will parse and score the request without opening it.',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 26),
          TextField(
            key: const Key('upi_uri_field'),
            controller: _controller,
            enabled: !_loading,
            autofocus: widget.initialUri == null,
            minLines: 3,
            maxLines: 5,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _analyze(),
            decoration: const InputDecoration(
              labelText: 'UPI payment link',
              hintText: 'upi://pay?pa=merchant@upi&pn=Merchant&am=180&cu=INR',
              alignLabelWithHint: true,
            ),
          ),
          if (widget.contextAnalysis?.hasValidatedContext == true) ...<Widget>[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: const Border(
                  left: BorderSide(color: AppColors.teal, width: 3),
                ),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.message_outlined, color: AppColors.tealDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Suspicious-message context will be included in this risk check.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 16),
            ErrorNotice(
              message: _error!,
              onRetry: _loading ? null : _analyze,
              secondary: TextButton(
                onPressed: _loading ? null : _openHighRiskDemo,
                child: const Text('Use reliable demo'),
              ),
            ),
          ],
          const SizedBox(height: 22),
          _IntentPicker(
            selected: _intent,
            enabled: !_loading,
            onChanged: (PaymentIntent? value) =>
                setState(() => _intent = value),
          ),
          const SizedBox(height: 22),
          AsyncFilledButton(
            buttonKey: const Key('analyze_payment_button'),
            loading: _loading,
            onPressed: _analyze,
            icon: Icons.policy_outlined,
            label: 'Analyze payment',
            loadingLabel: 'Checking request…',
            loadingSemanticsLabel: 'Checking request',
          ),
          const SizedBox(height: 16),
          const PrivacyNote(
            text:
                'Your payment request and anonymous device identifier are sent to FinGuard for scoring and short-lived assessment records. FinGuard never asks for bank credentials or a UPI PIN.',
          ),
        ],
      ),
    ),
  );

  Future<void> _analyze() async {
    if (_loading) {
      return;
    }
    final String raw = _controller.text;
    try {
      Payment.validateUpiUri(raw);
    } on FormatException catch (error) {
      setState(() => _error = error.message.toString());
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ContextAnalysis? validatedContext =
          widget.contextAnalysis?.hasValidatedContext == true
          ? widget.contextAnalysis
          : null;
      final Payment payment = await widget.services.api.parsePayment(raw);
      final String deviceId = await widget.services.store.deviceId();
      // Read the device environment at check time so the deterministic policy
      // can weigh an active remote-access tool and a live call alongside the
      // payment signals. Both are single readings taken now, not subscriptions:
      // a call that starts after this result is on screen is invisible to us.
      final List<String> remoteAccessTools = await widget
          .services
          .threatEnvironment
          .remoteAccessTools();
      final CallActivity callActivity = await widget.services.threatEnvironment
          .callActivity();
      final RiskScoreResult scoreResult = await widget.services.api
          .scorePayment(
            payment: payment,
            deviceId: deviceId,
            context: validatedContext,
            remoteAccessTools: remoteAccessTools,
            callActivity: callActivity,
            intent: _intent,
          );
      final Payment validatedPayment = scoreResult.payment;
      final RiskAssessment assessment = scoreResult.assessment;
      final DateTime checkedAt = scoreResult.assessedAt;
      try {
        await widget.services.store.addHistory(
          HistoryEntry(
            id: 'check_${checkedAt.microsecondsSinceEpoch}',
            checkedAt: checkedAt,
            payment: validatedPayment,
            assessment: assessment,
          ),
        );
      } on Object {
        // Local history is optional; a storage failure must not hide a risk result.
      }
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
      await Navigator.pushReplacement<void, void>(
        context,
        MaterialPageRoute<void>(
          builder: (BuildContext context) => RiskResultScreen(
            services: widget.services,
            payment: validatedPayment,
            assessment: assessment,
            payeeTrust: scoreResult.payeeTrust,
            intentShield: scoreResult.intentShield,
            paymentHandoffEnabled: scoreResult.paymentHandoffEnabled,
            contextAnalysis: validatedContext,
            consentToExternalAi: widget.consentToExternalAi,
          ),
        ),
      );
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

  Future<void> _openHighRiskDemo() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final DemoScenario scenario = await widget.services.demos.load('fake-kyc');
    if (!mounted) {
      return;
    }
    final DateTime checkedAt = DateTime.now();
    try {
      await widget.services.store.addHistory(
        HistoryEntry(
          id: 'demo_${checkedAt.microsecondsSinceEpoch}',
          checkedAt: checkedAt,
          payment: scenario.payment,
          assessment: scenario.assessment,
          isDemo: true,
        ),
      );
    } on Object {
      // The bundled demonstration remains available if local storage is blocked.
    }
    if (!mounted) {
      return;
    }
    setState(() => _loading = false);
    await Navigator.pushReplacement<void, void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => RiskResultScreen(
          services: widget.services,
          payment: scenario.payment,
          assessment: scenario.assessment,
          paymentHandoffEnabled: false,
          isDemo: true,
        ),
      ),
    );
  }
}

/// Asks what the user believes this request will do, before it is analysed.
///
/// Optional on purpose. Somebody who just wants a verdict should not be made
/// to answer a question first, and an unanswered picker produces no warning
/// rather than a default assumption.
class _IntentPicker extends StatelessWidget {
  const _IntentPicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final PaymentIntent? selected;
  final bool enabled;
  final ValueChanged<PaymentIntent?> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('intent_picker'),
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'What do you expect this to do?',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 3),
        Text(
          'Optional. This never changes the risk score - it only checks your '
          'expectation against what the request actually does.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.inkMuted,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final PaymentIntent intent in PaymentIntent.values)
              ChoiceChip(
                key: Key('intent_${intent.apiValue}'),
                label: Text(intent.label),
                selected: selected == intent,
                onSelected: enabled
                    ? (bool value) => onChanged(value ? intent : null)
                    : null,
              ),
          ],
        ),
      ],
    ),
  );
}
