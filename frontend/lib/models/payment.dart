import '../config/app_config.dart';

final class Payment {
  const Payment({
    required this.upiUri,
    required this.payeeVpa,
    required this.currency,
    this.payeeName,
    this.amount,
    this.note,
    this.transactionReference,
  });

  final String upiUri;
  final String payeeVpa;
  final String? payeeName;
  final double? amount;
  final String? note;
  final String currency;
  final String? transactionReference;

  String get recipientLabel {
    final String name = payeeName?.trim() ?? '';
    return name.isEmpty ? payeeVpa : name;
  }

  String get formattedAmount {
    if (amount == null) {
      return 'Amount chosen in UPI app';
    }
    final String value = amount!.toStringAsFixed(2);
    final String compact = value.endsWith('.00')
        ? value.substring(0, value.length - 3)
        : value;
    return currency.toUpperCase() == 'INR'
        ? '₹$compact'
        : '${currency.toUpperCase()} $compact';
  }

  Map<String, Object?> toApiJson() => <String, Object?>{
    'vpa': payeeVpa,
    'payee_name': payeeName,
    'amount': amount,
    'transaction_note': note,
    'currency': currency,
    'transaction_reference': transactionReference,
  };

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'upi_uri': upiUri,
    ...toApiJson(),
  };

  void requireMatchesOriginalUpiUri(Uri originalUpiUri) {
    final Uri validatedOriginal = validateUpiUri(originalUpiUri.toString());
    final Map<String, String> originalParameters = _normalizedParameters(
      validatedOriginal,
    );
    if (payeeVpa.toLowerCase() !=
        originalParameters['pa']!.trim().toLowerCase()) {
      throw const FormatException(
        'The parsed recipient does not match the original UPI request.',
      );
    }
    _requireCanonicalAmountMatch(
      parsedAmount: amount,
      handoffAmount: _doubleValue(originalParameters['am']),
    );
    _requireCanonicalMatch(
      field: 'payee name',
      parsedValue: payeeName,
      handoffValue: _normalizedOptionalText(originalParameters['pn']),
    );
    _requireCanonicalMatch(
      field: 'payment note',
      parsedValue: note,
      handoffValue: _normalizedOptionalText(originalParameters['tn']),
    );
    final String originalCurrency =
        (_stringValue(originalParameters['cu']) ?? 'INR').toUpperCase();
    if (currency != originalCurrency) {
      throw const FormatException(
        'The parsed currency does not match the original UPI request.',
      );
    }
    _requireCanonicalMatch(
      field: 'transaction reference',
      parsedValue: transactionReference,
      handoffValue:
          _normalizedOptionalText(originalParameters['tr']) ??
          _normalizedOptionalText(originalParameters['tid']),
    );
  }

  factory Payment.fromApiJson(
    Map<String, Object?> json, {
    required String canonicalUpiUri,
  }) {
    if (json.length != _apiFieldNames.length ||
        !json.keys.every(_apiFieldNames.contains)) {
      throw const FormatException(
        'The payment response contained an invalid field set.',
      );
    }
    _requireApiString(json['vpa'], maximumLength: 193);
    _requireNullableApiString(json['payee_name'], maximumLength: 128);
    final Object? amount = json['amount'];
    if (amount != null && amount is! num) {
      throw const FormatException(
        'The payment response contained an invalid amount.',
      );
    }
    _requireNullableApiString(json['transaction_note'], maximumLength: 250);
    _requireApiString(json['currency'], maximumLength: 3);
    _requireNullableApiString(
      json['transaction_reference'],
      maximumLength: 100,
    );
    return Payment.fromJson(json, canonicalUpiUri: canonicalUpiUri);
  }

  factory Payment.fromJson(
    Map<String, Object?> json, {
    String? canonicalUpiUri,
  }) {
    final String vpa =
        _stringValue(json['payee_vpa'] ?? json['vpa'] ?? json['pa']) ?? '';
    if (vpa.isEmpty) {
      throw const FormatException(
        'The payment response did not include a payee VPA.',
      );
    }
    final String upiUri =
        _stringValue(canonicalUpiUri) ??
        _stringValue(json['upi_uri'] ?? json['uri'] ?? json['raw_uri']) ??
        '';
    if (upiUri.isEmpty) {
      throw const FormatException(
        'The payment response did not include a UPI URI.',
      );
    }

    final Uri validatedUri = validateUpiUri(upiUri);
    final String normalizedVpa = vpa.toLowerCase();
    if (validatedUri.queryParameters['pa']?.toLowerCase() != normalizedVpa) {
      throw const FormatException(
        'The parsed recipient does not match the validated UPI handoff request.',
      );
    }
    final String currency =
        (_stringValue(json['currency'] ?? json['cu']) ?? 'INR').toUpperCase();
    if (currency != 'INR') {
      throw const FormatException(
        'FinGuard currently supports INR UPI requests only.',
      );
    }
    final double? amount = _doubleValue(json['amount'] ?? json['am']);
    if (amount != null &&
        (!amount.isFinite || amount <= 0 || amount > 10000000)) {
      throw const FormatException(
        'The payment amount is outside the supported range.',
      );
    }
    final String? payeeName = _stringValue(
      json['payee_name'] ?? json['name'] ?? json['pn'],
    );
    final String? note = _stringValue(
      json['note'] ?? json['transaction_note'] ?? json['tn'],
    );
    final String? transactionReference = _stringValue(
      json['transaction_reference'] ?? json['reference'] ?? json['tr'],
    );

    _requireCanonicalMatch(
      field: 'payee name',
      parsedValue: payeeName,
      handoffValue: _stringValue(validatedUri.queryParameters['pn']),
    );
    _requireCanonicalAmountMatch(
      parsedAmount: amount,
      handoffAmount: _doubleValue(validatedUri.queryParameters['am']),
    );
    _requireCanonicalMatch(
      field: 'payment note',
      parsedValue: note,
      handoffValue: _stringValue(validatedUri.queryParameters['tn']),
    );
    final String handoffCurrency =
        (_stringValue(validatedUri.queryParameters['cu']) ?? 'INR')
            .toUpperCase();
    if (currency != handoffCurrency) {
      throw const FormatException(
        'The parsed currency does not match the validated UPI handoff request.',
      );
    }
    _requireCanonicalMatch(
      field: 'transaction reference',
      parsedValue: transactionReference,
      handoffValue: _stringValue(
        validatedUri.queryParameters['tr'] ??
            validatedUri.queryParameters['tid'],
      ),
    );

    return Payment(
      upiUri: validatedUri.toString(),
      payeeVpa: normalizedVpa,
      payeeName: payeeName,
      amount: amount,
      note: note,
      currency: currency,
      transactionReference: transactionReference,
    );
  }

  static Uri validateUpiUri(String rawInput) {
    final String value = rawInput.trim();
    if (value.isEmpty) {
      throw const FormatException('Paste or scan a UPI payment link first.');
    }
    if (value.length > AppConfig.maxUpiUriLength) {
      throw const FormatException(
        'This payment link is too long to check safely.',
      );
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'upi' ||
        uri.host.toLowerCase() != 'pay') {
      throw const FormatException(
        'Only standard upi://pay links can be checked.',
      );
    }
    if (uri.path.isNotEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.port != 0) {
      throw const FormatException(
        'This UPI link contains unsupported address data.',
      );
    }
    if (_malformedPercentEncoding.hasMatch(uri.query)) {
      throw const FormatException(
        'This UPI link contains malformed payment fields.',
      );
    }
    final List<String> rawFields = uri.query.isEmpty
        ? const <String>[]
        : uri.query.split('&');
    if (rawFields.length > 30) {
      throw const FormatException(
        'This UPI link contains too many payment fields.',
      );
    }
    final Map<String, String> normalizedParameters = _normalizedParameters(uri);
    final String vpa = (normalizedParameters['pa'] ?? '').trim().toLowerCase();
    if (vpa.isEmpty) {
      throw const FormatException(
        'This UPI link is missing the recipient address (pa).',
      );
    }
    if (!_vpaPattern.hasMatch(vpa)) {
      throw const FormatException(
        'This UPI link contains an invalid recipient address.',
      );
    }
    final String? rawAmount = normalizedParameters['am']?.trim();
    if (rawAmount != null && rawAmount.isNotEmpty) {
      final double? amount = _amountPattern.hasMatch(rawAmount)
          ? double.tryParse(rawAmount)
          : null;
      if (amount == null || amount <= 0 || amount > 10000000) {
        throw const FormatException(
          'This UPI link contains an invalid payment amount.',
        );
      }
    } else if (rawAmount != null) {
      throw const FormatException(
        'This UPI link contains an empty payment amount.',
      );
    }
    final String currency = (normalizedParameters['cu'] ?? 'INR')
        .trim()
        .toUpperCase();
    if (currency != 'INR') {
      throw const FormatException(
        'FinGuard currently supports INR UPI requests only.',
      );
    }
    return uri;
  }

  static final RegExp _vpaPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}@[A-Za-z0-9][A-Za-z0-9.-]{0,63}$',
  );
  static final RegExp _amountPattern = RegExp(r'^\d{1,8}(?:\.\d{1,2})?$');
  static final RegExp _malformedPercentEncoding = RegExp(
    r'%(?![0-9A-Fa-f]{2})',
  );
  static const Set<String> _apiFieldNames = <String>{
    'vpa',
    'payee_name',
    'amount',
    'transaction_note',
    'currency',
    'transaction_reference',
  };

  static void _requireApiString(Object? value, {required int maximumLength}) {
    if (value is! String ||
        value.isEmpty ||
        value.length > maximumLength ||
        value != value.trim() ||
        _containsControlCharacter(value)) {
      throw const FormatException(
        'The payment response contained an invalid text field.',
      );
    }
  }

  static void _requireNullableApiString(
    Object? value, {
    required int maximumLength,
  }) {
    if (value == null) {
      return;
    }
    _requireApiString(value, maximumLength: maximumLength);
  }

  static bool _containsControlCharacter(String value) =>
      value.codeUnits.any((int codeUnit) => codeUnit < 32 || codeUnit == 127);

  static Map<String, String> _normalizedParameters(Uri uri) {
    final Map<String, String> normalizedParameters = <String, String>{};
    for (final MapEntry<String, List<String>> parameter
        in uri.queryParametersAll.entries) {
      final String normalizedKey = parameter.key.toLowerCase();
      if (parameter.value.length != 1 ||
          normalizedParameters.containsKey(normalizedKey)) {
        throw const FormatException(
          'This UPI link contains duplicate payment fields.',
        );
      }
      normalizedParameters[normalizedKey] = parameter.value.single;
    }
    return normalizedParameters;
  }

  static String? _stringValue(Object? value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String? _normalizedOptionalText(String? value) {
    final String? text = _stringValue(value);
    if (text == null) {
      return null;
    }
    return text.split(RegExp(r'\s+')).join(' ');
  }

  static double? _doubleValue(Object? value) {
    if (value == null || value.toString().trim().isEmpty) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    final double? parsed = double.tryParse(value.toString());
    if (parsed == null) {
      throw const FormatException(
        'The payment response contained an invalid amount.',
      );
    }
    return parsed;
  }

  static void _requireCanonicalMatch({
    required String field,
    required String? parsedValue,
    required String? handoffValue,
  }) {
    if (parsedValue != handoffValue) {
      throw FormatException(
        'The parsed $field does not match the validated UPI handoff request.',
      );
    }
  }

  static void _requireCanonicalAmountMatch({
    required double? parsedAmount,
    required double? handoffAmount,
  }) {
    if (parsedAmount == null && handoffAmount == null) {
      return;
    }
    if (parsedAmount == null || handoffAmount == null) {
      throw const FormatException(
        'The parsed amount does not match the validated UPI handoff request.',
      );
    }
    if ((parsedAmount - handoffAmount).abs() > 0.000001) {
      throw const FormatException(
        'The parsed amount does not match the validated UPI handoff request.',
      );
    }
  }
}
