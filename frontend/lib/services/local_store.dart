import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_entry.dart';

abstract interface class LocalStore {
  Future<String> deviceId();

  Future<List<HistoryEntry>> history();

  Future<void> addHistory(HistoryEntry entry);

  Future<void> clearHistory();
}

final class PreferencesLocalStore implements LocalStore {
  PreferencesLocalStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const String _deviceKey = 'anonymous_device_id_v1';
  static const String _historyKey = 'local_check_history_v1';
  static const int _maxHistoryEntries = 20;

  final SharedPreferencesAsync _preferences;
  String? _cachedDeviceId;

  @override
  Future<String> deviceId() async {
    final String? cached = _cachedDeviceId;
    if (cached != null) {
      return cached;
    }
    try {
      final String? existing = await _preferences.getString(_deviceKey);
      if (existing != null && existing.isNotEmpty) {
        _cachedDeviceId = existing;
        return existing;
      }
    } on Object {
      // A transient storage failure must not prevent a pre-payment safety check.
    }
    final String value = _newAnonymousDeviceId();
    _cachedDeviceId = value;
    try {
      await _preferences.setString(_deviceKey, value);
    } on Object {
      // The in-memory identifier keeps this app session usable without persistence.
    }
    return value;
  }

  String _newAnonymousDeviceId() {
    final Random random = Random.secure();
    final String randomPart = List<int>.generate(
      12,
      (int _) => random.nextInt(256),
    ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'device_${DateTime.now().microsecondsSinceEpoch}_$randomPart';
  }

  @override
  Future<List<HistoryEntry>> history() async {
    String? encoded;
    try {
      encoded = await _preferences.getString(_historyKey);
    } on Object {
      return const <HistoryEntry>[];
    }
    if (encoded == null || encoded.isEmpty) {
      return const <HistoryEntry>[];
    }
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! List<Object?>) {
        return const <HistoryEntry>[];
      }
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> item) => HistoryEntry.fromJson(
              item.map(
                (Object? key, Object? value) => MapEntry(key.toString(), value),
              ),
            ),
          )
          .toList(growable: false);
    } on Object {
      return const <HistoryEntry>[];
    }
  }

  @override
  Future<void> addHistory(HistoryEntry entry) async {
    final List<HistoryEntry> entries = <HistoryEntry>[
      entry,
      ...await history(),
    ].take(_maxHistoryEntries).toList(growable: false);
    try {
      await _preferences.setString(
        _historyKey,
        jsonEncode(entries.map((HistoryEntry item) => item.toJson()).toList()),
      );
    } on Object {
      // Browser privacy modes may block persistence; the safety result still remains usable.
    }
  }

  @override
  Future<void> clearHistory() async {
    try {
      await _preferences.remove(_historyKey);
    } on Object {
      // There is no local data to clear when the platform store is unavailable.
    }
  }
}

final class MemoryLocalStore implements LocalStore {
  MemoryLocalStore({this.fixedDeviceId = 'test-device'});

  final String fixedDeviceId;
  final List<HistoryEntry> _entries = <HistoryEntry>[];

  @override
  Future<void> addHistory(HistoryEntry entry) async {
    _entries.insert(0, entry);
  }

  @override
  Future<void> clearHistory() async {
    _entries.clear();
  }

  @override
  Future<String> deviceId() async => fixedDeviceId;

  @override
  Future<List<HistoryEntry>> history() async =>
      List<HistoryEntry>.unmodifiable(_entries);
}
