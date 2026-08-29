final class TrustedContact {
  const TrustedContact({required this.name, required this.phone});

  final String name;
  final String phone;

  String get maskedPhone {
    final String suffix = phone.length <= 4
        ? phone
        : phone.substring(phone.length - 4);
    return '••••••$suffix';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'phone': phone,
  };

  factory TrustedContact.fromJson(Map<String, Object?> json) {
    final Object? rawName = json['name'];
    final Object? rawPhone = json['phone'];
    if (rawName is! String || rawPhone is! String) {
      throw const FormatException('Invalid trusted contact');
    }
    final String name = rawName.trim();
    final String? phone = normalizePhone(rawPhone);
    if (name.isEmpty || name.length > 40 || phone == null) {
      throw const FormatException('Invalid trusted contact');
    }
    return TrustedContact(name: name, phone: phone);
  }

  static String? normalizePhone(String raw) {
    String value = raw.trim().replaceAll(RegExp(r'[\s\-()]'), '');
    if (value.startsWith('+')) {
      value = value.substring(1);
    } else if (value.startsWith('00')) {
      value = value.substring(2);
    }
    if (!RegExp(r'^\d+$').hasMatch(value)) {
      return null;
    }
    if (value.length == 10 && RegExp(r'^[6-9]').hasMatch(value)) {
      value = '91$value';
    } else if (value.length == 11 && value.startsWith('0')) {
      final String local = value.substring(1);
      if (!RegExp(r'^[6-9]').hasMatch(local)) {
        return null;
      }
      value = '91$local';
    }
    return value.length >= 10 && value.length <= 15 ? value : null;
  }
}
