import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network/api_client.dart';
import 'services/entitlement_service.dart';

/// Holds the authenticated user and JWT, persisted across launches.
class ConFriKaSession extends ChangeNotifier {
  static final ConFriKaSession instance = ConFriKaSession._();
  ConFriKaSession._();

  static const _kToken = 'confrika_token';
  static const _kUser = 'confrika_user';
  static const _kPrefLang = 'confrika_preferred_language';

  String? _token;
  Map<String, dynamic>? _user;
  String? _preferredLanguage;

  bool get isAuthenticated => _token != null && _user != null;
  Map<String, dynamic>? get user => _user;
  String get displayName => (_user?['full_name'] as String?)?.trim().isNotEmpty == true
      ? _user!['full_name'] as String
      : (_user?['username'] as String? ?? 'You');
  String get username => _user?['username'] as String? ?? '';
  String get primaryDialect => _user?['primary_dialect'] as String? ?? 'English';
  String get countryCode => _user?['country_code'] as String? ?? '';
  double get f0BaselineHz => ((_user?['f0_baseline_hz'] as num?) ?? 138.0).toDouble();

  /// The language the user wants to read/listen to others in. Defaults to the
  /// language they speak until they pick one in the top-bar selector.
  String get preferredLanguage =>
      (_preferredLanguage?.trim().isNotEmpty == true)
          ? _preferredLanguage!
          : primaryDialect;

  Future<void> setPreferredLanguage(String language) async {
    _preferredLanguage = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefLang, language);
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_kToken);
    _preferredLanguage = prefs.getString(_kPrefLang);
    final userJson = prefs.getString(_kUser);
    if (userJson != null) {
      try {
        _user = jsonDecode(userJson) as Map<String, dynamic>;
      } catch (_) {
        _user = null;
      }
    }
    if (_token != null) ConFriKaApiClient.instance.setAuthToken(_token);
    notifyListeners();
  }

  Future<void> setAuthenticated(String token, Map<String, dynamic> user) async {
    _token = token;
    _user = user;
    ConFriKaApiClient.instance.setAuthToken(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, token);
    await prefs.setString(_kUser, jsonEncode(user));
    notifyListeners();
  }

  Future<void> updateUser(Map<String, dynamic> user) async {
    _user = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUser, jsonEncode(user));
    notifyListeners();
  }

  Future<void> signOut() async {
    _token = null;
    _user = null;
    ConFriKaApiClient.instance.setAuthToken(null);
    EntitlementService.instance.reset();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUser);
    notifyListeners();
  }
}
