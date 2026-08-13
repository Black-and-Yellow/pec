import 'package:finguard/screens/incident_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  const String report = 'Test incident draft';

  AppServices buildServices(FakeExternalActions actions) => AppServices(
    api: FakeApi(),
    store: MemoryLocalStore(),
    externalActions: actions,
    demos: const DemoRepository(),
  );

  Future<void> pumpIncidentScreen(
    WidgetTester tester,
    FakeExternalActions actions,
  ) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: IncidentScreen(
        services: buildServices(actions),
        report: report,
        alreadyPaid: false,
        preparedLocally: true,
      ),
    ),
  );

  testWidgets('cancelling clipboard confirmation does not copy the report', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions actions = FakeExternalActions();
    await pumpIncidentScreen(tester, actions);

    await tester.tap(find.byKey(const Key('copy_report_button')));
    await tester.pumpAndSettle();

    expect(find.text('Copy incident draft?'), findsOneWidget);
    expect(
      find.text(
        'This will copy the incident draft to your device clipboard. Review it before sharing it with anyone.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(actions.copiedText, isNull);
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('confirming clipboard access copies the incident report', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions actions = FakeExternalActions();
    await pumpIncidentScreen(tester, actions);

    await tester.tap(find.byKey(const Key('copy_report_button')));
    await tester.pumpAndSettle();
    expect(actions.copiedText, isNull);

    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();

    expect(actions.copiedText, report);
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Incident draft copied.'), findsOneWidget);
  });
}
