final class ContextAnalysis {
  const ContextAnalysis({
    required this.available,
    required this.sourceText,
    required this.flags,
    this.confidence,
    this.explanation,
    this.unavailableReason,
    this.source = ContextAnalysisSource.none,
    this.status,
    this.serviceMessage,
  }) : integrityToken = null,
       _integrityEligible = false;

  const ContextAnalysis._fromServer({
    required this.available,
    required this.sourceText,
    required this.flags,
    required this.confidence,
    required this.explanation,
    required this.unavailableReason,
    required this.source,
    required this.status,
    required this.serviceMessage,
    required this.integrityToken,
    required bool integrityEligible,
  }) : _integrityEligible = integrityEligible;

  final bool available;
  final String sourceText;
  final Map<String, bool> flags;
  final double? confidence;
  final String? explanation;
  final String? unavailableReason;
  final ContextAnalysisSource source;
  final String? status;
  final String? serviceMessage;
  final String? integrityToken;
  final bool _integrityEligible;

  bool get hasValidatedContext =>
      _integrityEligible &&
      source != ContextAnalysisSource.none &&
      (integrityToken ?? '').isNotEmpty;

  List<String> get detectedLabels => flags.entries
      .where((MapEntry<String, bool> entry) => entry.value)
      .map((MapEntry<String, bool> entry) => _friendlyLabel(entry.key))
      .toList(growable: false);

  Map<String, Object?> toApiJson() => <String, Object?>{
    for (final String key in _knownFlags) key: flags[key] ?? false,
    'confidence': (confidence ?? 0).clamp(0, 1).toDouble(),
  };

  factory ContextAnalysis.fromJson(
    Map<String, Object?> json, {
    required String sourceText,
  }) {
    final Object? nested =
        json['context'] ?? json['analysis'] ?? json['signals'];
    final Map<Object?, Object?>? nestedMap = nested is Map<Object?, Object?>
        ? nested
        : null;
    final Map<String, Object?> values = nestedMap != null
        ? nestedMap.map(
            (Object? key, Object? value) => MapEntry(key.toString(), value),
          )
        : json;
    final Map<String, bool> flags = <String, bool>{
      for (final String key in _knownFlags) key: _boolValue(values[key]),
    };
    final bool available = _boolValue(
      json['available'] ?? json['ai_available'],
      fallback: true,
    );
    final String? serviceMessage = _stringValue(json['message']);
    final ContextAnalysisSource source = _sourceValue(json['source']);
    final String? integrityToken = _stringValue(json['context_token']);
    final Object? rawConfidence = values['confidence'];
    final Set<String> contextKeys = values.keys.toSet();
    final bool hasStrictContextShape =
        nestedMap != null &&
        contextKeys.length == _knownFlags.length + 1 &&
        contextKeys.contains('confidence') &&
        _knownFlags.every(
          (String key) => contextKeys.contains(key) && values[key] is bool,
        ) &&
        rawConfidence is num &&
        rawConfidence.toDouble().isFinite &&
        rawConfidence >= 0 &&
        rawConfidence <= 1;
    return ContextAnalysis._fromServer(
      available: available,
      sourceText: sourceText,
      flags: flags,
      confidence: _doubleValue(values['confidence']),
      explanation: _stringValue(json['explanation'] ?? values['explanation']),
      unavailableReason: available
          ? _stringValue(json['unavailable_reason'])
          : _stringValue(json['unavailable_reason']) ?? serviceMessage,
      source: source,
      status: _stringValue(json['status']),
      serviceMessage: serviceMessage,
      integrityToken: integrityToken,
      integrityEligible:
          source != ContextAnalysisSource.none &&
          integrityToken != null &&
          hasStrictContextShape,
    );
  }

  static const List<String> _knownFlags = <String>[
    'impersonation',
    'urgency',
    'kyc_threat',
    'reward_or_refund_claim',
    'payment_requested',
    'suspicious_support_claim',
  ];

  static bool _boolValue(Object? value, {bool fallback = false}) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      return value.toLowerCase() == 'true';
    }
    return fallback;
  }

  static double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static String? _stringValue(Object? value) {
    final String text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static ContextAnalysisSource _sourceValue(Object? value) =>
      switch (value?.toString().toLowerCase()) {
        'gemini' => ContextAnalysisSource.gemini,
        'local_rules' => ContextAnalysisSource.localRules,
        _ => ContextAnalysisSource.none,
      };

  static String _friendlyLabel(String key) => switch (key) {
    'impersonation' => 'Possible impersonation',
    'urgency' => 'Urgent or pressuring language',
    'kyc_threat' => 'KYC or account-block threat',
    'reward_or_refund_claim' => 'Reward or refund claim',
    'payment_requested' => 'Payment requested',
    'suspicious_support_claim' => 'Unverified support claim',
    _ => key.replaceAll('_', ' '),
  };
}

enum ContextAnalysisSource { gemini, localRules, none }
