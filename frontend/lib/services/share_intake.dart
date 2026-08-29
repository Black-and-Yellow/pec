import 'dart:async';

import 'package:flutter/services.dart';

const int maxSharedTextLength = 5000;

abstract interface class ShareIntake {
  Future<String?> initialShare();

  Stream<String> shares();
}

final class PlatformShareIntake implements ShareIntake {
  PlatformShareIntake() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const MethodChannel _channel = MethodChannel('org.pec.finguard/share');

  final StreamController<String> _shares = StreamController<String>.broadcast();

  @override
  Future<String?> initialShare() async {
    final Object? shared = await _channel.invokeMethod<Object?>(
      'getInitialShare',
    );
    return shared is String ? normalizeSharedText(shared) : null;
  }

  @override
  Stream<String> shares() => _shares.stream;

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onShare' || call.arguments is! String) {
      return;
    }
    final String? shared = normalizeSharedText(call.arguments as String);
    if (shared != null) {
      _shares.add(shared);
    }
  }
}

final class NoopShareIntake implements ShareIntake {
  const NoopShareIntake();

  @override
  Future<String?> initialShare() async => null;

  @override
  Stream<String> shares() => const Stream<String>.empty();
}

String? normalizeSharedText(String? value) {
  if (value == null) {
    return null;
  }
  final String bounded = value.length <= maxSharedTextLength
      ? value
      : value.substring(0, maxSharedTextLength);
  return bounded.trim().isEmpty ? null : bounded;
}
