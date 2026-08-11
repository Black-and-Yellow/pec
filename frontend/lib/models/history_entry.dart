import 'payment.dart';
import 'risk.dart';

final class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.checkedAt,
    required this.payment,
    required this.assessment,
    this.isDemo = false,
  });

  final String id;
  final DateTime checkedAt;
  final Payment payment;
  final RiskAssessment assessment;
  final bool isDemo;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'checked_at': checkedAt.toUtc().toIso8601String(),
    'payment': payment.toStorageJson(),
    'assessment': assessment.toStorageJson(),
    'is_demo': isDemo,
  };

  factory HistoryEntry.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> paymentJson = _mapValue(json['payment']);
    final Map<String, Object?> assessmentJson = _mapValue(json['assessment']);
    return HistoryEntry(
      id: (json['id'] ?? '').toString(),
      checkedAt:
          DateTime.tryParse((json['checked_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      payment: Payment.fromJson(paymentJson),
      assessment: RiskAssessment.fromJson(assessmentJson),
      isDemo: json['is_demo'] == true,
    );
  }

  static Map<String, Object?> _mapValue(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('History entry is incomplete.');
    }
    return value.map(
      (Object? key, Object? item) => MapEntry(key.toString(), item),
    );
  }
}
