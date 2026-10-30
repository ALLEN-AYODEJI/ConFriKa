import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One device text-to-speech voice (as reported by the platform engine).
class SignVoice {
  final String name;
  final String locale;
  const SignVoice(this.name, this.locale);

  /// Best-effort gender from the voice name ('female' | 'male' | 'unknown').
  String get gender {
    final n = name.toLowerCase();
    if (RegExp(r'female|woman|\bzira\b|samantha|victoria|karen|moira|tessa|fiona|amelie|anna|aria|jenny|michelle|libby|sonia|catherine|serena')
        .hasMatch(n)) {
      return 'female';
    }
    if (RegExp(r'\bmale\b|\bman\b|david|daniel|\balex\b|fred|rishi|george|ryan|\bguy\b|eric|arthur|thabo')
        .hasMatch(n)) {
      return 'male';
    }
    // Many Android voices are named like "en-us-x-sfg#female_1-local".
    if (n.contains('female')) return 'female';
    if (n.contains('male')) return 'male';
    return 'unknown';
  }

  /// Whether this looks like an African-language or African-accent voice.
  bool get isAfrican {
    final l = locale.replaceAll('_', '-');
    final base = l.split('-').first.toLowerCase();
    final region = l.contains('-') ? l.split('-')[1].toUpperCase() : '';
    const bases = {
      'af', 'zu', 'xh', 'st', 'tn', 'ts', 'ss', 'nr', 've', 'nso', 'sw', 'am',
      'ha', 'yo', 'ig', 'so', 'rw', 'rn', 'sn', 'ny', 'lg', 'om', 'ti', 'wo',
      'ff', 'kg', 'ln', 'mg', 'sg',
    };
    const regions = {
      'ZA', 'NG', 'KE', 'GH', 'TZ', 'UG', 'ZW', 'ET', 'SN', 'CI', 'CM', 'CD',
      'ML', 'EG', 'MA', 'DZ', 'TN', 'LY', 'AO', 'MZ', 'RW', 'SO', 'BF', 'BJ',
      'BW', 'ZM', 'MW', 'NA', 'SD', 'NE', 'TD', 'GN', 'SL', 'LR', 'TG',
    };
    if (bases.contains(base) || regions.contains(region)) return true;
    return RegExp(r'africa|zulu|xhosa|afrikaans|swahili|amharic|hausa|yoruba|igbo|nigeria|kenya|ghana')
        .hasMatch(name.toLowerCase());
  }
}

/// Device text-to-speech for Sign Mode: voices a Deaf/non-speaking user's
/// composed or recognized signs aloud. On-device, no network, no cost.
///
/// Users can pick which voice speaks for them — male or female, and an
/// African-accent/language voice when the device has one installed. The choice
/// is persisted and applied to every utterance.
class SignSpeechService {
  static final SignSpeechService instance = SignSpeechService._();
  SignSpeechService._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  List<SignVoice> _voices = const [];
  SignVoice? _selected;
  String _filter = 'any'; // 'any' | 'female' | 'male' | 'african'

  static const _prefName = 'sign_voice_name';
  static const _prefLocale = 'sign_voice_locale';
  static const _prefFilter = 'sign_voice_filter';

  SignVoice? get selected => _selected;
  String get filter => _filter;

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
    await _restoreVoice();
  }

  /// All voices the device TTS engine offers.
  Future<List<SignVoice>> voices() async {
    await _ensure();
    if (_voices.isNotEmpty) return _voices;
    try {
      final raw = await _tts.getVoices;
      final list = <SignVoice>[];
      if (raw is List) {
        for (final v in raw) {
          if (v is Map) {
            final name = (v['name'] ?? '').toString();
            final locale = (v['locale'] ?? v['language'] ?? '').toString();
            if (name.isNotEmpty) list.add(SignVoice(name, locale));
          }
        }
      }
      // Stable, readable ordering: by locale then name.
      list.sort((a, b) {
        final c = a.locale.compareTo(b.locale);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
      _voices = list;
    } catch (e) {
      debugPrint('TTS getVoices failed: $e');
      _voices = const [];
    }
    return _voices;
  }

  /// Voices matching the current (or given) quick filter.
  Future<List<SignVoice>> voicesFiltered([String? filter]) async {
    final f = filter ?? _filter;
    final all = await voices();
    Iterable<SignVoice> out = all;
    if (f == 'female') {
      out = all.where((v) => v.gender == 'female');
    } else if (f == 'male') {
      out = all.where((v) => v.gender == 'male');
    } else if (f == 'african') {
      out = all.where((v) => v.isAfrican);
    }
    final result = out.toList();
    return result.isEmpty ? all : result; // never show an empty picker
  }

  Future<void> setFilter(String filter) async {
    _filter = filter;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefFilter, filter);
    } catch (_) {}
  }

  /// Choose the speaking voice and persist it.
  Future<void> selectVoice(SignVoice voice) async {
    _selected = voice;
    await _ensure();
    try {
      await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
    } catch (e) {
      debugPrint('TTS setVoice failed: $e');
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefName, voice.name);
      await p.setString(_prefLocale, voice.locale);
    } catch (_) {}
  }

  Future<void> _restoreVoice() async {
    try {
      final p = await SharedPreferences.getInstance();
      _filter = p.getString(_prefFilter) ?? 'any';
      final name = p.getString(_prefName);
      final locale = p.getString(_prefLocale);
      if (name != null && name.isNotEmpty) {
        _selected = SignVoice(name, locale ?? '');
        await _tts.setVoice({'name': name, 'locale': locale ?? ''});
      }
    } catch (e) {
      debugPrint('TTS restore voice failed: $e');
    }
  }

  /// Speak [text] aloud using the selected voice (if any). When no voice is
  /// chosen, [languageCode] (BCP-47) selects the language; the engine falls
  /// back to its default if that locale is unavailable.
  Future<void> speak(String text, {String languageCode = 'en-US'}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _ensure();
    try {
      if (_selected != null) {
        await _tts.setVoice({'name': _selected!.name, 'locale': _selected!.locale});
      } else {
        await _tts.setLanguage(languageCode);
      }
    } catch (_) {/* unsupported locale/voice — keep current */}
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
