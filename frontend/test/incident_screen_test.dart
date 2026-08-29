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
    FakeExternalActions actions, {
    bool alreadyPaid = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: IncidentScreen(
        services: buildServices(actions),
        report: report,
        alreadyPaid: alreadyPaid,
        preparedLocally: true,
      ),
    ),
  );

  testWidgets('prevention draft does not show the recovery clock', (
    WidgetTester tester,
  ) async {
    await pumpIncidentScreen(tester, FakeExternalActions());

    expect(find.byKey(const Key('golden_hour_card')), findsNothing);
    expect(find.text('When did the payment happen?'), findsNothing);
  });

  testWidgets('just-now recovery selection counts down', (
    WidgetTester tester,
  ) async {
    await pumpIncidentScreen(tester, FakeExternalActions(), alreadyPaid: true);

    await tester.tap(find.text('Just now'));
    await tester.pump();
    final Finder clock = find.byKey(const Key('recovery_clock'));
    expect(clock, findsOneWidget);
    final String initial = tester.widget<Text>(clock).data!;
    expect(initial, matches(RegExp(r'^about (59|60):\d{2} left$')));

    await tester.pump(const Duration(seconds: 3));
    final String afterThreeSeconds = tester.widget<Text>(clock).data!;
    expect(afterThreeSeconds, isNot(initial));
  });

  testWidgets('longer-ago selection encourages reporting without a countdown', (
    WidgetTester tester,
  ) async {
    await pumpIncidentScreen(tester, FakeExternalActions(), alreadyPaid: true);

    await tester.tap(find.text('Longer ago'));
    await tester.pump();
    expect(find.text('Report now'), findsOneWidget);
    expect(find.byKey(const Key('recovery_clock')), findsNothing);
    expect(find.byKey(const Key('call_1930_button')), findsOneWidget);
  });

  testWidgets('cancelling 1930 confirmation does not open the dialer', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions actions = FakeExternalActions();
    await pumpIncidentScreen(tester, actions, alreadyPaid: true);
    await tester.tap(find.text('Longer ago'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('call_1930_button')));
    await tester.pumpAndSettle();
    expect(find.text('Call 1930?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(actions.dialerOpenCount, 0);
  });

  testWidgets('tapping copy immediately copies the report without a dialog', (
    WidgetTester tester,
  ) async {
    // Clipboard copy is local and reversible, so it no longer sits behind a
    // confirmation modal (see the tiering note on `confirmAction`) — the
    // "Copied" snackbar and button-label swap are the feedback instead.
    final FakeExternalActions actions = FakeExternalActions();
    await pumpIncidentScreen(tester, actions);

    await tester.tap(find.byKey(const Key('copy_report_button')));
    await tester.pumpAndSettle();

    expect(find.text('Copy incident draft?'), findsNothing);
    expect(actions.copiedText, isNotNull);
    expect(find.text('Copied'), findsOneWidget);
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
