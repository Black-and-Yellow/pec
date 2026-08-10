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
    final Map<String, List<String>> parameters = uri.queryParametersAll;
    if (parameters.values.any((List<String> values) => values.length != 1)) {
      throw const FormatException(
        'This UPI link contains duplicate payment fields.',
      );
    }
    final String vpa = (uri.queryParameters['pa'] ?? '').trim().toLowerCase();
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
    final String? rawAmount = uri.queryParameters['am']?.trim();
    if (rawAmount != null && rawAmount.isNotEmpty) {
      final double? amount = double.tryParse(rawAmount);
      final int decimals = rawAmount.contains('.')
          ? rawAmount.length - rawAmount.lastIndexOf('.') - 1
          : 0;
      if (amount == null ||
          !amount.isFinite ||
          amount <= 0 ||
          amount > 10000000 ||
          decimals > 2) {
        throw const FormatException(
          'This UPI link contains an invalid payment amount.',
        );
      }
    } else if (rawAmount != null) {
      throw const FormatException(
        'This UPI link contains an empty payment amount.',
      );
    }
    final String currency = (uri.queryParameters['cu'] ?? 'INR').toUpperCase();
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

  static String? _stringValue(Object? value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty ? null : text;
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
