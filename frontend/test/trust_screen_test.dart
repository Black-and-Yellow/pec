import 'package:finguard/models/payee_trust.dart';
import 'package:finguard/screens/trust_screen.dart';
import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  AppServices buildServices(FakeApi api) => AppServices(
    api: api,
    store: MemoryLocalStore(),
    externalActions: FakeExternalActions(),
    demos: const DemoRepository(),
  );

  Future<void> pumpLookup(WidgetTester tester, FakeApi api, String vpa) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: TrustScreen(services: buildServices(api)),
      ),
    );
    await tester.enterText(find.byKey(const Key('trust_vpa_field')), vpa);
    await tester.tap(find.byKey(const Key('lookup_trust_button')));
    await tester.pumpAndSettle();
  }

  testWidgets('a thin file shows its grade and no invented number', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    await pumpLookup(tester, api, 'brand.new@okaxis');

    expect(api.lastTrustLookupVpa, 'brand.new@okaxis');
    expect(find.byKey(const Key('payee_trust_card')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('payee_trust_grade'))).data,
      'NEW',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('payee_trust_score'))).data,
      'no history',
    );
  });

  testWidgets('an established payee shows its grade and score', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi()
      ..trustLookupResult = PayeeTrust.fromApiJson(
        payeeTrustJson(
          vpa: 'coffee.corner@okaxis',
          grade: 'A_PLUS',
          score: 96,
          thinFile: false,
          checkCount: 1483,
          distinctDeviceCount: 412,
          observedDays: 612,
        ),
      );
    await pumpLookup(tester, api, 'coffee.corner@okaxis');

    expect(
      tester.widget<Text>(find.byKey(const Key('payee_trust_grade'))).data,
      'A+',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('payee_trust_score'))).data,
      '96/100',
    );
    expect(find.text('1 year'), findsOneWidget);
  });

  testWidgets('the provenance disclaimer is always reachable', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    await pumpLookup(tester, api, 'anyone@okaxis');

    expect(
      find.byKey(const Key('payee_trust_disclaimer')),
      findsOneWidget,
      reason: 'the score must never render without saying where it came from',
    );
    expect(find.textContaining('not an NPCI'), findsOneWidget);
  });

  testWidgets('a rejected lookup surfaces the message and offers a retry', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi()
      ..trustLookupError = const ApiException('That UPI ID is not valid.');
    await pumpLookup(tester, api, 'nonsense');

    expect(find.text('That UPI ID is not valid.'), findsOneWidget);
    expect(find.byKey(const Key('payee_trust_card')), findsNothing);
  });
}
