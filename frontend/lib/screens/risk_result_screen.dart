import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/context_analysis.dart';
import '../models/payee_trust.dart';
import '../models/payment.dart';
import '../models/risk.dart';
import '../models/risk_explanation.dart';
import '../models/trusted_contact.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../services/report_builder.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/trust_report.dart';
import 'incident_screen.dart';

class RiskResultScreen extends StatefulWidget {
  const RiskResultScreen({
    required this.services,
    required this.payment,
    required this.assessment,
    required this.paymentHandoffEnabled,
    super.key,
    this.payeeTrust,
    this.contextAnalysis,
    this.consentToExternalAi = false,
    this.isDemo = false,
  });

  final AppServices services;
  final Payment payment;
  final RiskAssessment assessment;

  /// Absent for saved history entries and bundled demos, which were not
  /// scored against the live reputation ledger.
  final PayeeTrust? payeeTrust;

  final bool paymentHandoffEnabled;
  final ContextAnalysis? contextAnalysis;
  final bool consentToExternalAi;
  final bool isDemo;

  @override
  State<RiskResultScreen> createState() => _RiskResultScreenState();
}

class _RiskResultScreenState extends State<RiskResultScreen> {
  /// Used when no live trust report exists: saved history entries and bundled
  /// demos were never scored against the ledger, so they keep the original
  /// fixed pause rather than inheriting a grade they never earned.
  static const int _unratedCoolOffSeconds = 10;

  /// The shortest pause any high-risk result may impose.
  ///
  /// The pause exists only for HIGH verdicts, so letting a good grade drive it
  /// to zero would switch the safeguard off in the case that needs it most: a
  /// trusted merchant whose QR was swapped, or a payer being talked into
  /// sending money to an ordinary-looking account. A well-regarded payee and a
  /// dangerous payment are different claims, and reputation cannot answer the
  /// second one.
  static const int _minimumCoolOffSeconds = 5;

  /// How long the deliberate pause lasts, scaled by what the network knows
  /// about the recipient.
  ///
  /// A stranger earns a longer stop than an address hundreds of payers have
  /// used without incident. Scammers rely on speed, so the less FinGuard can
  /// say about who is being paid, the more deliberate the last step becomes —
  /// but never less than [_minimumCoolOffSeconds], because the verdict that
  /// triggered this pause was reached on evidence the payee's record does not
  /// override.
  int get _coolOffSeconds => switch (widget.payeeTrust?.grade) {
    TrustGrade.aPlus || TrustGrade.a => _minimumCoolOffSeconds,
    TrustGrade.b => 5,
    TrustGrade.isNew => 10,
    TrustGrade.c => 15,
    TrustGrade.d => 20,
    null => _unratedCoolOffSeconds,
  };

  bool _preparingReport = false;
  final Set<_VerificationCheck> _completedVerifications =
      <_VerificationCheck>{};
  Timer? _coolOffTimer;
  late int _coolOffRemaining;
  TrustedContact? _trustedContact;
  late RiskExplanation _explanation;
  RiskExplanation? _aiWording;

  @override
  void initState() {
    super.initState();
    _coolOffRemaining = _coolOffSeconds;
    _explanation = RiskExplanation(
      available: true,
      source: RiskExplanationSource.template,
      status: 'generated',
      explanation: ReportBuilder.plainLanguageExplanation(widget.assessment),
    );
    if (widget.assessment.level == RiskLevel.highRisk) {
      // A brief, permission-free cue that registers before the user has
      // read anything — deliberately fired once, not on every rebuild.
      unawaited(HapticFeedback.heavyImpact());
    }
    if (!widget.isDemo) {
      unawaited(_loadTrustedContact());
      if (widget.assessment.assessmentId != null) {
        unawaited(_loadExplanation());
      }
    }
  }

  bool get _requiresIndependentVerification =>
      widget.paymentHandoffEnabled && widget.assessment.level != RiskLevel.safe;

  bool get _independentVerificationComplete =>
      !_requiresIndependentVerification ||
      _completedVerifications.length == _VerificationCheck.values.length;

  bool get _requiresCoolOff =>
      widget.paymentHandoffEnabled &&
      widget.assessment.level == RiskLevel.highRisk;

  bool get _coolOffComplete => !_requiresCoolOff || _coolOffRemaining == 0;

  /// Whether this result gives the user a reason to consult the national
  /// register: an adverse payee grade, a mule-shaped ledger, or a top-band
  /// verdict. A safe result does not, and offering it there would dilute the
  /// prompt everywhere it matters.
  bool get _warrantsRegistryCheck =>
      (widget.payeeTrust?.isAdverse ?? false) ||
      widget.assessment.level == RiskLevel.highRisk ||
      widget.assessment.signals.any(
        (RiskSignal signal) => signal.code == 'MULE_ACCOUNT_SIGNATURE',
      );

  /// The name the request claims, when the server has told us it is a claim.
  ///
  /// The signal is what licenses the card: FinGuard cannot read the bank's
  /// registered name, so it only ever says this out loud when the scoring
  /// policy has flagged the name as unverifiable. Null means say nothing.
  String? get _claimedPayeeName {
    final bool unverified = widget.assessment.signals.any(
      (RiskSignal signal) => signal.code == 'PAYEE_NAME_UNVERIFIED',
    );
    if (!unverified) {
      return null;
    }
    final String claimed = widget.payment.payeeName?.trim() ?? '';
    return claimed.isEmpty ? null : claimed;
  }

  @override
  void dispose() {
    _coolOffTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width >= 900;
    // Plain language first, the numeric score second: the target user is
    // often reading this under stress, not auditing a scoring model.
    // Payment facts and the full signal breakdown are one tap away rather
    // than pre-scrolled past, so the actual decision (stop / continue) is
    // reachable without wading through detail the user already has.
    final Widget result = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ResultHeader(assessment: widget.assessment, isDemo: widget.isDemo),
        const SizedBox(height: 16),
        _ExplanationCard(explanation: _explanation, aiWording: _aiWording),
        const SizedBox(height: 18),
        _ScoreSummary(assessment: widget.assessment),
        if (widget.payeeTrust case final PayeeTrust trust) ...<Widget>[
          const SizedBox(height: 22),
          TrustReportCard(
            trust: trust,
            // An adverse grade opens already: the reason is the point, and
            // burying it behind a tap on the one screen that matters would
            // be the same as not showing it.
            initiallyExpanded: trust.isAdverse,
          ),
          // Offered only where there is a reason to look. Inviting a check of
          // the national fraud register on every ordinary payment would train
          // people to tap past it, which is the opposite of the point.
          if (_warrantsRegistryCheck) ...<Widget>[
            const SizedBox(height: 14),
            SuspectRegistryCard(
              vpa: trust.vpa,
              onCopy: widget.services.externalActions.copyText,
              onOpenRegistry:
                  widget.services.externalActions.openSuspectRegistry,
            ),
          ],
        ],
        const SizedBox(height: 24),
        CollapsibleSection(
          title: 'Payment details',
          headerKey: const Key('payment_details_toggle'),
          child: _PaymentDetails(payment: widget.payment),
        ),
        if (_claimedPayeeName case final String claimed) ...<Widget>[
          const SizedBox(height: 18),
          _PayeeNameClaimCard(claimedName: claimed),
        ],
        const SizedBox(height: 14),
        CollapsibleSection(
          title: 'Why do we say this?',
          subtitle: widget.assessment.signals.isEmpty
              ? 'No warning signals'
              : '${widget.assessment.signals.length} signal(s)',
          headerKey: const Key('why_this_score_toggle'),
          child: _SignalListContent(assessment: widget.assessment),
        ),
      ],
    );
    final bool showQuickStop =
        !wide &&
        widget.paymentHandoffEnabled &&
        widget.assessment.level != RiskLevel.safe;
    final Widget actions = _ActionPanel(
      assessment: widget.assessment,
      paymentHandoffEnabled: widget.paymentHandoffEnabled,
      isDemo: widget.isDemo,
      preparingReport: _preparingReport,
      completedVerifications: _completedVerifications,
      canContinue: _independentVerificationComplete && _coolOffComplete,
      coolOffRemaining: _requiresCoolOff ? _coolOffRemaining : 0,
      trustedContact: _trustedContact,
      onStop: _stopHere,
      onContinue: _continue,
      onVerificationChanged: _setVerification,
      onVerify: _showVerificationGuidance,
      onPrepareReport: () => _prepareReport(alreadyPaid: false),
      onShare: _shareTrustedContact,
      onMessageTrustedContact: _messageTrustedContact,
      onSaveTrustedContact: _saveTrustedContact,
      onAlreadyPaid: () => _prepareReport(alreadyPaid: true),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Risk result'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Close result',
            onPressed: _stopHere,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PageBody(
        maxWidth: 1080,
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 7, child: result),
                  const SizedBox(width: 36),
                  Expanded(flex: 4, child: actions),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[result, const SizedBox(height: 28), actions],
              ),
      ),
      bottomNavigationBar: showQuickStop
          ? _QuickStopBar(
              isHighRisk: widget.assessment.level == RiskLevel.highRisk,
              onStop: _stopHere,
            )
          : null,
    );
  }

  void _stopHere() {
    Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
  }

  Future<void> _loadExplanation() async {
    final String? assessmentId = widget.assessment.assessmentId;
    if (assessmentId == null) {
      return;
    }
    try {
      final RiskExplanation explanation = await widget.services.api
          .explainAssessment(
            assessmentId: assessmentId,
            consent: widget.consentToExternalAi,
          );
      if (mounted && explanation.available && explanation.isAiAssisted) {
        setState(() => _aiWording = explanation);
      }
    } on Object {
      // The immediate local template remains the offline and failure fallback.
    }
  }

  Future<void> _continue() async {
    if (!widget.paymentHandoffEnabled) {
      return;
    }
    final RiskLevel level = widget.assessment.level;
    if (level != RiskLevel.safe &&
        (!_independentVerificationComplete || !_coolOffComplete)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text(
              !_independentVerificationComplete
                  ? 'Complete the independent verification checklist first.'
                  : 'Wait for the deliberate cooling-off pause to finish.',
            ),
          ),
        );
      }
      return;
    }
    final bool confirmed = await confirmAction(
      context,
      title: switch (level) {
        RiskLevel.safe => 'Open this request in a UPI app?',
        RiskLevel.caution => 'Continue with caution?',
        RiskLevel.highRisk => 'Continue despite high risk?',
      },
      message: switch (level) {
        RiskLevel.safe =>
          'FinGuard will hand the validated request to a UPI app. Review the recipient and amount there before authorizing anything.',
        RiskLevel.caution =>
          'Verify the recipient independently first. Continuing will open your UPI app, where you remain responsible for reviewing and authorizing payment.',
        RiskLevel.highRisk =>
          'FinGuard found strong warning signals. Continuing will hand this request to a UPI app; FinGuard cannot stop or reverse a payment made there.',
      },
      confirmLabel: level == RiskLevel.safe
          ? 'Open UPI app'
          : 'Open UPI app anyway',
      isDanger: level == RiskLevel.highRisk,
      icon: level == RiskLevel.highRisk
          ? Icons.warning_amber_outlined
          : Icons.open_in_new,
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await widget.services.externalActions.openUpi(widget.payment.upiUri);
    } on Object catch (error) {
      if (mounted) {
        showActionError(context, error);
      }
    }
  }

  void _setVerification(_VerificationCheck check, bool selected) {
    setState(() {
      if (selected) {
        _completedVerifications.add(check);
      } else {
        _completedVerifications.remove(check);
      }
      if (_requiresCoolOff && !_independentVerificationComplete) {
        _coolOffTimer?.cancel();
        _coolOffTimer = null;
        _coolOffRemaining = _coolOffSeconds;
      }
    });
    // A zero-length pause needs no timer: starting one would tick straight
    // past zero and rebuild the screen for nothing.
    if (_requiresCoolOff &&
        _coolOffSeconds > 0 &&
        _independentVerificationComplete &&
        _coolOffTimer == null) {
      _coolOffTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _coolOffRemaining--;
          if (_coolOffRemaining <= 0) {
            _coolOffRemaining = 0;
            timer.cancel();
          }
        });
      });
    }
  }

  Future<void> _showVerificationGuidance() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Check the recipient independently'),
        content: Text(
          'Confirm ${widget.payment.payeeVpa} using a phone number, website or in-person contact you already trust. Do not use contact details from the suspicious message.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  // No confirmation dialog here: the OS share sheet the user is about to
  // see is itself a confirmation surface (they still pick an app and a
  // contact there), so a modal in front of it would be a second gate for
  // one decision — exactly the fatigue pattern that trains people to tap
  // through dialogs without reading the ones that actually matter.
  Future<void> _shareTrustedContact() async {
    try {
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final Rect? origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await widget.services.externalActions.shareTrustedContact(
        ReportBuilder.trustedContactMessage(widget.payment, widget.assessment),
        origin: origin,
      );
    } on Object catch (error) {
      if (mounted) {
        showActionError(context, error);
      }
    }
  }

  Future<void> _loadTrustedContact() async {
    final TrustedContact? contact = await widget.services.store
        .trustedContact();
    if (!mounted) {
      return;
    }
    setState(() => _trustedContact = contact);
  }

  Future<void> _saveTrustedContact() async {
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

  // No confirmation dialog: the button itself already reads "Alert {name}
  // on WhatsApp" — that label is the confirmation — and WhatsApp/SMS still
  // requires the user to press Send there before anything actually goes.
  Future<void> _messageTrustedContact() async {
    final TrustedContact? contact = _trustedContact;
    if (contact == null) {
      return;
    }
    try {
      await widget.services.externalActions.messageTrustedContact(
        contact.phone,
        ReportBuilder.trustedContactMessage(widget.payment, widget.assessment),
      );
    } on Object catch (error) {
      if (mounted) {
        showActionError(context, error);
      }
    }
  }

  // No confirmation dialog: preparing a draft is fully local and reversible
  // (nothing external happens until the incident screen's own copy/share/
  // open-portal actions, which each keep their own confirmation).
  Future<void> _prepareReport({required bool alreadyPaid}) async {
    if (_preparingReport) {
      return;
    }
    setState(() => _preparingReport = true);
    bool preparedLocally = widget.isDemo;
    String report;
    if (widget.isDemo) {
      report = _buildLocalReport(alreadyPaid: alreadyPaid);
    } else {
      try {
        report = await widget.services.api.prepareResponse(
          payment: widget.payment,
          assessment: widget.assessment,
          alreadyPaid: alreadyPaid,
          context: widget.contextAnalysis,
        );
      } on ApiException {
        preparedLocally = true;
        report = _buildLocalReport(alreadyPaid: alreadyPaid);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() => _preparingReport = false);
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => IncidentScreen(
          services: widget.services,
          report: report,
          alreadyPaid: alreadyPaid,
          preparedLocally: preparedLocally,
        ),
      ),
    );
  }

  String _buildLocalReport({required bool alreadyPaid}) => ReportBuilder.build(
    payment: widget.payment,
    assessment: widget.assessment,
    occurredAt: DateTime.now(),
    alreadyPaid: alreadyPaid,
    context: widget.contextAnalysis,
  );
}

enum _VerificationCheck {
  recipient(
    'verify_recipient_checkbox',
    'I checked the recipient VPA using a source I trust.',
  ),
  amount('verify_amount_checkbox', 'I reviewed the amount and currency.'),
  independentContact(
    'verify_independent_contact_checkbox',
    'I ignored urgency and contact instructions in this request and verified independently.',
  );

  const _VerificationCheck(this.keyName, this.label);

  final String keyName;
  final String label;
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({required this.assessment, required this.isDemo});

  final RiskAssessment assessment;
  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final String headline = switch (assessment.level) {
      RiskLevel.safe => 'No strong warning signal found',
      RiskLevel.caution => 'Pause and verify the recipient',
      RiskLevel.highRisk => 'Strong warning signals found',
    };
    return Semantics(
      header: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _statusSurface(assessment.level),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                RiskBadge(level: assessment.level),
                if (isDemo)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface.withValues(alpha: 0.7),
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('SEEDED DEMO DATA'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(headline, style: Theme.of(context).textTheme.headlineMedium),
          ],
        ),
      ),
    );
  }

  Color _statusSurface(RiskLevel level) => switch (level) {
    RiskLevel.safe => AppColors.safeSurface,
    RiskLevel.caution => AppColors.cautionSurface,
    RiskLevel.highRisk => AppColors.dangerSurface,
  };
}

/// The numeric score and recommended action, deliberately smaller and
/// secondary to [_ExplanationCard]'s plain-language sentence — a score out
/// of 100 means little to a first-time or panicking user without the
/// sentence explaining it, so the sentence leads and the number supports it.
class _ScoreSummary extends StatelessWidget {
  const _ScoreSummary({required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(
              '${assessment.score}',
              key: const Key('risk_score'),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: _statusColor(assessment.level),
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '/100',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          assessment.recommendedAction,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    ],
  );

  Color _statusColor(RiskLevel level) => switch (level) {
    RiskLevel.safe => AppColors.safe,
    RiskLevel.caution => AppColors.caution,
    RiskLevel.highRisk => AppColors.danger,
  };
}

class _QuickStopBar extends StatelessWidget {
  const _QuickStopBar({required this.isHighRisk, required this.onStop});

  final bool isHighRisk;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 8,
    color: Theme.of(context).scaffoldBackgroundColor,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('quick_stop_button'),
            style: isHighRisk
                ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                : null,
            onPressed: onStop,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop here'),
          ),
        ),
      ),
    ),
  );
}

class _ExplanationCard extends StatelessWidget {
  const _ExplanationCard({required this.explanation, required this.aiWording});

  final RiskExplanation explanation;
  final RiskExplanation? aiWording;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('plain_language_summary'),
    container: true,
    liveRegion: true,
    label: 'Plain-language summary. ${explanation.explanation}',
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 0, 4),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.border, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'Plain-language summary',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            explanation.explanation,
            key: const Key('plain_language_summary_text'),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 10),
          Text(
            'Generated from the deterministic signals above. The score and verdict come from FinGuard\'s policy engine, not from AI.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
          if (aiWording != null) ...<Widget>[
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Container(
                  key: const Key('ai_assisted_wording_chip'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.tealSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'AI-ASSISTED WORDING',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.tealDark,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                Text(
                  'Optional wording only',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              aiWording!.explanation,
              key: const Key('ai_assisted_wording_text'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Do not use this AI wording instead of the deterministic score, evidence, and recommended action.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ],
      ),
    ),
  );
}

class _PaymentDetails extends StatelessWidget {
  const _PaymentDetails({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 18),
    decoration: const BoxDecoration(
      border: Border.symmetric(horizontal: BorderSide(color: AppColors.border)),
    ),
    child: Wrap(
      spacing: 38,
      runSpacing: 18,
      children: <Widget>[
        _Detail(
          label: 'RECIPIENT',
          value: payment.recipientLabel,
          detail: payment.payeeVpa,
        ),
        _Detail(label: 'AMOUNT', value: payment.formattedAmount),
        if ((payment.note ?? '').isNotEmpty)
          _Detail(label: 'NOTE', value: payment.note!),
        if ((payment.transactionReference ?? '').isNotEmpty)
          _Detail(label: 'REFERENCE', value: payment.transactionReference!),
      ],
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 150, maxWidth: 290),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.inkMuted,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 5),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        if (detail != null) ...<Widget>[
          const SizedBox(height: 2),
          SelectableText(
            detail!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ],
    ),
  );
}

class _SignalListContent extends StatelessWidget {
  const _SignalListContent({required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        'Each displayed weight is a deterministic input to the policy score. No AI assigns the final verdict.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 16),
      if (assessment.signals.isEmpty)
        Text(
          assessment.level == RiskLevel.safe
              ? 'The deterministic policy found no risk-raising signals in this request.'
              : 'No detailed signal was supplied for this assessment. Verify the request independently.',
        )
      else
        for (final RiskSignal signal in assessment.signals)
          _SignalRow(signal: signal),
    ],
  );
}

class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.signal});

  final RiskSignal signal;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 48,
          child: Text(
            signal.weight > 0 ? '+${signal.weight}' : '${signal.weight}',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: signal.weight > 0 ? AppColors.danger : AppColors.safe,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                signal.label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 3),
              Text(
                signal.evidence,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.assessment,
    required this.paymentHandoffEnabled,
    required this.isDemo,
    required this.preparingReport,
    required this.completedVerifications,
    required this.canContinue,
    required this.coolOffRemaining,
    required this.trustedContact,
    required this.onStop,
    required this.onContinue,
    required this.onVerificationChanged,
    required this.onVerify,
    required this.onPrepareReport,
    required this.onShare,
    required this.onMessageTrustedContact,
    required this.onSaveTrustedContact,
    required this.onAlreadyPaid,
  });

  final RiskAssessment assessment;
  final bool paymentHandoffEnabled;
  final bool isDemo;
  final bool preparingReport;
  final Set<_VerificationCheck> completedVerifications;
  final bool canContinue;
  final int coolOffRemaining;
  final TrustedContact? trustedContact;
  final VoidCallback onStop;
  final VoidCallback onContinue;
  final void Function(_VerificationCheck check, bool selected)
  onVerificationChanged;
  final VoidCallback onVerify;
  final VoidCallback onPrepareReport;
  final VoidCallback onShare;
  final VoidCallback onMessageTrustedContact;
  final VoidCallback onSaveTrustedContact;
  final VoidCallback onAlreadyPaid;

  @override
  Widget build(BuildContext context) {
    final bool safe = assessment.level == RiskLevel.safe;
    return WorkspacePanel(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Choose the next step',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              !paymentHandoffEnabled
                  ? 'Payment handoff is unavailable for saved and demo results. Run a fresh check before opening a UPI app.'
                  : safe
                  ? 'FinGuard will hand the validated request to your UPI app. Review the recipient again there.'
                  : 'FinGuard has not opened a UPI app or initiated a payment.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 18),
            if (!paymentHandoffEnabled)
              Container(
                key: const Key('payment_handoff_unavailable'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.lock_outline, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This result is view-only. No UPI app can be opened from it.',
                      ),
                    ),
                  ],
                ),
              )
            else if (safe)
              FilledButton.icon(
                key: const Key('continue_upi_button'),
                onPressed: onContinue,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Continue to UPI app'),
              ),
            if (!safe) ...<Widget>[
              if (!paymentHandoffEnabled) const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('stop_here_button'),
                style: assessment.level == RiskLevel.highRisk
                    ? FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        foregroundColor: Colors.white,
                      )
                    : null,
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop here'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: onVerify,
                icon: const Icon(Icons.person_search_outlined),
                label: const Text('Check recipient'),
              ),
              const SizedBox(height: 10),
              if (paymentHandoffEnabled) ...<Widget>[
                _IndependentVerificationChecklist(
                  completed: completedVerifications,
                  onChanged: onVerificationChanged,
                ),
                const SizedBox(height: 10),
                if (coolOffRemaining > 0) ...<Widget>[
                  Semantics(
                    key: const Key('cool_off_notice'),
                    liveRegion: true,
                    child: const Text(
                      'Take a moment. Scammers rely on speed — this pause is deliberate.',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
              if (assessment.level == RiskLevel.highRisk &&
                  !isDemo) ...<Widget>[
                OutlinedButton.icon(
                  onPressed: preparingReport ? null : onPrepareReport,
                  icon: preparingReport
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.description_outlined),
                  label: const Text('Prepare report'),
                ),
                const SizedBox(height: 10),
                if (trustedContact
                    case final TrustedContact contact) ...<Widget>[
                  FilledButton.icon(
                    key: const Key('message_trusted_contact_button'),
                    onPressed: onMessageTrustedContact,
                    icon: const Icon(Icons.chat_outlined),
                    label: Text('Alert ${contact.name} on WhatsApp'),
                  ),
                  TextButton(
                    onPressed: onShare,
                    child: const Text('Use share sheet instead'),
                  ),
                ] else ...<Widget>[
                  OutlinedButton.icon(
                    onPressed: onShare,
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('Alert trusted contact'),
                  ),
                  TextButton(
                    key: const Key('save_trusted_contact_button'),
                    onPressed: onSaveTrustedContact,
                    child: const Text('Save a trusted contact'),
                  ),
                ],
                const SizedBox(height: 6),
              ],
              if (paymentHandoffEnabled)
                TextButton(
                  key: const Key('continue_anyway_button'),
                  onPressed: canContinue ? onContinue : null,
                  child: Text(
                    coolOffRemaining > 0
                        ? 'Continue anyway (${coolOffRemaining}s)'
                        : 'Continue anyway',
                  ),
                ),
            ],
            if (!isDemo) ...<Widget>[
              const Divider(height: 30),
              TextButton.icon(
                key: const Key('already_paid_button'),
                onPressed: preparingReport ? null : onAlreadyPaid,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('I already paid'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IndependentVerificationChecklist extends StatelessWidget {
  const _IndependentVerificationChecklist({
    required this.completed,
    required this.onChanged,
  });

  final Set<_VerificationCheck> completed;
  final void Function(_VerificationCheck check, bool selected) onChanged;

  @override
  Widget build(BuildContext context) {
    final int completedCount = completed.length;
    final bool isComplete = completedCount == _VerificationCheck.values.length;

    return Material(
      key: const Key('independent_verification_checklist'),
      color: isComplete
          ? AppColors.safe.withValues(alpha: 0.08)
          : AppColors.surfaceMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: isComplete ? AppColors.safe : AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Verify before continuing',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              'Confirm these details away from the payment request.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 6),
            for (final _VerificationCheck check in _VerificationCheck.values)
              _VerificationCheckbox(
                key: Key(check.keyName),
                value: completed.contains(check),
                label: check.label,
                onChanged: (bool selected) => onChanged(check, selected),
              ),
            const SizedBox(height: 4),
            Semantics(
              liveRegion: true,
              label: isComplete
                  ? 'Independent verification complete'
                  : '$completedCount of 3 verification steps complete',
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Row(
                  key: ValueKey<bool>(isComplete),
                  children: <Widget>[
                    Icon(
                      isComplete
                          ? Icons.verified_outlined
                          : Icons.pending_outlined,
                      size: 18,
                      color: isComplete ? AppColors.safe : AppColors.inkMuted,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        isComplete
                            ? 'Verification complete'
                            : '$completedCount of 3 checked',
                        key: const Key('verification_progress'),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: isComplete
                                  ? AppColors.safe
                                  : AppColors.inkMuted,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerificationCheckbox extends StatelessWidget {
  const _VerificationCheckbox({
    required super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: value,
    onChanged: (bool? selected) => onChanged(selected ?? false),
    controlAffinity: ListTileControlAffinity.leading,
    contentPadding: EdgeInsets.zero,
    dense: true,
    visualDensity: VisualDensity.compact,
    title: Text(label, style: Theme.of(context).textTheme.bodySmall),
  );
}


/// Tells the user where to look next, rather than passing a verdict.
///
/// The name in a UPI request is set by whoever generated it. FinGuard cannot
/// check it against the bank record and does not pretend to. What it can do is
/// name the one screen where the real registered name does appear, and say
/// plainly what to do when the two disagree. A limitation stated precisely is
/// more useful to someone mid-payment than a reassurance that is not earned.
class _PayeeNameClaimCard extends StatelessWidget {
  const _PayeeNameClaimCard({required this.claimedName});

  final String claimedName;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('payee_name_unverified_card'),
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.cautionSurface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.caution),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.badge_outlined, color: AppColors.caution, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Check this name on the next screen',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    const TextSpan(text: 'This request claims to be from '),
                    TextSpan(
                      text: claimedName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const TextSpan(
                      text:
                          '. That name was written by whoever created this '
                          'request, and FinGuard cannot check it against the '
                          'bank record.',
                    ),
                  ],
                ),
                key: const Key('payee_name_unverified_claim'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Your UPI app will show the real registered name before you '
                'authorize anything. If it does not match, stop there.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              // The instruction above is not advice FinGuard invented: every
              // UPI app has been required to show the bank-verified name
              // since 1 June 2026. Citing the rule tells the user the check
              // is guaranteed to be available, not merely likely.
              Text(
                'Every UPI app in India has been required to show the '
                'bank-verified name since 1 June 2026.',
                key: const Key('payee_name_mandate_citation'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.inkMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
