/// A reputation report for one UPI ID.
///
/// FinGuard cannot read a payee's UPI history: NPCI publishes no such feed.
/// What this reports is the standing the FinGuard network itself has observed,
/// plus what the address structure discloses on its own. It is a bureau score,
/// not a regulator's rating, and [disclaimer] travels with it so no screen can
/// render the number without its provenance.
library;

enum TrustGrade {
  aPlus('A_PLUS', 'A+'),
  a('A', 'A'),
  b('B', 'B'),
  c('C', 'C'),
  d('D', 'D'),
  isNew('NEW', 'NEW');

  const TrustGrade(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static TrustGrade fromApi(Object? value) => switch (value) {
    'A_PLUS' => TrustGrade.aPlus,
    'A' => TrustGrade.a,
    'B' => TrustGrade.b,
    'C' => TrustGrade.c,
    'D' => TrustGrade.d,
    'NEW' => TrustGrade.isNew,
    _ => throw const FormatException(
      'The trust response did not include a recognized grade.',
    ),
  };
}

enum TrustPillarStatus {
  strong('STRONG'),
  neutral('NEUTRAL'),
  weak('WEAK'),
  noData('NO_DATA');

  const TrustPillarStatus(this.apiValue);

  final String apiValue;

  static TrustPillarStatus fromApi(Object? value) => switch (value) {
    'STRONG' => TrustPillarStatus.strong,
    'NEUTRAL' => TrustPillarStatus.neutral,
    'WEAK' => TrustPillarStatus.weak,
    'NO_DATA' => TrustPillarStatus.noData,
    _ => throw const FormatException(
      'The trust response contained an unrecognized pillar status.',
    ),
  };
}

final class TrustPillar {
  const TrustPillar({
    required this.code,
    required this.label,
    required this.points,
    required this.maximum,
    required this.status,
    required this.evidence,
  });

  final String code;
  final String label;
  final int points;
  final int maximum;
  final TrustPillarStatus status;
  final String evidence;

  bool get hasData => status != TrustPillarStatus.noData;

  double get fraction => maximum == 0 ? 0 : points / maximum;

  factory TrustPillar.fromApiJson(Map<String, Object?> json) {
    final int maximum = _boundedInt(json['maximum'], minimum: 1, maximum: 100);
    final int points = _boundedInt(json['points'], minimum: 0, maximum: 100);
    if (points > maximum) {
      throw const FormatException(
        'A trust pillar awarded more points than it could.',
      );
    }
    return TrustPillar(
      code: _text(json['code'], maximumLength: 32),
      label: _text(json['label'], maximumLength: 80),
      points: points,
      maximum: maximum,
      status: TrustPillarStatus.fromApi(json['status']),
      evidence: _text(json['evidence'], maximumLength: 400),
    );
  }
}

final class PayeeTrust {
  const PayeeTrust({
    required this.vpa,
    required this.grade,
    required this.headline,
    required this.thinFile,
    required this.impersonation,
    required this.confidence,
    required this.pillars,
    required this.assessedPoints,
    required this.assessableMaximum,
    required this.observedDays,
    required this.checkCount,
    required this.distinctDeviceCount,
    required this.reportedCount,
    required this.disclaimer,
    this.score,
    this.firstSeenAt,
  });

  final String vpa;

  /// Withheld for a thin file, the way a credit bureau returns "no history"
  /// rather than a number. A new payee scoring well on address structure
  /// alone would otherwise display a high number that reads as an
  /// endorsement of an address nobody has ever paid.
  final int? score;

  final TrustGrade grade;
  final String headline;
  final bool thinFile;
  final bool impersonation;
  final String confidence;
  final List<TrustPillar> pillars;
  final int assessedPoints;
  final int assessableMaximum;
  final int observedDays;
  final int checkCount;
  final int distinctDeviceCount;
  final int reportedCount;
  final String disclaimer;
  final DateTime? firstSeenAt;

  bool get isAdverse => grade == TrustGrade.d || impersonation;

  factory PayeeTrust.fromApiJson(Map<String, Object?> json) {
    final Object? rawPillars = json['pillars'];
    if (rawPillars is! List<Object?> || rawPillars.length > 8) {
      throw const FormatException(
        'The trust response did not include a valid pillar list.',
      );
    }
    final List<TrustPillar> pillars = rawPillars.map((Object? item) {
      if (item is! Map<Object?, Object?> ||
          !item.keys.every((Object? key) => key is String)) {
        throw const FormatException(
          'The trust response contained an invalid pillar.',
        );
      }
      return TrustPillar.fromApiJson(item.cast<String, Object?>());
    }).toList(growable: false);

    final Object? rawScore = json['score'];
    if (rawScore != null && (rawScore is! int || rawScore < 0 || rawScore > 100)) {
      throw const FormatException(
        'The trust response contained an invalid score.',
      );
    }

    return PayeeTrust(
      vpa: _text(json['vpa'], maximumLength: 193).toLowerCase(),
      score: rawScore as int?,
      grade: TrustGrade.fromApi(json['grade']),
      headline: _text(json['headline'], maximumLength: 160),
      thinFile: _flag(json['thin_file']),
      impersonation: _flag(json['impersonation']),
      confidence: _text(json['confidence'], maximumLength: 8),
      pillars: pillars,
      assessedPoints: _boundedInt(json['assessed_points'], minimum: 0, maximum: 100),
      assessableMaximum: _boundedInt(
        json['assessable_maximum'],
        minimum: 1,
        maximum: 100,
      ),
      observedDays: _boundedInt(json['observed_days'], minimum: 0, maximum: 100000),
      checkCount: _boundedInt(json['check_count'], minimum: 0, maximum: 100000000),
      distinctDeviceCount: _boundedInt(
        json['distinct_device_count'],
        minimum: 0,
        maximum: 100000000,
      ),
      reportedCount: _boundedInt(
        json['reported_count'],
        minimum: 0,
        maximum: 100000000,
      ),
      disclaimer: _text(json['disclaimer'], maximumLength: 400),
      firstSeenAt: _optionalTimestamp(json['first_seen_at']),
    );
  }
}

String _text(Object? value, {required int maximumLength}) {
  if (value is! String) {
    throw const FormatException(
      'The trust response contained an invalid text field.',
    );
  }
  final String text = value.trim();
  if (text.isEmpty || text.length > maximumLength) {
    throw const FormatException(
      'The trust response contained an invalid text field.',
    );
  }
  return text;
}

int _boundedInt(Object? value, {required int minimum, required int maximum}) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException(
      'The trust response contained an out-of-range number.',
    );
  }
  return value;
}

bool _flag(Object? value) {
  if (value is! bool) {
    throw const FormatException(
      'The trust response contained an invalid flag.',
    );
  }
  return value;
}

DateTime? _optionalTimestamp(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw const FormatException(
      'The trust response contained an invalid timestamp.',
    );
  }
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw const FormatException(
      'The trust response contained an invalid timestamp.',
    );
  }
  return parsed.toUtc();
}
