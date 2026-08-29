import 'package:finguard/models/identifier_check.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  Map<String, Object?> body({
    required String kind,
    required String value,
    List<Object?> addresses = const <Object?>[],
    int examined = 0,
    String summary = 'Fixture summary.',
    Object? reason,
  }) => <String, Object?>{
    'kind': kind,
    'value': value,
    'addresses': addresses,
    'addresses_examined': examined,
    'summary': summary,
    'reason': reason,
  };

  group('reading an identifier check', () {
    test('a single address is available as the primary report', () {
      final IdentifierCheck check = IdentifierCheck.fromApiJson(
        body(
          kind: 'UPI_ID',
          value: 'shop@okaxis',
          addresses: <Object?>[
            <String, Object?>{
              'vpa': 'shop@okaxis',
              'trust': payeeTrustJson(vpa: 'shop@okaxis', grade: 'A', score: 70, thinFile: false),
              'known_to_network': true,
            },
          ],
          examined: 1,
        ),
      );

      expect(check.kind, IdentifierKind.upiId);
      expect(check.primaryTrust?.grade.label, 'A');
      expect(check.addresses.single.knownToNetwork, isTrue);
    });

    test('a mobile number can report more than one address', () {
      final IdentifierCheck check = IdentifierCheck.fromApiJson(
        body(
          kind: 'MOBILE',
          value: '9876543210',
          addresses: <Object?>[
            <String, Object?>{
              'vpa': '9876543210@ybl',
              'trust': payeeTrustJson(vpa: '9876543210@ybl', grade: 'D', score: 20, thinFile: false),
              'known_to_network': true,
            },
            <String, Object?>{
              'vpa': '9876543210@paytm',
              'trust': payeeTrustJson(vpa: '9876543210@paytm', grade: 'B', score: 55, thinFile: false),
              'known_to_network': true,
            },
          ],
          examined: 8,
        ),
      );

      expect(check.kind, IdentifierKind.mobile);
      expect(check.addresses, hasLength(2));
      // Two reports means there is no single one to lead with.
      expect(check.primaryTrust, isNull);
      // The count examined must survive: it is what makes "nothing found"
      // readable as "we looked at eight" rather than "we did not look".
      expect(check.addressesExamined, 8);
    });

    test('a number matching nothing still reports how many were examined', () {
      final IdentifierCheck check = IdentifierCheck.fromApiJson(
        body(kind: 'MOBILE', value: '9000000001', examined: 8),
      );

      expect(check.addresses, isEmpty);
      expect(check.addressesExamined, 8);
    });

    test('an unusable input carries the reason it could not be read', () {
      final IdentifierCheck check = IdentifierCheck.fromApiJson(
        body(
          kind: 'UNSUPPORTED',
          value: 'not an id',
          summary: 'This could not be read.',
          reason: 'Paste a UPI ID such as name@okaxis.',
        ),
      );

      expect(check.kind, IdentifierKind.unsupported);
      expect(check.reason, contains('name@okaxis'));
    });

    test('an empty reason is treated as absent', () {
      final IdentifierCheck check = IdentifierCheck.fromApiJson(
        body(kind: 'UPI_ID', value: 'shop@okaxis', reason: ''),
      );

      expect(check.reason, isNull);
    });

    test('an unknown kind is rejected rather than guessed at', () {
      expect(
        () => IdentifierCheck.fromApiJson(body(kind: 'PIGEON', value: 'x')),
        throwsA(isA<FormatException>()),
      );
    });

    test('a malformed address list is rejected', () {
      expect(
        () => IdentifierCheck.fromApiJson(
          body(kind: 'UPI_ID', value: 'shop@okaxis', addresses: <Object?>['nope']),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing summary is rejected', () {
      expect(
        () => IdentifierCheck.fromApiJson(<String, Object?>{
          'kind': 'UPI_ID',
          'value': 'shop@okaxis',
          'addresses': <Object?>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
