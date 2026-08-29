import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/screens/scanner_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:finguard/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('shared danger confirmation keeps a white foreground', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (BuildContext context) => FilledButton(
            onPressed: () => confirmAction(
              context,
              title: 'Delete history?',
              message: 'This cannot be undone.',
              confirmLabel: 'Delete history',
              isDanger: true,
            ),
            child: const Text('Open confirmation'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open confirmation'));
    await tester.pumpAndSettle();

    final FilledButton confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete history'),
    );
    expect(
      confirm.style?.foregroundColor?.resolve(<WidgetState>{}),
      Colors.white,
    );
  });

  testWidgets('scanner fits a 320px viewport at twice the text scale', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ScannerScreen(services: _services()),
      ),
    );
    await tester.pump();

    expect(find.text('Nothing opens automatically'), findsOneWidget);
    expect(find.byKey(const Key('upload_qr_button')), findsOneWidget);
    expect(find.text('Paste a UPI link instead'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('result score header wraps at 320px and twice the text scale', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: RiskResultScreen(
          services: _services(),
          payment: const Payment(
            upiUri: 'upi://pay?pa=demo%40upi&am=50&cu=INR',
            payeeVpa: 'demo@upi',
            amount: 50,
            currency: 'INR',
          ),
          assessment: const RiskAssessment(
            score: 80,
            level: RiskLevel.highRisk,
            signals: <RiskSignal>[],
            recommendedAction: 'Stop and verify independently.',
          ),
          paymentHandoffEnabled: false,
          isDemo: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('risk_score')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final FilledButton stop = tester.widget<FilledButton>(
      find.byKey(const Key('stop_here_button')),
    );
    expect(stop.style?.foregroundColor?.resolve(<WidgetState>{}), Colors.white);
  });
}

AppServices _services() => AppServices(
  api: FakeApi(),
  store: MemoryLocalStore(),
  externalActions: FakeExternalActions(),
  demos: const DemoRepository(),
);
