import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import 'api_service.dart';
import 'auth_api.dart';
import 'auth_controller.dart';
import 'auth_store.dart';
import 'demo_repository.dart';
import 'external_actions.dart';
import 'local_store.dart';
import 'share_intake.dart';
import 'threat_environment.dart';
import 'voice_api.dart';

final class AppServices {
  const AppServices({
    required this.api,
    required this.store,
    required this.externalActions,
    required this.demos,
    this.shareIntake = const NoopShareIntake(),
    this.threatEnvironment = const NoopThreatEnvironment(),
    this.auth,
    this.voice,
  });

  final FinGuardApi api;
  final LocalStore store;
  final ExternalActions externalActions;
  final DemoRepository demos;
  final ShareIntake shareIntake;
  final ThreatEnvironment threatEnvironment;
  final AuthController? auth;

  /// Optional spoken layer. Absent in tests and on any build that does not
  /// want it; the result screen simply omits the listen control.
  final VoiceApi? voice;

  factory AppServices.production() {
    final ApiService api = ApiService(baseUri: AppConfig.apiBaseUri);
    return AppServices(
      api: api,
      store: PreferencesLocalStore(),
      externalActions: PlatformExternalActions(),
      demos: const DemoRepository(),
      shareIntake: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? PlatformShareIntake()
          : const NoopShareIntake(),
      threatEnvironment:
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? const PlatformThreatEnvironment()
          : const NoopThreatEnvironment(),
      auth: AuthController(
        api: AuthApiService(baseUri: AppConfig.apiBaseUri),
        store: SecureAuthStore(),
      ),
      voice: VoiceApiService(baseUri: AppConfig.apiBaseUri),
    );
  }
}
