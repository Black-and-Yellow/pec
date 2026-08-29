import 'package:finguard/models/payment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Payment', () {
    test('parses supported backend aliases', () {
      final Payment payment = Payment.fromJson(<String, Object?>{
        'pa': 'coffee@upi',
        'pn': 'Coffee Shop',
        'am': '180.00',
        'cu': 'INR',
        'tn': 'Latte',
        'upi_uri':
            'upi://pay?pa=coffee@upi&pn=Coffee%20Shop&am=180&cu=INR&tn=Latte',
      });

      expect(payment.payeeVpa, 'coffee@upi');
      expect(payment.payeeName, 'Coffee Shop');
      expect(payment.amount, 180);
      expect(payment.formattedAmount, '₹180');
    });

    test('rejects non-UPI and incomplete scanned links', () {
      expect(
        () => Payment.validateUpiUri('https://example.com/pay'),
        throwsFormatException,
      );
      expect(
        () => Payment.validateUpiUri('upi://pay?pn=Missing%20VPA'),
        throwsFormatException,
      );
    });

    test('accepts a standard UPI payment URI', () {
      final Uri uri = Payment.validateUpiUri(
        'upi://pay?pa=merchant@upi&pn=Merchant&am=45.50&cu=INR',
      );

      expect(uri.scheme, 'upi');
      expect(uri.host, 'pay');
      expect(uri.queryParameters['pa'], 'merchant@upi');
    });

    test('binds normalized text and blank tr fallback to the original URI', () {
      const Payment payment = Payment(
        upiUri:
            'upi://pay?pa=merchant%40upi&pn=Merchant%20Name&am=45.50&cu=INR&tn=Order%20payment&tr=SECONDARY',
        payeeVpa: 'merchant@upi',
        payeeName: 'Merchant Name',
        amount: 45.5,
        note: 'Order payment',
        currency: 'INR',
        transactionReference: 'SECONDARY',
      );

      expect(
        () => payment.requireMatchesOriginalUpiUri(
          Uri.parse(
            'upi://pay?pa=merchant%40upi&pn=%20Merchant++Name%20&am=45.50&cu=inr&tn=Order++payment&tr=&tid=SECONDARY',
          ),
        ),
        returnsNormally,
      );
    });

    test(
      'rejects duplicate fields, unsupported currency and malformed amounts',
      () {
        expect(
          () => Payment.validateUpiUri('upi://pay?pa=one@upi&pa=two@upi'),
          throwsFormatException,
        );
        expect(
          () => Payment.validateUpiUri('upi://pay?pa=merchant@upi&cu=USD'),
          throwsFormatException,
        );
        expect(
          () => Payment.validateUpiUri('upi://pay?pa=merchant@upi&am=-10'),
          throwsFormatException,
        );
        for (final String amount in <String>['1e3', '1.234', '000000001']) {
          expect(
            () =>
                Payment.validateUpiUri('upi://pay?pa=merchant@upi&am=$amount'),
            throwsFormatException,
            reason: 'client handoff must reject non-canonical amount $amount',
          );
        }
      },
    );

    test('rejects case-folded duplicates and oversized query sets', () {
      expect(
        () =>
            Payment.validateUpiUri('upi://pay?pa=merchant@upi&PA=attacker@upi'),
        throwsFormatException,
      );

      final String tooManyFields = <String>[
        'pa=merchant@upi',
        ...List<String>.generate(30, (int index) => 'x$index=value'),
      ].join('&');
      expect(
        () => Payment.validateUpiUri('upi://pay?$tooManyFields'),
        throwsFormatException,
      );
    });

    test('rejects malformed percent encoding before URI handoff', () {
      expect(
        () => Payment.validateUpiUri('upi://pay?pa=merchant%ZZ@upi'),
        throwsFormatException,
      );
      expect(
        () => Payment.validateUpiUri('upi://pay?pa=merchant%@upi'),
        throwsFormatException,
      );
    });

    test('uses a strict backend payment shape separate from local storage', () {
      const Payment payment = Payment(
        upiUri: 'upi://pay?pa=coffee@upi&am=180&cu=INR',
        payeeVpa: 'coffee@upi',
        amount: 180,
        currency: 'INR',
      );

      expect(payment.toApiJson().keys, isNot(contains('upi_uri')));
      expect(payment.toApiJson()['vpa'], 'coffee@upi');
      expect(payment.toStorageJson()['upi_uri'], payment.upiUri);
    });

    test('rejects payment fields that disagree with the handoff URI', () {
      final Map<String, Object?> valid = <String, Object?>{
        'vpa': 'merchant@upi',
        'payee_name': 'Merchant',
        'amount': 4500,
        'transaction_note': 'Order payment',
        'currency': 'INR',
        'transaction_reference': 'ORDER-1',
      };
      const String canonical =
          'upi://pay?pa=merchant@upi&pn=Merchant&am=4500&tn=Order%20payment&cu=INR&tr=ORDER-1';

      for (final MapEntry<String, Object?> mismatch
          in <MapEntry<String, Object?>>[
            const MapEntry<String, Object?>('payee_name', 'Other merchant'),
            const MapEntry<String, Object?>('amount', 45),
            const MapEntry<String, Object?>('transaction_note', 'Other note'),
            const MapEntry<String, Object?>('transaction_reference', 'ORDER-2'),
          ]) {
        expect(
          () => Payment.fromJson(<String, Object?>{
            ...valid,
            mismatch.key: mismatch.value,
          }, canonicalUpiUri: canonical),
          throwsFormatException,
          reason: '${mismatch.key} must be bound to the handoff URI',
        );
      }
    });
  });
}
