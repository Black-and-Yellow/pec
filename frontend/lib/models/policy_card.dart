/// The scoring policy, as published by the side that owns it.
///
/// Deliberately fetched rather than hard-coded. A copy of the weights in the
/// app would be a second authority that can silently disagree with the engine,
/// and the number on screen would stop meaning what the server computed.
final class PolicyBand {
  const PolicyBand({
    required this.name,
    required this.minimum,
    required this.maximum,
    required this.meaning,
  });

  final String name;
  final int minimum;
  final int maximum;
  final String meaning;

  String get range => '$minimum-$maximum';

  static PolicyBand fromApiJson(Map<String, Object?> json) {
    final Object? name = json['name'];
    final Object? minimum = json['minimum'];
    final Object? maximum = json['maximum'];
    final Object? meaning = json['meaning'];
    if (name is! String ||
        minimum is! int ||
        maximum is! int ||
        meaning is! String) {
      throw const FormatException('A policy band is malformed.');
    }
    return PolicyBand(
      name: name,
      minimum: minimum,
      maximum: maximum,
      meaning: meaning,
    );
  }
}

final class PolicySignal {
  const PolicySignal({
    required this.title,
    required this.points,
    required this.rationale,
    required this.sourceCategory,
    required this.sourceLink,
  });

  final String title;
  final int points;
  final String rationale;
  final String sourceCategory;
  final String sourceLink;

  /// A short human label for where the signal's direction is supported.
  String get sourceLabel => switch (sourceCategory) {
    'NPCI_ADVISORY' => 'NPCI advisory',
    'RBI_ADVISORY' => 'RBI advisory',
    'I4C_ADVISORY' => 'I4C advisory',
    _ => 'FinGuard policy',
  };

  static PolicySignal fromApiJson(Map<String, Object?> json) {
    final Object? title = json['title'];
    final Object? points = json['points'];
    final Object? rationale = json['rationale'];
    if (title is! String || points is! int || rationale is! String) {
      throw const FormatException('A policy signal is malformed.');
    }
    return PolicySignal(
      title: title,
      points: points,
      rationale: rationale,
      sourceCategory: json['source_category'] is String
          ? json['source_category']! as String
          : 'FINGUARD_POLICY',
      sourceLink: json['source_link'] is String
          ? json['source_link']! as String
          : '',
    );
  }
}

final class PolicyCard {
  const PolicyCard({
    required this.policyVersion,
    required this.bands,
    required this.signals,
    required this.limitations,
    required this.calibrationStatement,
  });

  final String policyVersion;
  final List<PolicyBand> bands;
  final List<PolicySignal> signals;
  final List<String> limitations;

  /// The sentence that keeps the numbers honest. Always shown.
  final String calibrationStatement;

  /// Highest-weighted first: what actually moves a verdict, at a glance.
  List<PolicySignal> get signalsByWeight {
    final List<PolicySignal> sorted = List<PolicySignal>.of(signals)
      ..sort((PolicySignal a, PolicySignal b) => b.points.compareTo(a.points));
    return sorted;
  }

  static PolicyCard fromApiJson(Map<String, Object?> json) {
    final Object? version = json['policy_version'];
    final Object? statement = json['calibration_statement'];
    final Object? bands = json['bands'];
    final Object? signals = json['signals'];
    final Object? limitations = json['limitations'];
    if (version is! String ||
        statement is! String ||
        bands is! List<Object?> ||
        signals is! List<Object?> ||
        limitations is! List<Object?>) {
      throw const FormatException('The policy card response is malformed.');
    }
    return PolicyCard(
      policyVersion: version,
      calibrationStatement: statement,
      bands: <PolicyBand>[
        for (final Object? band in bands)
          if (band is Map<String, Object?>)
            PolicyBand.fromApiJson(band)
          else
            throw const FormatException('A policy band is malformed.'),
      ],
      signals: <PolicySignal>[
        for (final Object? signal in signals)
          if (signal is Map<String, Object?>)
            PolicySignal.fromApiJson(signal)
          else
            throw const FormatException('A policy signal is malformed.'),
      ],
      limitations: <String>[
        for (final Object? entry in limitations)
          if (entry is String) entry,
      ],
    );
  }
}
