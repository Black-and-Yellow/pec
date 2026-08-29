import 'package:finguard/models/trusted_contact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes supported trusted-contact phone formats', () {
    const Map<String, String?> cases = <String, String?>{
      '9876543210': '919876543210',
      '+91 98765 43210': '919876543210',
      '09876543210': '919876543210',
      '0091-98765-43210': '919876543210',
      '123': null,
      'abcd': null,
    };

    for (final MapEntry<String, String?> entry in cases.entries) {
      expect(
        TrustedContact.normalizePhone(entry.key),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('JSON parsing validates and normalizes the local contact', () {
    final TrustedContact contact = TrustedContact.fromJson(<String, Object?>{
      'name': '  Amma  ',
      'phone': '+91 98765 43210',
    });

    expect(contact.name, 'Amma');
    expect(contact.phone, '919876543210');
    expect(contact.maskedPhone, '••••••3210');
    expect(contact.toJson(), <String, Object?>{
      'name': 'Amma',
      'phone': '919876543210',
    });
  });
}
