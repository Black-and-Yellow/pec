import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(FinGuardApp(services: AppServices.production()));
}
