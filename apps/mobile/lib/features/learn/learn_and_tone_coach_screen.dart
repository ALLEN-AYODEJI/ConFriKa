import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../core/network/api_client.dart';
import '../../core/session.dart';
import '../../core/theme/confrika_theme.dart';

class LearnAndToneCoachScreen extends StatefulWidget {
  const LearnAndToneCoachScreen({super.key});

  @override
  State<LearnAndToneCoachScreen> createState() => _LearnAndToneCoachScreenState();
}

class _LearnAndToneCoachScreenState extends State<LearnAndToneCoachScreen> {
  final _api = ConFriKaApiClient.instance;
  List<dynamic> _pairs = [];
  List<Map<String, dynamic>> _languages = [];
  String _language = 'Yoruba';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final langs = (await _api.tonalLanguages()).cast<Map<String, dynamic>>();
      // Default to the user's own tonal language if it's in the catalogue.
      final mine = ConFriKaSession.instance.primaryDialect.split(' ').first.toLowerCase();
      final match = langs.firstWhere(
        (l) => (l['name'] as String).toLowerCase().contains(mine) && mine.length > 2,
        orElse: () => langs.isNotEmpty ? langs.first : {'name': 'Yoruba'},
      );
      if (mounted) {
        setState(() {
          _languages = langs;
          _language = match['name'] as String? ?? 'Yoruba';
        });
      }
    } catch (_) {}
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pairs = await _api.minimalPairs(language: _language);
      if (!mounted) return;
      setState(() {
        _pairs = pairs;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _pairs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 10),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final native = _isNativeSpeaker;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Tonal Coach',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(
            native
                ? 'You speak a tonal dialect. Practise to see your pitch live, and tap '
                    '“Teach” to add your native pronunciation so others learn from you.'
                : 'Tap Practice and say the word. Your pitch (F0) is tracked live so you '
                    'can see it rise and fall, with on-the-spot guidance and a match score.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 14),
          _languagePicker(),
          const SizedBox(height: 12),
          ..._pairs.map((p) => _TonePracticeCard(
                pair: p as Map<String, dynamic>,
                isNative: native,
              )),
          if (_pairs.isEmpty) _emptyState(native),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _openTeachSheet(),
            icon: const Icon(Icons.add),
            label: Text('Teach a word in $_language'),
          ),
        ],
      ),
    );
  }

  Widget _languagePicker() {
    final names = _languages.isEmpty
        ? [_language]
        : _languages.map((l) => l['name'] as String).toList();
    if (!names.contains(_language)) names.insert(0, _language);
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Language',
        prefixIcon: Icon(Icons.record_voice_over_outlined),
        border: OutlineInputBorder(),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _language,
          isExpanded: true,
          items: names
              .map((n) => DropdownMenuItem(value: n, child: Text(n)))
              .toList(),
          onChanged: (v) {
            if (v == null || v == _language) return;
            setState(() => _language = v);
            _load();
          },
        ),
      ),
    );
  }

  Widget _emptyState(bool native) {
    final cur = _languages.firstWhere(
      (l) => l['name'] == _language,
      orElse: () => {'curated': false},
    );
    final curated = cur['curated'] == true;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(Icons.graphic_eq, size: 36, color: Theme.of(context).hintColor),
          const SizedBox(height: 10),
          Text(
            curated
                ? 'No words loaded for $_language yet.'
                : '$_language has no community words yet. Native speakers teach the '
                    'tones here, pitch by pitch, so learners can practise against real '
                    'pronunciations. Be the first to teach $_language.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Future<void> _openTeachSheet() async {
    final taught = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TeachWordSheet(language: _language),
    );
    if (taught == true) _load();
  }

  bool get _isNativeSpeaker {
    final d = ConFriKaSession.instance.primaryDialect.toLowerCase();
    const globals = ['english', 'français', 'francais', 'french', 'português',
        'portuguese', 'arabic', 'العربية'];
    return d.isNotEmpty && !globals.any((g) => d.contains(g));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// On-device pitch tracker: autocorrelation F0 over streamed PCM16, converted to
// semitones relative to the learner's baseline pitch.
// ─────────────────────────────────────────────────────────────────────────────
class _PitchTracker {
  final double baselineHz;
  final int sampleRate = 16000;
  final double fmin = 70;
  final double fmax = 350;
  late final int _frameLen = (0.04 * sampleRate).round();
  late final int _hop = (0.02 * sampleRate).round();
  final List<double> _buf = [];

  _PitchTracker(this.baselineHz);

  /// Feed PCM16-LE bytes; return newly resolved semitone values (null = unvoiced).
  List<double?> addBytes(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      _buf.add(bd.getInt16(i, Endian.little) / 32768.0);
    }
    final out = <double?>[];
    while (_buf.length >= _frameLen) {
      final frame = _buf.sublist(0, _frameLen);
      final f0 = _autocorrF0(frame);
      out.add(f0 > 0 ? 12.0 * (math.log(f0 / baselineHz) / math.ln2) : null);
      _buf.removeRange(0, _hop);
    }
    return out;
  }

  double _autocorrF0(List<double> frame) {
    double mean = 0;
    for (final v in frame) {
      mean += v;
    }
    mean /= frame.length;
    double energy = 0;
    for (var i = 0; i < frame.length; i++) {
      frame[i] -= mean;
      energy += frame[i] * frame[i];
    }
    if (energy < 1e-3) return 0; // silence / unvoiced

    final minLag = (sampleRate / fmax).floor();
    var maxLag = (sampleRate / fmin).ceil();
    if (maxLag >= frame.length) maxLag = frame.length - 1;
    if (minLag >= maxLag) return 0;

    var bestLag = -1;
    var bestCorr = 0.0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var corr = 0.0;
      for (var i = 0; i < frame.length - lag; i++) {
        corr += frame[i] * frame[i + lag];
      }
      if (corr > bestCorr) {
        bestCorr = corr;
        bestLag = lag;
      }
    }
    // Lower clarity threshold so normal-volume (not shouted) speech registers;
    // the recorder's noise suppression keeps false positives down.
    if (bestLag <= 0 || bestCorr < 0.2 * energy) return 0;
    return sampleRate / bestLag;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _TonePracticeCard extends StatefulWidget {
  final Map<String, dynamic> pair;
  final bool isNative;
  const _TonePracticeCard({required this.pair, required this.isNative});

  @override
  State<_TonePracticeCard> createState() => _TonePracticeCardState();
}

enum _Stage { idle, recording, scoring, done, error }

class _TonePracticeCardState extends State<_TonePracticeCard> {
  final _api = ConFriKaApiClient.instance;
  final _recorder = AudioRecorder();

  _Stage _stage = _Stage.idle;
  String? _message;
  double? _scorePct;
  bool _acceptable = false;
  String _liveHint = '';

  StreamSubscription<Uint8List>? _sub;
  _PitchTracker? _tracker;
  final List<double?> _liveDisplay = []; // includes nulls (unvoiced gaps)
  final List<double> _liveVoiced = []; // voiced only, for scoring
  List<double> _learnerContour = const [];
  int _sampleCount = 0;

  // Auto-stop: end the recording ~0.8s after the speaker finishes the word.
  bool _hasSpoken = false;
  int _voicedRun = 0;
  int _trailingSilence = 0;

  List<double> get _targets {
    final community = (widget.pair['community_target_semitones'] as List?);
    final src = community ?? (widget.pair['target_semitones'] as List? ?? const []);
    return src.map((e) => (e as num).toDouble()).toList();
  }

  int get _communityCount => (widget.pair['community_sample_count'] as num?)?.toInt() ?? 0;

  @override
  void dispose() {
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_stage == _Stage.recording) {
      await _stopAndScore();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    try {
      if (!await _recorder.hasPermission()) {
        setState(() {
          _stage = _Stage.error;
          _message = 'Microphone permission is required to practise.';
        });
        return;
      }
      final baseline = ConFriKaSession.instance.f0BaselineHz;
      _tracker = _PitchTracker(baseline);
      _liveDisplay.clear();
      _liveVoiced.clear();
      _sampleCount = 0;
      _hasSpoken = false;
      _voicedRun = 0;
      _trailingSilence = 0;

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          // Use the device's voice DSP so users don't have to shout and
          // background noise is filtered: automatic gain control, noise
          // suppression, and echo cancellation.
          autoGain: true,
          noiseSuppress: true,
          echoCancel: true,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
          ),
        ),
      );
      setState(() {
        _stage = _Stage.recording;
        _message = 'Listening… say the word, watch your pitch, then tap Stop.';
        _scorePct = null;
        _learnerContour = const [];
        _liveHint = '';
      });

      _sub = stream.listen((bytes) {
        final semis = _tracker!.addBytes(bytes);
        if (semis.isEmpty) return;
        for (final s in semis) {
          _liveDisplay.add(s);
          if (s != null) {
            _liveVoiced.add(s);
            _voicedRun++;
            if (_voicedRun >= 3) _hasSpoken = true; // sustained voicing = speech
            _trailingSilence = 0;
          } else {
            _voicedRun = 0;
            if (_hasSpoken) _trailingSilence++;
          }
          _sampleCount++;
        }
        _updateLiveHint();
        if (mounted && _stage == _Stage.recording) setState(() {});
        // Stop automatically once the speaker has gone quiet for ~0.8s after
        // speaking (40 frames at the 20ms hop), then score.
        if (_hasSpoken &&
            _trailingSilence >= 40 &&
            _stage == _Stage.recording) {
          _stopAndScore();
        }
      });
    } catch (e) {
      setState(() {
        _stage = _Stage.error;
        _message = 'Couldn\'t start recording. Please check microphone access.';
      });
    }
  }

  void _updateLiveHint() {
    final target = _targets;
    if (target.isEmpty) return;
    // Find the latest voiced value.
    double? current;
    for (var i = _liveDisplay.length - 1; i >= 0; i--) {
      if (_liveDisplay[i] != null) {
        current = _liveDisplay[i];
        break;
      }
    }
    if (current == null) {
      _liveHint = 'Speak up, no pitch detected yet';
      return;
    }
    // Align elapsed speech (~0.9s nominal) to a position in the target contour.
    final frac = (_sampleCount / 45).clamp(0.0, 1.0);
    final idx = (frac * (target.length - 1)).round().clamp(0, target.length - 1);
    final diff = target[idx] - current;
    if (diff > 0.8) {
      _liveHint = '↑ Raise your pitch';
    } else if (diff < -0.8) {
      _liveHint = '↓ Lower your pitch';
    } else {
      _liveHint = '✓ On target, hold it';
    }
  }

  Future<void> _stopAndScore() async {
    if (_stage != _Stage.recording) return; // guard: auto-stop + manual Stop
    _stage = _Stage.scoring;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}

    if (_liveVoiced.length < 3) {
      setState(() {
        _stage = _Stage.error;
        _message = 'Not enough voiced sound detected. Speak a little louder and longer.';
      });
      return;
    }
    setState(() {
      _stage = _Stage.scoring;
      _message = 'Scoring your tone…';
    });

    final target = _targets;
    final learner = _resample(_liveVoiced, target.isEmpty ? 6 : target.length);
    final baseline = ConFriKaSession.instance.f0BaselineHz;
    try {
      final result = await _api.calibrateTone(
        targetWordId: widget.pair['id'].toString(),
        learnerSemitones: learner,
        baselineF0Hz: baseline,
      );
      if (!mounted) return;
      setState(() {
        _stage = _Stage.done;
        _scorePct = ((result['match_score_pct'] as num?) ?? 0).toDouble();
        _acceptable = result['is_acceptable_tone'] == true;
        _message = result['feedback']?.toString();
        _learnerContour =
            ((result['learner_semitones'] as List?) ?? learner).map((e) => (e as num).toDouble()).toList();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _message = e.message;
      });
    }
  }

  Future<void> _teachAsNative() async {
    if (_learnerContour.isEmpty) return;
    try {
      final res = await _api.contributeNativeTone(
        targetWordId: widget.pair['id'].toString(),
        nativeSemitones: _learnerContour,
        meanF0Hz: ConFriKaSession.instance.f0BaselineHz,
      );
      if (!mounted) return;
      final count = (res['community_sample_count'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Thank you! $count native speaker(s) have taught this word.')),
      );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  List<double> _resample(List<double> xs, int n) {
    if (xs.isEmpty || n <= 0) return const [];
    if (xs.length == n) return xs;
    if (xs.length == 1) return List<double>.filled(n, xs.first);
    final out = <double>[];
    for (var i = 0; i < n; i++) {
      final pos = i * (xs.length - 1) / (n - 1);
      final lo = pos.floor();
      final hi = pos.ceil();
      final frac = pos - lo;
      out.add(xs[lo] * (1 - frac) + xs[hi] * frac);
    }
    return out;
  }

  /// Compact "when to go up/down" guidance derived from the target contour.
  List<String> _guidanceChips() {
    final t = _targets;
    if (t.isEmpty) return const [];
    String level(double v) => v < -1.2 ? 'Low' : (v > 1.2 ? 'High' : 'Mid');
    final start = level(t.first);
    final end = level(t.last);
    final chips = <String>['Start $start'];
    final delta = t.last - t.first;
    if (delta > 1.0) {
      chips.add('↑ rise to $end');
    } else if (delta < -1.0) {
      chips.add('↓ fall to $end');
    } else {
      chips.add('→ hold $start');
    }
    return chips;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pair;
    final recording = _stage == _Stage.recording;
    final scoring = _stage == _Stage.scoring;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(p['diacritized_word']?.toString() ?? '',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: ConFriKaColors.oceanBlue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(p['tone_pattern']?.toString() ?? '',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: ConFriKaColors.oceanBlue)),
                ),
              ],
            ),
            Text(p['meaning']?.toString() ?? '',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),

            // Guidance chips: when to go up / down.
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final g in _guidanceChips())
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: ConFriKaColors.savannaGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(g,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: ConFriKaColors.savannaGreen)),
                  ),
                if (_communityCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('👥 $_communityCount native target',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: ConFriKaColors.sunsetOrange)),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Live / result pitch graph.
            _PitchGraph(
              target: _targets,
              live: _liveDisplay,
              learner: _stage == _Stage.done ? _learnerContour : const [],
              recording: recording,
            ),
            if (recording && _liveHint.isNotEmpty) ...[
              const SizedBox(height: 6),
              Center(
                child: Text(_liveHint,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: _liveHint.startsWith('✓')
                          ? ConFriKaColors.savannaGreen
                          : ConFriKaColors.oceanBlue,
                    )),
              ),
            ],
            const SizedBox(height: 8),
            Text(p['coaching_tip']?.toString() ?? '',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),

            Row(
              children: [
                FilledButton.icon(
                  onPressed: scoring ? null : _toggle,
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        recording ? Colors.redAccent : ConFriKaColors.savannaGreen,
                  ),
                  icon: Icon(recording ? Icons.stop : Icons.mic, size: 18),
                  label: Text(recording ? 'Stop' : 'Practice'),
                ),
                const SizedBox(width: 12),
                if (scoring)
                  const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                if (_stage == _Stage.done && _scorePct != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: (_acceptable ? ConFriKaColors.savannaGreen : ConFriKaColors.sunsetOrange)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_acceptable ? '✅' : '🔁'} ${_scorePct!.round()}% match',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: _acceptable
                            ? ConFriKaColors.savannaGreen
                            : ConFriKaColors.sunsetOrange,
                      ),
                    ),
                  ),
              ],
            ),
            if (widget.isNative && _stage == _Stage.done && _learnerContour.isNotEmpty) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _teachAsNative,
                icon: const Icon(Icons.volunteer_activism, size: 16),
                label: const Text('Teach ConFriKa (I\'m a native speaker)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ConFriKaColors.sunsetOrange,
                  side: BorderSide(color: ConFriKaColors.sunsetOrange.withValues(alpha: 0.5)),
                ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(
                _message!,
                style: TextStyle(
                  fontSize: 12,
                  color: _stage == _Stage.error ? Colors.redAccent : Colors.grey,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Draws the target tone contour and, over it, the live/final learner pitch.
class _PitchGraph extends StatelessWidget {
  final List<double> target;
  final List<double?> live;
  final List<double> learner;
  final bool recording;
  const _PitchGraph({
    required this.target,
    required this.live,
    required this.learner,
    required this.recording,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 110,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(8),
      child: CustomPaint(
        painter: _PitchPainter(target: target, live: live, learner: learner),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _PitchPainter extends CustomPainter {
  final List<double> target;
  final List<double?> live;
  final List<double> learner;
  _PitchPainter({required this.target, required this.live, required this.learner});

  static const double _min = -6; // semitones
  static const double _max = 6;

  double _y(double st, Size s) {
    final norm = ((st - _min) / (_max - _min)).clamp(0.0, 1.0);
    return s.height - norm * s.height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Zero (baseline) gridline.
    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final zeroY = _y(0, size);
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), grid);

    // Target contour (smooth blue line).
    if (target.length >= 2) {
      final paint = Paint()
        ..color = ConFriKaColors.oceanBlue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      final path = Path();
      for (var i = 0; i < target.length; i++) {
        final x = target.length == 1 ? 0.0 : i / (target.length - 1) * size.width;
        final y = _y(target[i], size);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, paint);
    }

    // Learner contour (final, orange dots + line).
    final learnerPts = learner;
    if (learnerPts.length >= 2) {
      final paint = Paint()
        ..color = ConFriKaColors.sunsetOrange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      final path = Path();
      for (var i = 0; i < learnerPts.length; i++) {
        final x = learnerPts.length == 1 ? 0.0 : i / (learnerPts.length - 1) * size.width;
        final y = _y(learnerPts[i], size);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, paint);
    } else if (live.isNotEmpty) {
      // Live trace while recording (orange points across time).
      final dot = Paint()..color = ConFriKaColors.sunsetOrange;
      final n = live.length;
      for (var i = 0; i < n; i++) {
        final v = live[i];
        if (v == null) continue;
        final x = n == 1 ? 0.0 : i / (n - 1) * size.width;
        canvas.drawCircle(Offset(x, _y(v, size)), 2.2, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PitchPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Teach a new word in any tonal language: enter the word, record your native
// pitch, and contribute it so others can practise against a real pronunciation.
// ─────────────────────────────────────────────────────────────────────────────
class _TeachWordSheet extends StatefulWidget {
  final String language;
  const _TeachWordSheet({required this.language});

  @override
  State<_TeachWordSheet> createState() => _TeachWordSheetState();
}

class _TeachWordSheetState extends State<_TeachWordSheet> {
  final _api = ConFriKaApiClient.instance;
  final _recorder = AudioRecorder();
  final _spelling = TextEditingController();
  final _meaning = TextEditingController();
  final _tone = TextEditingController();

  StreamSubscription<Uint8List>? _sub;
  _PitchTracker? _tracker;
  final List<double> _voiced = [];
  bool _recording = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _sub?.cancel();
    _recorder.dispose();
    _spelling.dispose();
    _meaning.dispose();
    _tone.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _sub?.cancel();
      await _recorder.stop();
      setState(() => _recording = false);
      return;
    }
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission is required.');
      return;
    }
    _voiced.clear();
    _tracker = _PitchTracker(ConFriKaSession.instance.f0BaselineHz);
    final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1));
    setState(() {
      _recording = true;
      _error = null;
    });
    _sub = stream.listen((bytes) {
      for (final s in _tracker!.addBytes(bytes)) {
        if (s != null) _voiced.add(s);
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _submit() async {
    if (_spelling.text.trim().isEmpty || _meaning.text.trim().isEmpty) {
      setState(() => _error = 'Enter the word and its meaning.');
      return;
    }
    if (_voiced.length < 3) {
      setState(() => _error = 'Record the word first (speak clearly).');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.teachToneWord(
        language: widget.language,
        spelling: _spelling.text.trim(),
        meaning: _meaning.text.trim(),
        tonePattern: _tone.text.trim().isEmpty ? null : _tone.text.trim(),
        semitones: _voiced,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18, right: 18, top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Teach a word in ${widget.language}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Native speakers record real pitch so others can learn it.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 14),
          TextField(
            controller: _spelling,
            decoration: const InputDecoration(
                labelText: 'Word (with tone marks if any)',
                border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _meaning,
            decoration: const InputDecoration(
                labelText: 'Meaning', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tone,
            decoration: const InputDecoration(
                labelText: 'Tone pattern (optional, e.g. Mid · High)',
                border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _toggleRecord,
            style: FilledButton.styleFrom(
              backgroundColor:
                  _recording ? Colors.redAccent : ConFriKaColors.savannaGreen,
            ),
            icon: Icon(_recording ? Icons.stop : Icons.mic),
            label: Text(_recording
                ? 'Stop (${_voiced.length} pitch points)'
                : (_voiced.isEmpty ? 'Record pronunciation' : 'Re-record')),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
                backgroundColor: ConFriKaColors.oceanBlue,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Teach this word',
                    style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
