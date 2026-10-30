import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/theme/confrika_theme.dart';
import 'live_sign_view.dart';
import 'sign_composer.dart';
import 'sign_speech_service.dart';

/// Sign Mode — the in-person / meeting-in-the-room accessibility screen.
///
/// The user lays the phone down and steps back: the screen is split so they can
/// watch their own signing in the camera self-view (bottom) while the
/// conversation builds up top. Two directions:
///   • their composed sign → **spoken aloud** for the hearing person, and
///   • the hearing person's **speech → live captions** for the user.
class SignModeScreen extends StatefulWidget {
  const SignModeScreen({super.key});

  @override
  State<SignModeScreen> createState() => _SignModeScreenState();
}

class _Turn {
  final bool mine; // true = the user's signed+spoken message; false = heard speech
  final String text;
  _Turn(this.mine, this.text);
}

class _SignModeScreenState extends State<SignModeScreen>
    with WidgetsBindingObserver {
  CameraController? _cam;
  bool _camReady = false;
  String? _camError;

  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _listening = false;
  String _partial = '';

  final List<_Turn> _turns = [];
  final _scroll = ScrollController();

  // Live-camera mode: MediaPipe recognition in an in-app WebView.
  bool _live = false;
  String _liveMsg = '';
  String _liveMode = 'spell'; // 'spell' (fingerspell) | 'words' (trained model)

  // Voice selection (male/female/African) for everything spoken aloud.
  List<SignVoice> _voiceChoices = const [];
  SignVoice? _voice;
  String _voiceFilter = 'any';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _initStt();
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    try {
      final svc = SignSpeechService.instance;
      final list = await svc.voicesFiltered();
      if (!mounted) return;
      setState(() {
        _voiceFilter = svc.filter;
        _voiceChoices = list;
        _voice = svc.selected ?? (list.isNotEmpty ? list.first : null);
      });
    } catch (_) {/* no voices enumerated — speaking still uses the default */}
  }

  Future<void> _setVoiceFilter(String f) async {
    await SignSpeechService.instance.setFilter(f);
    final list = await SignSpeechService.instance.voicesFiltered(f);
    if (!mounted) return;
    setState(() {
      _voiceFilter = f;
      _voiceChoices = list;
      if (_voice == null || !list.any((v) => v.name == _voice!.name && v.locale == _voice!.locale)) {
        _voice = list.isNotEmpty ? list.first : null;
        if (_voice != null) SignSpeechService.instance.selectVoice(_voice!);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    _stt.stop();
    SignSpeechService.instance.stop();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _cam;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      c.dispose();
      _camReady = false;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _camError = 'No camera found on this device.');
        return;
      }
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false, // leave the mic free for speech-to-text
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cam = controller;
        _camReady = true;
        _camError = null;
      });
    } catch (e) {
      setState(() => _camError = 'Camera unavailable. Compose and speak still work.');
    }
  }

  Future<void> _initStt() async {
    try {
      _sttAvailable = await _stt.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) {
            _commitPartial();
            setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
    } catch (_) {
      _sttAvailable = false;
    }
    if (mounted) setState(() {});
  }

  void _commitPartial() {
    final t = _partial.trim();
    if (t.isNotEmpty) {
      _addTurn(_Turn(false, t));
    }
    _partial = '';
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_sttAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Speech recognition is not available on this device.')));
      return;
    }
    setState(() {
      _listening = true;
      _partial = '';
    });
    await _stt.listen(
      onResult: (r) {
        setState(() => _partial = r.recognizedWords);
        if (r.finalResult) {
          _commitPartial();
          setState(() => _listening = false);
        }
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
      ),
    );
  }

  void _onSign(String text) {
    _addTurn(_Turn(true, text));
    SignSpeechService.instance.speak(text);
  }

  /// Switch between the keyboard composer and live-camera recognition. The two
  /// can't use the camera at once, so the plugin preview is released when the
  /// WebView takes over, and re-initialised when we come back.
  Future<void> _setLive(bool on) async {
    if (on) {
      await _cam?.dispose();
      _cam = null;
      if (mounted) setState(() { _camReady = false; _live = true; _liveMsg = ''; });
    } else {
      if (mounted) setState(() => _live = false);
      _initCamera();
    }
  }

  void _onLiveWord(String w) {
    final word = w.trim();
    if (word.isEmpty) return;
    setState(() => _liveMsg = _liveMsg.isEmpty ? word : '$_liveMsg $word');
    SignSpeechService.instance.speak(word); // speak each finished word, fast
  }

  void _sendLiveToConversation() {
    final t = _liveMsg.trim();
    if (t.isEmpty) return;
    _addTurn(_Turn(true, t));
    setState(() => _liveMsg = '');
  }

  void _addTurn(_Turn turn) {
    setState(() => _turns.add(turn));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign Mode'),
        actions: [
          IconButton(
            tooltip: 'How Sign Mode works',
            onPressed: _showHelp,
            icon: const Icon(Icons.help_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── TOP: conversation (what's being said) ──
            Expanded(flex: 5, child: _conversationPanel(isDark)),
            const Divider(height: 1),
            // ── BOTTOM: self-view camera + sign composer ──
            Expanded(flex: 6, child: _signPanel(isDark)),
          ],
        ),
      ),
    );
  }

  Widget _conversationPanel(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.forum_outlined, size: 18, color: ConFriKaColors.oceanBlue),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Conversation',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
              ),
              FilledButton.icon(
                onPressed: _toggleListen,
                style: FilledButton.styleFrom(
                  backgroundColor:
                      _listening ? Colors.redAccent : ConFriKaColors.oceanBlue,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                icon: Icon(_listening ? Icons.stop : Icons.hearing, size: 16),
                label: Text(_listening ? 'Stop' : 'Listen to them',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: (_turns.isEmpty && _partial.isEmpty)
                ? _emptyConversation()
                : ListView(
                    controller: _scroll,
                    children: [
                      for (final t in _turns) _bubble(t, isDark),
                      if (_listening || _partial.isNotEmpty)
                        _bubble(_Turn(false, _partial.isEmpty ? '…' : _partial),
                            isDark,
                            pending: true),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyConversation() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🤟', style: TextStyle(fontSize: 34)),
            const SizedBox(height: 8),
            Text(
              'Sign below to speak aloud, or tap “Listen to them” to caption what the other person says.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Turn t, bool isDark, {bool pending = false}) {
    final mine = t.mine;
    final bg = mine
        ? ConFriKaColors.savannaGreen.withValues(alpha: 0.15)
        : (isDark ? const Color(0xFF1E293B) : Colors.white);
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: mine
                ? ConFriKaColors.savannaGreen.withValues(alpha: 0.4)
                : (isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(mine ? 'You (signed)' : 'They said',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: mine ? ConFriKaColors.savannaGreen : Colors.grey)),
            const SizedBox(height: 2),
            Text(t.text,
                style: TextStyle(
                    fontSize: 15,
                    fontStyle: pending ? FontStyle.italic : FontStyle.normal,
                    color: pending
                        ? Colors.grey
                        : (isDark ? Colors.white : Colors.black87))),
          ],
        ),
      ),
    );
  }

  Widget _signPanel(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _modeToggle(isDark),
          const SizedBox(height: 10),
          _voiceBar(isDark),
          const SizedBox(height: 10),
          if (_live) ..._liveLayout(isDark) else ..._keyboardLayout(isDark),
        ],
      ),
    );
  }

  Widget _voiceBar(bool isDark) {
    final border = isDark ? Colors.white24 : Colors.black.withValues(alpha: 0.08);
    Widget chip(String label, String value) {
      final on = _voiceFilter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          selected: on,
          onSelected: (_) => _setVoiceFilter(value),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          selectedColor: ConFriKaColors.oceanBlue,
          labelStyle: TextStyle(color: on ? Colors.white : null),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.record_voice_over, size: 15, color: ConFriKaColors.oceanBlue),
              const SizedBox(width: 6),
              Text('SPEAKING VOICE',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900,
                      color: Colors.grey.shade600, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              chip('All', 'any'),
              chip('Female', 'female'),
              chip('Male', 'male'),
              chip('African', 'african'),
            ]),
          ),
          const SizedBox(height: 6),
          if (_voiceChoices.isEmpty)
            Text('Using the device default voice (no selectable voices found).',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600))
          else
            DropdownButtonHideUnderline(
              child: DropdownButton<SignVoice>(
                isExpanded: true,
                value: _voiceChoices.firstWhere(
                  (v) => _voice != null && v.name == _voice!.name && v.locale == _voice!.locale,
                  orElse: () => _voiceChoices.first,
                ),
                items: [
                  for (final v in _voiceChoices)
                    DropdownMenuItem<SignVoice>(
                      value: v,
                      child: Text('${v.name} · ${v.locale}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _voice = v);
                  SignSpeechService.instance.selectVoice(v);
                  SignSpeechService.instance.speak('Hello'); // preview the voice
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _modeToggle(bool isDark) {
    Widget seg(String label, IconData ic, bool on, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: on ? ConFriKaColors.oceanBlue : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(ic, size: 16, color: on ? Colors.white : Colors.grey),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                          color: on ? Colors.white : Colors.grey)),
                ],
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        seg('Keyboard', Icons.keyboard, !_live, () { if (_live) _setLive(false); }),
        seg('Live camera · beta', Icons.videocam, _live, () { if (!_live) _setLive(true); }),
      ]),
    );
  }

  List<Widget> _keyboardLayout(bool isDark) => [
        // Self-view camera.
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 170,
            color: Colors.black,
            alignment: Alignment.center,
            child: _camReady && _cam != null
                ? _CameraSelfView(controller: _cam!)
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _camError ?? 'Starting camera…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.videocam_outlined, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Watch yourself sign. Compose your message, then tap “Speak to them”.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SignComposer(
          dark: isDark,
          onSpeak: _onSign,
          speakLabel: 'Speak to them',
          speakIcon: Icons.volume_up,
        ),
      ];

  Widget _liveModeToggle(bool isDark) {
    Widget seg(String label, String value, IconData ic) {
      final on = _liveMode == value;
      return Expanded(
        child: InkWell(
          onTap: () { if (_liveMode != value) setState(() => _liveMode = value); },
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: on ? ConFriKaColors.savannaGreen : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(ic, size: 15, color: on ? Colors.white : Colors.grey),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11,
                          color: on ? Colors.white : Colors.grey)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFEDF1F6),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(children: [
        seg('Fingerspell', 'spell', Icons.sign_language),
        seg('Words · beta', 'words', Icons.chat_bubble_outline),
      ]),
    );
  }

  List<Widget> _liveLayout(bool isDark) => [
        _liveModeToggle(isDark),
        const SizedBox(height: 8),
        // Live recognition view (MediaPipe in a WebView).
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 300,
            child: LiveSignView(
              mode: _liveMode,
              onWord: _onLiveWord,
              onToken: (m) {
                // Low-confidence hint from the word model — surface briefly.
                if (mounted && _liveMode == 'words') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
                }
              },
              onError: (m) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? Colors.white10 : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: isDark ? Colors.white24 : Colors.black.withValues(alpha: 0.08)),
          ),
          child: Text(
            _liveMsg.isEmpty ? 'Recognized words appear here, and are spoken aloud…' : _liveMsg,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _liveMsg.isEmpty
                    ? Colors.grey
                    : (isDark ? Colors.white : Colors.black87)),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => SignSpeechService.instance.speak(_liveMsg),
                style: FilledButton.styleFrom(
                    backgroundColor: ConFriKaColors.savannaGreen,
                    padding: const EdgeInsets.symmetric(vertical: 12)),
                icon: const Icon(Icons.volume_up, size: 18),
                label: const Text('Speak all', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _sendLiveToConversation,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
              child: const Icon(Icons.subdirectory_arrow_left, size: 18),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => setState(() => _liveMsg = ''),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
              child: const Icon(Icons.clear, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _liveMode == 'words'
              ? 'Beta · sign a whole word (one of 250 everyday ASL signs), then lower '
                  'your hands. The recognized word is spoken aloud in your chosen voice.'
              : 'Beta · fingerspell a letter and hold; lower your hand to finish a word. '
                  'Each finished word is spoken aloud.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ];

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Mode'),
        content: const Text(
          'Lay your phone down and step back so the camera can see you.\n\n'
          '• Watch yourself sign in the camera view.\n'
          '• Build your message with the fingerspelling keys or a quick phrase, '
          'then tap “Speak to them” — your phone says it aloud.\n'
          '• Tap “Listen to them” to turn the other person\'s speech into text.\n\n'
          'Live camera (beta): switch to it to read your signing from the camera — '
          'either fingerspelling, or whole words (250 everyday ASL signs). '
          'Pick the speaking voice — male, female, or an African voice when your '
          'device has one installed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

/// Front-camera preview scaled to cover its box, mirrored like a selfie.
class _CameraSelfView extends StatelessWidget {
  final CameraController controller;
  const _CameraSelfView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.rotationY(3.1415926), // mirror horizontally
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: controller.value.previewSize?.height ?? 1,
          height: controller.value.previewSize?.width ?? 1,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}
