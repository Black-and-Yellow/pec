import 'dart:async';

import 'package:finguard/screens/paste_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('payment check exposes an accessible live loading status', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final Completer<void> parseGate = Completer<void>();
    final MemoryLocalStore store = MemoryLocalStore();
    final AppServices services = AppServices(
      api: FakeApi(parsePaymentGate: parseGate.future),
      store: store,
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: PasteScreen(services: services),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('upi_uri_field')),
      'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
    );
    await tester.tap(find.byKey(const Key('analyze_payment_button')));
    await tester.pump();

    final Finder loading = find.bySemanticsLabel('Checking request');
    expect(loading, findsOneWidget);
    expect(
      tester.getSemantics(loading),
      matchesSemantics(label: 'Checking request', isLiveRegion: true),
    );

    parseGate.complete();
    await tester.pumpAndSettle();
    expect(
      (await store.history()).single.checkedAt,
      DateTime.utc(2026, 8, 12, 10),
    );
    semantics.dispose();
  });
}
