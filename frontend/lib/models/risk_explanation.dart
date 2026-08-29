enum RiskExplanationSource { template, gemini }

final class RiskExplanation {
  const RiskExplanation({
    required this.available,
    required this.source,
    required this.status,
    required this.explanation,
  });

  final bool available;
  final RiskExplanationSource source;
  final String status;
  final String explanation;

  bool get isAiAssisted => source == RiskExplanationSource.gemini;

  factory RiskExplanation.fromApiJson(Map<String, Object?> json) {
    const Set<String> fields = <String>{
      'available',
      'source',
      'status',
      'explanation',
    };
    const Set<String> statuses = <String>{
      'generated',
      'ai_disabled',
      'consent_required',
      'provider_unavailable',
      'malformed_response',
    };
    if (json.length != fields.length || !json.keys.every(fields.contains)) {
      throw const FormatException(
        'The explanation response had an invalid shape.',
      );
    }
    final Object? available = json['available'];
    final String source = json['source']?.toString() ?? '';
    final String status = json['status']?.toString() ?? '';
    final Object? rawExplanation = json['explanation'];
    if (available is! bool ||
        !statuses.contains(status) ||
        rawExplanation is! String) {
      throw const FormatException(
        'The explanation response had invalid fields.',
      );
    }
    final String explanation = rawExplanation.trim();
    if (explanation.isEmpty || explanation.length > 400) {
      throw const FormatException(
        'The explanation response was empty or too long.',
      );
    }
    final RiskExplanationSource parsedSource = switch (source) {
      'template' => RiskExplanationSource.template,
      'gemini' => RiskExplanationSource.gemini,
      _ => throw const FormatException(
        'The explanation response had an unknown source.',
      ),
    };
    if (parsedSource == RiskExplanationSource.gemini && status != 'generated') {
      throw const FormatException(
        'The explanation response had inconsistent provenance.',
      );
    }
    return RiskExplanation(
      available: available,
      source: parsedSource,
      status: status,
      explanation: explanation,
    );
  }
}
