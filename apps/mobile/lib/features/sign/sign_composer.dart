import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/confrika_theme.dart';

/// A reusable sign-input composer for Deaf/non-speaking users.
///
/// Two reliable input paths that work on every device today:
///   • a **fingerspelling keyboard** (ASL alphabet A–Z / digits 0–9), and
///   • a **phrase palette** of common signs, loaded from the backend
///     `/sign/vocabulary`.
///
/// Live camera auto-detection of signing needs 21-point hand landmarks, which
/// the ConFriKa browser extension produces in-browser; on mobile it is the
/// next step. Until then this composer lets a user build any message and have
/// it voiced via [onSpeak].
class SignComposer extends StatefulWidget {
  /// Called with the composed text when the user taps the primary action
  /// (e.g. speak it aloud, or speak it into a call).
  final ValueChanged<String> onSpeak;
  final String speakLabel;
  final IconData speakIcon;
  final bool dark;

  /// Compact layout for tight spaces (the in-call panel).
  final bool compact;

  const SignComposer({
    super.key,
    required this.onSpeak,
    this.speakLabel = 'Speak',
    this.speakIcon = Icons.volume_up,
    this.dark = false,
    this.compact = false,
  });

  @override
  State<SignComposer> createState() => _SignComposerState();
}

class _SignComposerState extends State<SignComposer> {
  final _ctrl = TextEditingController();
  bool _digits = false;

  // Phrase palette. Seeded with a sensible default so the composer is usable
  // even before the network call returns; replaced by the live vocabulary.
  List<Map<String, dynamic>> _phrases = const [
    {'token': 'HELLO', 'text': 'Hello', 'auto': false},
    {'token': 'THANK_YOU', 'text': 'Thank you', 'auto': false},
    {'token': 'YES', 'text': 'Yes', 'auto': false},
    {'token': 'NO', 'text': 'No', 'auto': false},
    {'token': 'PLEASE', 'text': 'Please', 'auto': false},
    {'token': 'HELP', 'text': 'Help', 'auto': false},
  ];

  static const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _nums = '0123456789';

  @override
  void initState() {
    super.initState();
    _loadVocabulary();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadVocabulary() async {
    try {
      final v = await ConFriKaApiClient.instance.signVocabulary();
      final phrases = (v['phrases'] as List?)?.cast<Map<String, dynamic>>();
      if (phrases != null && phrases.isNotEmpty && mounted) {
        setState(() => _phrases = phrases);
      }
    } catch (_) {
      // Keep the seeded defaults — the composer still works offline.
    }
  }

  void _append(String s) => setState(() {
        _ctrl.text += s;
        _ctrl.selection =
            TextSelection.collapsed(offset: _ctrl.text.length);
      });

  void _backspace() => setState(() {
        final t = _ctrl.text;
        if (t.isNotEmpty) {
          _ctrl.text = t.substring(0, t.length - 1);
          _ctrl.selection =
              TextSelection.collapsed(offset: _ctrl.text.length);
        }
      });

  void _clear() => setState(() => _ctrl.clear());

  void _speak() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    widget.onSpeak(t);
    _clear();
  }

  Color get _fg => widget.dark ? Colors.white : Colors.black87;
  Color get _subtle =>
      widget.dark ? Colors.white10 : const Color(0xFFF1F5F9);
  Color get _border =>
      widget.dark ? Colors.white24 : Colors.black.withValues(alpha: 0.08);

  @override
  Widget build(BuildContext context) {
    final keys = (_digits ? _nums : _letters).split('');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Composed message line.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _subtle,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _ctrl,
                  builder: (_, v, __) => Text(
                    v.text.isEmpty ? 'Compose a message…' : v.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: widget.compact ? 15 : 17,
                      fontWeight: FontWeight.w700,
                      color: v.text.isEmpty ? Colors.grey : _fg,
                    ),
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _backspace,
                icon: Icon(Icons.backspace_outlined, size: 20, color: _fg),
                tooltip: 'Delete',
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _clear,
                icon: Icon(Icons.clear, size: 20, color: _fg),
                tooltip: 'Clear',
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Primary action: voice it.
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _speak,
                style: FilledButton.styleFrom(
                  backgroundColor: ConFriKaColors.savannaGreen,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: Icon(widget.speakIcon, size: 18),
                label: Text(widget.speakLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(width: 8),
            // ABC / 123 toggle + space.
            OutlinedButton(
              onPressed: () => setState(() => _digits = !_digits),
              style: OutlinedButton.styleFrom(
                foregroundColor: _fg,
                side: BorderSide(color: _border),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              child: Text(_digits ? 'ABC' : '123',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _append(' '),
              style: OutlinedButton.styleFrom(
                foregroundColor: _fg,
                side: BorderSide(color: _border),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              child: const Text('␣', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Fingerspelling keyboard.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final k in keys)
              _KeyButton(label: k, dark: widget.dark, onTap: () => _append(k)),
          ],
        ),
        const SizedBox(height: 10),

        // Phrase palette.
        Align(
          alignment: Alignment.centerLeft,
          child: Text('QUICK PHRASES',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: Colors.grey.shade500,
                  letterSpacing: 0.5)),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in _phrases)
              ActionChip(
                label: Text(p['text']?.toString() ?? p['token'].toString()),
                labelStyle: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: _fg),
                backgroundColor: ConFriKaColors.oceanBlue.withValues(alpha: 0.10),
                side: BorderSide(
                    color: ConFriKaColors.oceanBlue.withValues(alpha: 0.30)),
                onPressed: () {
                  final text = p['text']?.toString() ?? '';
                  if (text.isNotEmpty) _append('${_ctrl.text.isEmpty ? '' : ' '}$text');
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _KeyButton extends StatelessWidget {
  final String label;
  final bool dark;
  final VoidCallback onTap;
  const _KeyButton({required this.label, required this.dark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 42,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: dark ? Colors.white : Colors.black87,
          side: BorderSide(
              color: dark ? Colors.white24 : Colors.black.withValues(alpha: 0.12)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
