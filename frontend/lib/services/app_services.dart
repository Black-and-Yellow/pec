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

final class AppServices {
  const AppServices({
    required this.api,
    required this.store,
    required this.externalActions,
    required this.demos,
    this.shareIntake = const NoopShareIntake(),
    this.auth,
  });

  final FinGuardApi api;
  final LocalStore store;
  final ExternalActions externalActions;
  final DemoRepository demos;
  final ShareIntake shareIntake;
  final AuthController? auth;

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
      auth: AuthController(
        api: AuthApiService(baseUri: AppConfig.apiBaseUri),
        store: SecureAuthStore(),
      ),
    );
  }
}
