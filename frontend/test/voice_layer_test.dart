import 'dart:typed_data';

import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/services/voice_api.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:finguard/widgets/listen_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// A voice backend that never reaches the network.
final class FakeVoiceApi implements VoiceApi {
  FakeVoiceApi({
    this.languages = const <VoiceLanguage>[
      VoiceLanguage(code: 'hi', label: 'हिंदी'),
      VoiceLanguage(code: 'ta', label: 'தமிழ்'),
    ],
    this.failure,
  });

  final List<VoiceLanguage> languages;
  final VoiceException? failure;
  final List<(RiskLevel, int, String)> requests = <(RiskLevel, int, String)>[];

  @override
  Future<List<VoiceLanguage>> availableLanguages() async => languages;

  @override
  Future<Uint8List> speak({
    required RiskLevel level,
    required int score,
    required String language,
  }) async {
    requests.add((level, score, language));
    if (failure case final VoiceException error) {
      throw error;
    }
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}

final class FakeVoicePlayer implements VoicePlayer {
  int playCount = 0;
  bool disposed = false;

  @override
  Future<void> play(Uint8List audio) async {
    playCount += 1;
  }

  @override
  Future<void> stop() async {}

  @override
  void dispose() {
    disposed = true;
  }
}

const RiskAssessment _highRisk = RiskAssessment(
  assessmentId: 'assessment-voice',
  score: 82,
  level: RiskLevel.highRisk,
  signals: <RiskSignal>[
    RiskSignal(
      code: 'SEEDED_FRAUD_MATCH',
      label: 'Reported recipient',
      weight: 40,
      evidence: 'The recipient appears in the labelled indicator list',
    ),
  ],
  recommendedAction: 'Stop the UPI handoff and verify independently.',
);

const Payment _payment = Payment(
  upiUri: 'upi://pay?pa=scam.payee%40okaxis&am=4500&cu=INR',
  payeeVpa: 'scam.payee@okaxis',
  amount: 4500,
  currency: 'INR',
);

AppServices _services({VoiceApi? voice}) => AppServices(
  api: FakeApi(),
  store: MemoryLocalStore(),
  externalActions: FakeExternalActions(),
  demos: const DemoRepository(),
  voice: voice,
);

Widget _screen(AppServices services) => MaterialApp(
  theme: AppTheme.light,
  home: RiskResultScreen(
    services: services,
    payment: _payment,
    assessment: _highRisk,
    paymentHandoffEnabled: true,
  ),
);

void main() {
  testWidgets('a build with no voice service shows no listen control', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_screen(_services()));
    await tester.pump();

    expect(find.byKey(const Key('listen_button')), findsNothing);
  });

  testWidgets('a backend that speaks nothing draws nothing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        _services(voice: FakeVoiceApi(languages: const <VoiceLanguage>[])),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('listen_button')), findsNothing);
  });

  testWidgets('offered languages appear in their own script', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_screen(_services(voice: FakeVoiceApi())));
    await tester.pump();

    expect(find.byKey(const Key('listen_button')), findsOneWidget);
    expect(find.text('हिंदी'), findsOneWidget);
    expect(find.text('தமிழ்'), findsOneWidget);
  });

  testWidgets('the spoken request carries the verdict shown on screen', (
    WidgetTester tester,
  ) async {
    final FakeVoiceApi voice = FakeVoiceApi();
    await tester.pumpWidget(_screen(_services(voice: voice)));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const Key('listen_ta')),
      120,
    );
    await tester.tap(find.byKey(const Key('listen_ta')));
    await tester.pump();
    await tester.pump();

    expect(voice.requests, <(RiskLevel, int, String)>[
      (RiskLevel.highRisk, 82, 'ta'),
    ]);
  });

  testWidgets('a voice failure never disturbs the written verdict', (
    WidgetTester tester,
  ) async {
    final FakeVoiceApi voice = FakeVoiceApi(
      failure: const VoiceException('Spoken guidance is unavailable.'),
    );
    await tester.pumpWidget(_screen(_services(voice: voice)));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const Key('listen_hi')),
      120,
    );
    await tester.tap(find.byKey(const Key('listen_hi')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('listen_failure')), findsOneWidget);
    // The verdict, the score and the recommended action are all still there.
    expect(find.text('Strong warning signals found'), findsOneWidget);
    expect(find.byKey(const Key('risk_score')), findsOneWidget);
    expect(
      find.text('Stop the UPI handoff and verify independently.'),
      findsOneWidget,
    );
  });

  testWidgets('audio plays when the backend answers', (
    WidgetTester tester,
  ) async {
    final FakeVoicePlayer player = FakeVoicePlayer();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ListenButton(
            voice: FakeVoiceApi(),
            player: player,
            level: RiskLevel.highRisk,
            score: 82,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('listen_hi')));
    await tester.pumpAndSettle();

    expect(player.playCount, 1);
    expect(find.byKey(const Key('listen_failure')), findsNothing);
  });

  test('an unreachable backend offers no languages instead of throwing', () async {
    final VoiceApiService service = VoiceApiService(
      baseUri: Uri.parse('http://127.0.0.1:1/'),
      timeout: const Duration(milliseconds: 200),
    );

    expect(await service.availableLanguages(), isEmpty);
  });
}
