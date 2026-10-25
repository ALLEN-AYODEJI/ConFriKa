import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Thrown when the backend returns a non-success status or is unreachable.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// Real HTTP client for the ConFriKa backend. No demo/offline fallbacks —
/// callers get real data or a real error.
class ConFriKaApiClient {
  static final ConFriKaApiClient instance = ConFriKaApiClient._();
  ConFriKaApiClient._();

  final String baseUrl = AppConfig.apiBaseUrl;
  String? _authToken;

  void setAuthToken(String? token) => _authToken = token;
  String? get authToken => _authToken;

  Map<String, String> get _headers {
    final map = {'Content-Type': 'application/json', 'Accept': 'application/json'};
    if (_authToken != null) map['Authorization'] = 'Bearer $_authToken';
    return map;
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) =>
      Uri.parse('$baseUrl$path').replace(
        queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
      );

  Never _fail(http.Response res) {
    // Surface only the server's human-readable `detail` (e.g. "User not found",
    // "Invalid credentials", "You've reached today's limit"). Never leak raw
    // response bodies or status codes to the user.
    String? detail;
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['detail'] != null) {
        detail = body['detail'].toString();
      }
    } catch (_) {/* non-JSON body */}
    final msg = (detail != null && detail.trim().isNotEmpty)
        ? detail
        : 'Something went wrong. Please try again.';
    throw ApiException(res.statusCode, msg);
  }

  Future<dynamic> _get(String path, [Map<String, dynamic>? query]) async {
    try {
      final res = await http
          .get(_uri(path, query), headers: _headers)
          .timeout(const Duration(seconds: 40));
      if (res.statusCode >= 200 && res.statusCode < 300) return jsonDecode(res.body);
      _fail(res);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Connection problem. Please check your internet and try again.');
    }
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    try {
      final res = await http
          .post(_uri(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res.body.isEmpty ? null : jsonDecode(res.body);
      }
      _fail(res);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Connection problem. Please check your internet and try again.');
    }
  }

  Future<dynamic> _put(String path, Map<String, dynamic> body) async {
    try {
      final res = await http
          .put(_uri(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res.body.isEmpty ? null : jsonDecode(res.body);
      }
      _fail(res);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Connection problem. Please check your internet and try again.');
    }
  }

  Future<dynamic> _delete(String path) async {
    try {
      final res = await http
          .delete(_uri(path), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res.body.isEmpty ? null : jsonDecode(res.body);
      }
      _fail(res);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Connection problem. Please check your internet and try again.');
    }
  }

  // ── Health ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> health() async =>
      (await _get('/health')) as Map<String, dynamic>;

  // ── Auth ──────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> signUp({
    required String email,
    required String password,
    required String fullName,
    required String username,
    required String countryCode,
    required String originRegion,
    required String primaryDialect,
  }) async {
    // Signup now starts email verification; it returns {status, email, ...}
    // and no token. The token is issued by verifyEmail once the OTP is entered.
    return (await _post('/api/v1/auth/signup', {
      'email': email,
      'password': password,
      'full_name': fullName,
      'username': username,
      'country_code': countryCode,
      'origin_region': originRegion,
      'primary_dialect': primaryDialect,
    })) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> verifyEmail({
    required String email,
    required String code,
  }) async {
    final data = await _post('/api/v1/auth/verify-email', {
      'email': email,
      'code': code,
    }) as Map<String, dynamic>;
    setAuthToken(data['access_token'] as String?);
    return data;
  }

  Future<Map<String, dynamic>> resendOtp(String email) async =>
      (await _post('/api/v1/auth/resend-otp', {'email': email})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> forgotPassword(String email) async =>
      (await _post('/api/v1/auth/forgot-password', {'email': email})) as Map<String, dynamic>;

  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _post('/api/v1/auth/reset-password', {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  /// Email the signed-in user an OTP authorizing a password change.
  Future<Map<String, dynamic>> requestChangePasswordOtp() async =>
      (await _post('/api/v1/auth/change-password/request-otp', {}))
          as Map<String, dynamic>;

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    required String code,
  }) async {
    await _post('/api/v1/auth/change-password', {
      'current_password': currentPassword,
      'new_password': newPassword,
      'code': code,
    });
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> fields) async =>
      (await _put('/api/v1/auth/me', fields)) as Map<String, dynamic>;

  /// Register this device's push (FCM) token for message & call alerts.
  Future<void> registerDevice(String token, {String platform = 'android'}) async {
    await _post('/api/v1/auth/me/devices', {'token': token, 'platform': platform});
  }

  /// Permanently delete the signed-in user's account (requires the password).
  Future<void> deleteAccount(String password) async {
    await _post('/api/v1/auth/delete-account', {'password': password});
  }

  /// Update reachability/privacy controls. Returns the refreshed user profile.
  Future<Map<String, dynamic>> updatePrivacy({
    String? callsPrivacy,
    String? messagesPrivacy,
    bool? allowImages,
  }) async {
    return (await _put('/api/v1/auth/me/privacy', {
      if (callsPrivacy != null) 'calls_privacy': callsPrivacy,
      if (messagesPrivacy != null) 'messages_privacy': messagesPrivacy,
      if (allowImages != null) 'allow_images': allowImages,
    })) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login({
    required String emailOrUsername,
    required String password,
  }) async {
    final data = await _post('/api/v1/auth/login', {
      'email_or_username': emailOrUsername,
      'password': password,
    }) as Map<String, dynamic>;
    setAuthToken(data['access_token'] as String?);
    return data;
  }

  Future<Map<String, dynamic>> me() async =>
      (await _get('/api/v1/auth/me')) as Map<String, dynamic>;

  /// Real learning progress (streak, words learned, XP) derived from activity.
  Future<Map<String, dynamic>> meStats() async =>
      (await _get('/api/v1/auth/me/stats')) as Map<String, dynamic>;

  Future<void> updateTonalBaseline(double f0Hz) async {
    await _put('/api/v1/auth/me/tonal-baseline', {'f0_baseline_hz': f0Hz});
  }

  // ── Translation ─────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> translate({
    required String text,
    required String sourceDialect,
    required String targetDialect,
    String formality = 'respectful',
  }) async {
    return (await _post('/api/v1/speech/translate', {
      'text': text,
      'source_dialect': sourceDialect,
      'target_dialect': targetDialect,
      'respect_tones': true,
      'formality': formality,
    })) as Map<String, dynamic>;
  }

  // ── Call history ──────────────────────────────────────────────────────
  Future<List<dynamic>> callHistory() async =>
      (await _get('/api/v1/calls/history')) as List<dynamic>;

  Future<void> recordCallOutcome(
      String sessionId, {required bool connected, int durationSeconds = 0}) async {
    await _post('/api/v1/calls/${Uri.encodeComponent(sessionId)}/outcome', {
      'connected': connected,
      'duration_seconds': durationSeconds,
    });
  }

  // ── Live call translation (voice) ─────────────────────────────────────
  Future<Map<String, dynamic>> voiceStatus() async =>
      (await _get('/api/v1/calls/voice/status')) as Map<String, dynamic>;

  /// Enroll a voice clone from a recording; returns {status, voice_id}.
  Future<Map<String, dynamic>> enrollVoice(String wavPath) async {
    final req = http.MultipartRequest('POST', _uri('/api/v1/calls/voice/enroll'));
    if (_authToken != null) req.headers['Authorization'] = 'Bearer $_authToken';
    req.files.add(await http.MultipartFile.fromPath('file', wavPath));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    _fail(res);
  }

  /// Translate one spoken utterance; returns source/translated text + audio_b64
  /// (spoken in the caller's voice when a clone is enrolled).
  Future<Map<String, dynamic>> translateUtterance({
    required String audioBase64,
    required String sourceDialect,
    required String targetDialect,
  }) async {
    return (await _post('/api/v1/calls/translate-utterance', {
      'audio_b64': audioBase64,
      'source_dialect': sourceDialect,
      'target_dialect': targetDialect,
    })) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> analyzePitch(String wavPath,
      {double baselineF0Hz = 138.0}) async {
    final req = http.MultipartRequest(
      'POST',
      _uri('/api/v1/speech/pitch-analysis', {'baseline_f0_hz': baselineF0Hz}),
    );
    if (_authToken != null) req.headers['Authorization'] = 'Bearer $_authToken';
    req.files.add(await http.MultipartFile.fromPath('audio', wavPath));
    try {
      final streamed = await req.send().timeout(const Duration(seconds: 30));
      final res = await http.Response.fromStream(streamed);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      _fail(res);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Connection problem. Please check your internet and try again.');
    }
  }

  // ── Contacts ──────────────────────────────────────────────────────────
  Future<List<dynamic>> contacts() async =>
      (await _get('/api/v1/contacts')) as List<dynamic>;

  Future<Map<String, dynamic>> addContact(String username,
      {String? alias, String? preferredLanguage}) async {
    return (await _post('/api/v1/contacts', {
      'username': username,
      if (alias != null) 'alias_name': alias,
      if (preferredLanguage != null) 'preferred_language': preferredLanguage,
    })) as Map<String, dynamic>;
  }

  Future<List<dynamic>> searchDirectory(String query) async =>
      (await _get('/api/v1/contacts/search', {'q': query})) as List<dynamic>;

  // ── Media ─────────────────────────────────────────────────────────────
  /// Build a full URL from a server-relative media path like "/media/x.png".
  String mediaUrl(String path) =>
      path.startsWith('http') ? path : '$baseUrl$path';

  Future<String> _uploadMultipart(http.MultipartFile file) async {
    final req = http.MultipartRequest('POST', _uri('/api/v1/media/upload'));
    if (_authToken != null) req.headers['Authorization'] = 'Bearer $_authToken';
    req.files.add(file);
    try {
      final streamed = await req.send().timeout(const Duration(seconds: 45));
      final res = await http.Response.fromStream(streamed);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return (jsonDecode(res.body) as Map<String, dynamic>)['url'] as String;
      }
      _fail(res);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'Upload failed. Please try again.');
    }
  }

  /// Upload a plaintext image file; returns its server-relative URL.
  Future<String> uploadImage(String filePath) async =>
      _uploadMultipart(await http.MultipartFile.fromPath('file', filePath));

  /// Upload an already-encrypted image blob (octet-stream); returns its URL.
  Future<String> uploadEncryptedBlob(List<int> bytes) async =>
      _uploadMultipart(
          http.MultipartFile.fromBytes('file', bytes, filename: 'img.bin'));

  /// Download raw bytes from a media URL (for encrypted image blobs).
  Future<List<int>> downloadBytes(String path) async {
    final res = await http
        .get(Uri.parse(mediaUrl(path)), headers: {
          if (_authToken != null) 'Authorization': 'Bearer $_authToken'
        })
        .timeout(const Duration(seconds: 30));
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    throw ApiException(res.statusCode, 'Could not load image');
  }

  // ── Chat ──────────────────────────────────────────────────────────────
  /// WhatsApp-style conversation list: one entry per DM partner.
  Future<List<dynamic>> conversations() async =>
      (await _get('/api/v1/chat/conversations')) as List<dynamic>;

  Future<List<dynamic>> directMessages(String username) async =>
      (await _get('/api/v1/chat/dm/${Uri.encodeComponent(username)}')) as List<dynamic>;

  Future<void> markThreadRead(String username) async {
    await _post('/api/v1/chat/dm/${Uri.encodeComponent(username)}/read', {});
  }

  // ── E2E encryption key exchange ───────────────────────────────────────
  Future<void> uploadPublicKey(String publicKey) async {
    await _put('/api/v1/chat/keys/me', {'public_key': publicKey});
  }

  /// Fetch a user's E2E key info: {public_key, primary_dialect, full_name}.
  /// public_key is null if they haven't registered one.
  Future<Map<String, dynamic>> peerKeyInfo(String username) async =>
      (await _get('/api/v1/chat/keys/${Uri.encodeComponent(username)}'))
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> sendEncryptedDirectMessage({
    required String recipientUsername,
    required String ciphertext,
    required String senderPub,
    required String sourceDialect,
    String? targetDialect,
    String messageType = 'text',
    String? replyToId,
  }) async {
    return (await _post('/api/v1/chat/dm', {
      'recipient_username': recipientUsername,
      'message_type': messageType,
      'is_encrypted': true,
      'ciphertext': ciphertext,
      'sender_pub': senderPub,
      if (replyToId != null) 'reply_to_id': replyToId,
      'source_dialect': sourceDialect,
      if (targetDialect != null) 'target_dialect': targetDialect,
      'auto_translate': false,
    })) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendDirectMessage({
    required String recipientUsername,
    String? text,
    required String sourceDialect,
    String? targetDialect,
    String messageType = 'text',
    String? mediaUrl,
    String? replyToId,
    String? replySnippet,
    String? replySender,
    bool autoTranslate = true,
  }) async {
    return (await _post('/api/v1/chat/dm', {
      'recipient_username': recipientUsername,
      'message_type': messageType,
      if (text != null) 'original_text': text,
      if (mediaUrl != null) 'media_url': mediaUrl,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (replySnippet != null) 'reply_snippet': replySnippet,
      if (replySender != null) 'reply_sender': replySender,
      'source_dialect': sourceDialect,
      if (targetDialect != null) 'target_dialect': targetDialect,
      'auto_translate': autoTranslate,
    })) as Map<String, dynamic>;
  }

  Future<List<dynamic>> spaces({String channel = 'all', String country = 'ALL'}) async =>
      (await _get('/api/v1/chat/spaces', {'channel': channel, 'country': country}))
          as List<dynamic>;

  // ── Communities ───────────────────────────────────────────────────────
  Future<List<dynamic>> communities() async =>
      (await _get('/api/v1/communities')) as List<dynamic>;

  Future<Map<String, dynamic>> createCommunity({
    required String name,
    String? description,
    String icon = '🌍',
    String category = 'general',
  }) async =>
      (await _post('/api/v1/communities', {
        'name': name,
        if (description != null) 'description': description,
        'icon': icon,
        'category': category,
      })) as Map<String, dynamic>;

  Future<void> joinCommunity(String slug) async {
    await _post('/api/v1/communities/${Uri.encodeComponent(slug)}/join', {});
  }

  Future<void> leaveCommunity(String slug) async {
    await _post('/api/v1/communities/${Uri.encodeComponent(slug)}/leave', {});
  }

  Future<void> deleteCommunity(String slug) async {
    await _delete('/api/v1/communities/${Uri.encodeComponent(slug)}');
  }

  Future<Map<String, dynamic>> postSpaces({
    String text = '',
    required String sourceDialect,
    String channel = 'all',
    String country = 'ALL',
    String messageType = 'text',
    String? mediaUrl,
    String? replyToId,
    String? replySnippet,
    String? replySender,
    bool autoTranslate = true,
  }) async {
    return (await _post('/api/v1/chat/spaces', {
      'original_text': text,
      'message_type': messageType,
      if (mediaUrl != null) 'media_url': mediaUrl,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (replySnippet != null) 'reply_snippet': replySnippet,
      if (replySender != null) 'reply_sender': replySender,
      'source_dialect': sourceDialect,
      'channel_category': channel,
      'country_filter': country,
      'auto_translate': autoTranslate,
    })) as Map<String, dynamic>;
  }

  // ── Tone coach ──────────────────────────────────────────────────────────
  Future<List<dynamic>> tonalLanguages() async =>
      (await _get('/api/v1/tone-coach/languages')) as List<dynamic>;

  Future<List<dynamic>> minimalPairs({String? language}) async =>
      (await _get('/api/v1/tone-coach/minimal-pairs',
          language != null ? {'language': language} : null)) as List<dynamic>;

  /// Native speakers add a word in any tonal language and record its pitch.
  Future<Map<String, dynamic>> teachToneWord({
    required String language,
    required String spelling,
    required String meaning,
    String? tonePattern,
    required List<double> semitones,
  }) async {
    return (await _post('/api/v1/tone-coach/teach', {
      'language': language,
      'spelling': spelling,
      'meaning': meaning,
      if (tonePattern != null) 'tone_pattern': tonePattern,
      'semitones': semitones,
    })) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> calibrateTone({
    required String targetWordId,
    required List<double> learnerSemitones,
    double baselineF0Hz = 138.0,
  }) async {
    return (await _post('/api/v1/tone-coach/calibrate', {
      'user_baseline_f0_hz': baselineF0Hz,
      'target_word_id': targetWordId,
      'learner_semitones': learnerSemitones,
    })) as Map<String, dynamic>;
  }

  /// Native speakers submit a reference pronunciation the app learns from.
  Future<Map<String, dynamic>> contributeNativeTone({
    required String targetWordId,
    required List<double> nativeSemitones,
    double? meanF0Hz,
  }) async {
    return (await _post('/api/v1/tone-coach/contribute', {
      'target_word_id': targetWordId,
      'native_semitones': nativeSemitones,
      if (meanF0Hz != null) 'mean_f0_hz': meanF0Hz,
    })) as Map<String, dynamic>;
  }

  // ── Calls ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> iceServers() async =>
      (await _get('/api/v1/calls/ice-servers')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> initiateCall(String calleeUsername,
      {String transport = 'inapp', String? sdpOffer}) async {
    return (await _post('/api/v1/calls/initiate', {
      'callee_username': calleeUsername,
      'call_transport': transport,
      if (sdpOffer != null) 'sdp_offer': sdpOffer,
    })) as Map<String, dynamic>;
  }

  // ── Billing / ConFriKa Pro ────────────────────────────────────────────
  Future<Map<String, dynamic>> entitlements() async =>
      (await _get('/api/v1/billing/entitlements')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> verifyPurchase({
    required String platform,
    required String productId,
    required String token,
  }) async =>
      (await _post('/api/v1/billing/verify', {
        'platform': platform,
        'product_id': productId,
        'token': token,
      })) as Map<String, dynamic>;
}
