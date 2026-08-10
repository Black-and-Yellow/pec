import '../config/app_config.dart';
import 'api_service.dart';
import 'auth_api.dart';
import 'auth_controller.dart';
import 'auth_store.dart';
import 'demo_repository.dart';
import 'external_actions.dart';
import 'local_store.dart';

final class AppServices {
  const AppServices({
    required this.api,
    required this.store,
    required this.externalActions,
    required this.demos,
    this.auth,
  });

  final FinGuardApi api;
  final LocalStore store;
  final ExternalActions externalActions;
  final DemoRepository demos;
  final AuthController? auth;

  factory AppServices.production() {
    final ApiService api = ApiService(baseUri: AppConfig.apiBaseUri);
    return AppServices(
      api: api,
      store: PreferencesLocalStore(),
      externalActions: PlatformExternalActions(),
      demos: const DemoRepository(),
      auth: AuthController(
        api: AuthApiService(baseUri: AppConfig.apiBaseUri),
        store: SecureAuthStore(),
      ),
    );
  }
}
