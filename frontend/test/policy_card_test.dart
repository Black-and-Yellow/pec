import 'package:finguard/models/policy_card.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('reading the published policy', () {
    test('bands, signals and limitations survive the round trip', () {
      final PolicyCard card = PolicyCard.fromApiJson(policyCardJson());

      expect(card.policyVersion, 'test-1');
      expect(card.bands.map((PolicyBand b) => b.name), <String>[
        'SAFE',
        'CAUTION',
        'HIGH',
      ]);
      expect(card.bands.first.range, '0-29');
      expect(card.limitations, isNotEmpty);
    });

    test('the calibration statement refuses to claim probabilities', () {
      final PolicyCard card = PolicyCard.fromApiJson(policyCardJson());
      expect(
        card.calibrationStatement,
        contains('not statistically calibrated fraud probabilities'),
      );
    });

    test('signals are ordered by what actually moves a verdict', () {
      final PolicyCard card = PolicyCard.fromApiJson(policyCardJson());
      final List<int> points = card.signalsByWeight
          .map((PolicySignal s) => s.points)
          .toList();
      expect(points, <int>[25, 18]);
    });

    test('a source category becomes a readable label', () {
      final PolicyCard card = PolicyCard.fromApiJson(policyCardJson());
      expect(card.signalsByWeight.first.sourceLabel, 'NPCI advisory');
      expect(card.signalsByWeight.last.sourceLabel, 'FinGuard policy');
    });

    test('a malformed payload is rejected rather than half-read', () {
      final Map<String, Object?> broken = policyCardJson()
        ..remove('calibration_statement');
      expect(
        () => PolicyCard.fromApiJson(broken),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown source category falls back without throwing', () {
      final Map<String, Object?> json = policyCardJson();
      (json['signals']! as List<Object?>).add(<String, Object?>{
        'field': 'future_signal',
        'title': 'Something new',
        'points': 4,
        'rationale': 'Added by a newer backend.',
        'source_category': 'SOMETHING_ELSE',
        'source_link': '',
      });
      final PolicyCard card = PolicyCard.fromApiJson(json);
      expect(card.signals.last.sourceLabel, 'FinGuard policy');
    });
  });
}
