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

abstract final class RiskThresholds {
  static const int safeMaximum = 29;
  static const int cautionMaximum = 69;

  static RiskLevel levelForScore(int score) {
    if (score <= safeMaximum) {
      return RiskLevel.safe;
    }
    if (score <= cautionMaximum) {
      return RiskLevel.caution;
    }
    return RiskLevel.highRisk;
  }
}

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

  factory RiskSignal.fromJson(Map<String, Object?> json) => RiskSignal(
    code: (json['code'] ?? 'UNSPECIFIED_SIGNAL').toString(),
    label: (json['label'] ?? 'Risk signal').toString(),
    weight: _intValue(json['weight']),
    evidence: (json['evidence'] ?? 'No additional evidence supplied.')
        .toString(),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'label': label,
    'weight': weight,
    'evidence': evidence,
  };

  static int _intValue(Object? value) {
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
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
    final int score = _requiredScore(
      json['score'] ?? json['risk_score'] ?? json['total_score'],
    );
    final RiskLevel level = _requiredLevel(
      json['level'] ?? json['risk_level'],
    );
    final RiskLevel expectedLevel = RiskThresholds.levelForScore(score);
    if (level != expectedLevel) {
      throw const FormatException(
        'The risk level does not match the deterministic score thresholds.',
      );
    }
    final Object? signalsValue = json['signals'] ?? json['reasons'];
    final List<RiskSignal> signals = signalsValue is List<Object?>
        ? signalsValue
              .whereType<Map<Object?, Object?>>()
              .map(
                (Map<Object?, Object?> item) => RiskSignal.fromJson(
                  item.map(
                    (Object? key, Object? value) =>
                        MapEntry(key.toString(), value),
                  ),
                ),
              )
              .toList(growable: false)
        : const <RiskSignal>[];
    return RiskAssessment(
      score: score,
      level: level,
      signals: signals,
      assessmentId: _optionalString(json['assessment_id']),
      transactionId: _optionalString(json['transaction_id']),
      recommendedAction:
          (json['recommended_action'] ??
                  json['recommendation'] ??
                  _defaultRecommendation(score))
              .toString(),
    );
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
    final String value =
        raw?.toString().toUpperCase().replaceAll('_', ' ').trim() ?? '';
    if (value == 'SAFE' || value == 'LOW') {
      return RiskLevel.safe;
    }
    if (value == 'CAUTION' || value == 'MEDIUM') {
      return RiskLevel.caution;
    }
    if (value == 'HIGH RISK' || value == 'HIGH') {
      return RiskLevel.highRisk;
    }
    throw const FormatException(
      'The risk response did not include a recognized risk level.',
    );
  }

  static String _defaultRecommendation(int score) {
    if (score <= RiskThresholds.safeMaximum) {
      return 'The request looks consistent with an ordinary payment. Verify the recipient before continuing.';
    }
    if (score <= RiskThresholds.cautionMaximum) {
      return 'Pause and independently verify the recipient before opening your UPI app.';
    }
    return 'Stop here. Do not pay until you have verified the request through a trusted channel.';
  }

  static int _requiredScore(Object? value) {
    int? score;
    if (value is int) {
      score = value;
    } else if (value is num &&
        value.isFinite &&
        value == value.roundToDouble()) {
      score = value.toInt();
    } else if (value is String) {
      score = int.tryParse(value.trim());
    }
    if (score == null || score < 0 || score > 100) {
      throw const FormatException(
        'The risk response did not include a valid score from 0 to 100.',
      );
    }
    return score;
  }

  static String? _optionalString(Object? value) {
    final String text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
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
