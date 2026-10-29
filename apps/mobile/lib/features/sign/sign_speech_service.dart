import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Device text-to-speech for Sign Mode: voices a Deaf/non-speaking user's
/// composed signs aloud so a hearing person next to them (or on a call's
/// loudspeaker) can hear it. On-device, no network, no cost.
class SignSpeechService {
  static final SignSpeechService instance = SignSpeechService._();
  SignSpeechService._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  Future<void> _ensure() async {
    if (_ready) return;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5); // natural, intelligible pace
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (e) {
      debugPrint('TTS init failed: $e');
    }
    _ready = true;
  }

  /// Speak [text] aloud. [languageCode] is a BCP-47 tag (e.g. 'en-US', 'fr-FR');
  /// if the device lacks that voice, the engine falls back to its default.
  Future<void> speak(String text, {String languageCode = 'en-US'}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _ensure();
    try {
      await _tts.setLanguage(languageCode);
    } catch (_) {/* unsupported locale — keep current voice */}
    try {
      await _tts.stop();
      await _tts.speak(t);
    } catch (e) {
      debugPrint('TTS speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
