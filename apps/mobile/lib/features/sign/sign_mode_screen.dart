import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/theme/confrika_theme.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _initStt();
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
        ],
      ),
    );
  }

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
          'Live camera auto-detection of signs is coming next (and is available '
          'now in the ConFriKa browser extension for video calls).',
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
