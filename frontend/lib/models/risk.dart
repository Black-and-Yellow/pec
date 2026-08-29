import 'payment.dart';

enum RiskLevel { safe, caution, highRisk }

extension RiskLevelLabel on RiskLevel {
  String get label => switch (this) {
    RiskLevel.safe => 'SAFE',
    RiskLevel.caution => 'CAUTION',
    RiskLevel.highRisk => 'HIGH RISK',
  };

  String get apiValue => switch (this) {
    RiskLevel.safe => 'SAFE',
    RiskLevel.caution => 'CAUTION',
    RiskLevel.highRisk => 'HIGH',
  };
}

enum RiskHandoffPolicy { normal, deliberateConfirmation, paused }

final class RiskSignal {
  const RiskSignal({
    required this.code,
    required this.label,
    required this.weight,
    required this.evidence,
  });

  final String code;
  final String label;
  final int weight;
  final String evidence;

  factory RiskSignal.fromJson(Map<String, Object?> json) {
    if (json.length != _fieldNames.length ||
        !json.keys.every(_fieldNames.contains)) {
      throw const FormatException(
        'The risk response contained an invalid signal shape.',
      );
    }
    final String code = _requiredString(json['code'], maximumLength: 64);
    if (!_codePattern.hasMatch(code)) {
      throw const FormatException(
        'The risk response contained an invalid signal code.',
      );
    }
    final Object? rawWeight = json['weight'];
    if (rawWeight is! int || rawWeight < 0 || rawWeight > 100) {
      throw const FormatException(
        'The risk response contained an invalid signal weight.',
      );
    }
    return RiskSignal(
      code: code,
      label: _requiredString(json['label'], maximumLength: 160),
      weight: rawWeight,
      evidence: _requiredString(json['evidence'], maximumLength: 300),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'label': label,
    'weight': weight,
    'evidence': evidence,
  };

  static const Set<String> _fieldNames = <String>{
    'code',
    'label',
    'weight',
    'evidence',
  };

  static final RegExp _codePattern = RegExp(r'^[A-Z][A-Z0-9_]+$');

  static String _requiredString(Object? value, {required int maximumLength}) {
    if (value is! String) {
      throw const FormatException(
        'The risk response contained an invalid signal field.',
      );
    }
    final String text = value.trim();
    if (text.isEmpty || text.length > maximumLength) {
      throw const FormatException(
        'The risk response contained an invalid signal field.',
      );
    }
    return text;
  }
}

final class RiskAssessment {
  const RiskAssessment({
    required this.score,
    required this.level,
    required this.signals,
    required this.recommendedAction,
    this.assessmentId,
    this.transactionId,
  });

  final int score;
  final RiskLevel level;
  final List<RiskSignal> signals;
  final String recommendedAction;
  final String? assessmentId;
  final String? transactionId;

  factory RiskAssessment.fromJson(Map<String, Object?> json) {
    final int score = _requiredScore(json['score']);
    final RiskLevel level = _requiredLevel(json['level']);
    final List<RiskSignal> signals = _requiredSignals(json['signals']);
    final int signalWeightTotal = signals.fold<int>(
      0,
      (int total, RiskSignal signal) => total + signal.weight,
    );
    final int expectedScore = signalWeightTotal > 100 ? 100 : signalWeightTotal;
    if (score != expectedScore) {
      throw const FormatException(
        'The risk response score did not match its signal weights.',
      );
    }
    if (!_levelMatchesScore(level, score)) {
      throw const FormatException(
        'The risk response level did not match its score range.',
      );
    }
    return RiskAssessment(
      score: score,
      level: level,
      signals: signals,
      assessmentId: _optionalIdentifier(json['assessment_id']),
      transactionId: _optionalIdentifier(json['transaction_id']),
      recommendedAction: _requiredRecommendation(json['recommended_action']),
    );
  }

  factory RiskAssessment.fromApiJson(Map<String, Object?> json) {
    final RiskAssessment assessment = RiskAssessment.fromJson(json);
    if (assessment.assessmentId == null || assessment.transactionId == null) {
      throw const FormatException(
        'The risk response did not include its required identifiers.',
      );
    }
    return assessment;
  }

  Map<String, Object?> toApiJson() => <String, Object?>{
    if (assessmentId != null) 'assessment_id': assessmentId,
    'score': score,
    'level': level.apiValue,
    'signals': signals.map((RiskSignal signal) => signal.toJson()).toList(),
    'recommended_action': recommendedAction,
  };

  Map<String, Object?> toStorageJson() => <String, Object?>{
    ...toApiJson(),
    if (transactionId != null) 'transaction_id': transactionId,
  };

  static RiskLevel _requiredLevel(Object? raw) {
    if (raw == 'SAFE') {
      return RiskLevel.safe;
    }
    if (raw == 'CAUTION') {
      return RiskLevel.caution;
    }
    if (raw == 'HIGH') {
      return RiskLevel.highRisk;
    }
    throw const FormatException(
      'The risk response did not include a recognized risk level.',
    );
  }

  static bool _levelMatchesScore(RiskLevel level, int score) => switch (level) {
    RiskLevel.safe => score <= 29,
    RiskLevel.caution => score >= 30 && score <= 69,
    RiskLevel.highRisk => score >= 70,
  };

  static List<RiskSignal> _requiredSignals(Object? value) {
    if (value is! List<Object?> || value.length > 32) {
      throw const FormatException(
        'The risk response did not include a valid signal list.',
      );
    }
    return value
        .map((Object? item) {
          if (item is! Map<Object?, Object?> ||
              !item.keys.every((Object? key) => key is String)) {
            throw const FormatException(
              'The risk response contained an invalid signal.',
            );
          }
          return RiskSignal.fromJson(item.cast<String, Object?>());
        })
        .toList(growable: false);
  }

  static String _requiredRecommendation(Object? value) {
    if (value is! String) {
      throw const FormatException(
        'The risk response did not include a valid recommendation.',
      );
    }
    final String text = value.trim();
    if (text.isEmpty || text.length > 500) {
      throw const FormatException(
        'The risk response did not include a valid recommendation.',
      );
    }
    return text;
  }

  static int _requiredScore(Object? value) {
    if (value is! int || value < 0 || value > 100) {
      throw const FormatException(
        'The risk response did not include a valid score from 0 to 100.',
      );
    }
    return value;
  }

  static String? _optionalIdentifier(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const FormatException(
        'The risk response contained an invalid identifier.',
      );
    }
    final String text = value.trim();
    if (!_identifierPattern.hasMatch(text)) {
      throw const FormatException(
        'The risk response contained an invalid identifier.',
      );
    }
    return text;
  }

  static final RegExp _identifierPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9-]{0,127}$',
  );
}

final class RiskScoreResult {
  const RiskScoreResult._({
    required this.payment,
    required this.assessment,
    required this.requiresConfirmation,
    required this.handoffPolicy,
    required this.assessedAt,
  });

  final Payment payment;
  final RiskAssessment assessment;
  final bool requiresConfirmation;
  final RiskHandoffPolicy handoffPolicy;
  final DateTime assessedAt;

  // A result can only be created after the complete live response envelope,
  // echoed payment, and server control values have passed validation.
  bool get paymentHandoffEnabled => true;

  factory RiskScoreResult.fromApiJson(
    Map<String, Object?> json, {
    required Payment requestedPayment,
  }) {
    if (json.length != _fieldNames.length ||
        !json.keys.every(_fieldNames.contains)) {
      throw const FormatException(
        'The risk response contained an incomplete or invalid envelope.',
      );
    }

    final RiskAssessment assessment = RiskAssessment.fromApiJson(json);
    final Map<String, Object?> paymentJson = _requiredMap(json['payment']);
    final Payment returnedPayment = Payment.fromApiJson(
      paymentJson,
      canonicalUpiUri: requestedPayment.upiUri,
    );
    if (!_paymentsMatch(returnedPayment, requestedPayment)) {
      throw const FormatException(
        'The risk response payment did not match the checked request.',
      );
    }

    final Object? rawRequiresConfirmation = json['requires_confirmation'];
    if (rawRequiresConfirmation is! bool) {
      throw const FormatException(
        'The risk response contained an invalid confirmation control.',
      );
    }
    final RiskHandoffPolicy handoffPolicy = _requiredHandoffPolicy(
      json['handoff_policy'],
    );
    final bool expectedConfirmation = switch (assessment.level) {
      RiskLevel.safe => false,
      RiskLevel.caution || RiskLevel.highRisk => true,
    };
    final RiskHandoffPolicy expectedPolicy = switch (assessment.level) {
      RiskLevel.safe => RiskHandoffPolicy.normal,
      RiskLevel.caution => RiskHandoffPolicy.deliberateConfirmation,
      RiskLevel.highRisk => RiskHandoffPolicy.paused,
    };
    if (rawRequiresConfirmation != expectedConfirmation ||
        handoffPolicy != expectedPolicy) {
      throw const FormatException(
        'The risk response contained inconsistent handoff controls.',
      );
    }

    return RiskScoreResult._(
      payment: returnedPayment,
      assessment: assessment,
      requiresConfirmation: rawRequiresConfirmation,
      handoffPolicy: handoffPolicy,
      assessedAt: _requiredAssessedAt(json['assessed_at']),
    );
  }

  static Map<String, Object?> _requiredMap(Object? value) {
    if (value is! Map<Object?, Object?> ||
        !value.keys.every((Object? key) => key is String)) {
      throw const FormatException(
        'The risk response did not include a valid payment.',
      );
    }
    return value.cast<String, Object?>();
  }

  static RiskHandoffPolicy _requiredHandoffPolicy(Object? value) =>
      switch (value) {
        'NORMAL' => RiskHandoffPolicy.normal,
        'DELIBERATE_CONFIRMATION' => RiskHandoffPolicy.deliberateConfirmation,
        'PAUSED' => RiskHandoffPolicy.paused,
        _ => throw const FormatException(
          'The risk response contained an invalid handoff policy.',
        ),
      };

  static DateTime _requiredAssessedAt(Object? value) {
    if (value is! String || !_timestampPattern.hasMatch(value)) {
      throw const FormatException(
        'The risk response did not include a valid assessment timestamp.',
      );
    }
    final DateTime? parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw const FormatException(
        'The risk response did not include a valid assessment timestamp.',
      );
    }
    return parsed.toUtc();
  }

  static bool _paymentsMatch(Payment returned, Payment requested) =>
      returned.payeeVpa.toLowerCase() == requested.payeeVpa.toLowerCase() &&
      returned.payeeName == requested.payeeName &&
      returned.amount == requested.amount &&
      returned.note == requested.note &&
      returned.currency.toUpperCase() == requested.currency.toUpperCase() &&
      returned.transactionReference == requested.transactionReference;

  static const Set<String> _fieldNames = <String>{
    'assessment_id',
    'transaction_id',
    'payment',
    'score',
    'level',
    'signals',
    'recommended_action',
    'requires_confirmation',
    'handoff_policy',
    'assessed_at',
  };
  static final RegExp _timestampPattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
  );
}

final class DemoScenario {
  const DemoScenario({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.payment,
    required this.assessment,
  });

  final String id;
  final String title;
  final String subtitle;
  final Payment payment;
  final RiskAssessment assessment;
}
