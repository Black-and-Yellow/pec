import 'dart:async';

import 'package:finguard/screens/context_screen.dart';
import 'package:finguard/screens/paste_screen.dart';
import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('message analysis announces loading and completion', (
    WidgetTester tester,
  ) async {
    final Completer<void> gate = Completer<void>();
    final AppServices services = AppServices(
      api: FakeApi(analyzeContextGate: gate.future),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );
    final SemanticsHandle semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ContextScreen(services: services),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('suspicious_message_field')),
      'Urgent support request',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('analyze_message_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('analyze_message_button')));
    await tester.pump();

    final Semantics loading = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const Key('analyze_message_button')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(loading.properties.label, 'Analyzing message');
    expect(loading.properties.liveRegion, isTrue);
    gate.complete();
    await tester.pumpAndSettle();
    final Semantics result = tester.widget<Semantics>(
      find.byKey(const Key('context_analysis_result')),
    );
    expect(result.properties.label, 'Message analysis complete');
    expect(result.properties.liveRegion, isTrue);
    semantics.dispose();
  });

  testWidgets('local fallback remains usable when Gemini is unavailable', (
    WidgetTester tester,
  ) async {
    final AppServices services = AppServices(
      api: FakeApi(contextAvailable: false),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ContextScreen(services: services),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('suspicious_message_field')),
      'Urgent: update KYC now or your account will be blocked.',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('analyze_message_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('analyze_message_button')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Local fallback signals'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Local fallback signals'), findsOneWidget);
    expect(find.text('Urgent or pressuring language'), findsOneWidget);
    expect(find.text('Check a UPI request with this context'), findsOneWidget);
  });

  testWidgets('API failure is carried forward only as an unavailable notice', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi(
      contextError: const ApiException(
        'Context service is unavailable. Try again.',
        retryable: true,
      ),
    );
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ContextScreen(services: services),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('suspicious_message_field')),
      'Urgent support request',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('analyze_message_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('analyze_message_button')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Context analysis unavailable'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Context analysis unavailable'), findsOneWidget);
    expect(
      find.text(
        'No validated context signal will be included in deterministic scoring.',
      ),
      findsOneWidget,
    );
    expect(find.text('Check a UPI request without context'), findsOneWidget);

    await tester.tap(find.text('Check a UPI request without context'));
    await tester.pumpAndSettle();
    expect(find.byType(PasteScreen), findsOneWidget);
    expect(
      find.text(
        'Suspicious-message context will be included in this risk check.',
      ),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const Key('upi_uri_field')),
      'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('analyze_payment_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const Key('analyze_payment_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('analyze_payment_button')));
    await tester.pumpAndSettle();
    expect(api.lastScoreContext, isNull);
  });

  testWidgets('editing analyzed source text invalidates the prior analysis', (
    WidgetTester tester,
  ) async {
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ContextScreen(services: services),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('suspicious_message_field')),
      'Urgent original message',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('analyze_message_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('analyze_message_button')));
    await tester.pumpAndSettle();
    expect(find.text('Check a UPI request with this context'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('suspicious_message_field')),
      'Edited message with different evidence',
    );
    await tester.pump();

    expect(find.text('Check a UPI request with this context'), findsNothing);
    expect(find.text('Gemini context signals'), findsNothing);
  });
}
