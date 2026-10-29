import 'package:flutter/material.dart';
import '../theme/confrika_theme.dart';

/// Renders the exact ConFriKa App Emblem extracted from the PDF cover.
class ConFriKaAppLogo extends StatelessWidget {
  final double size;

  const ConFriKaAppLogo({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black12),
      ),
      child: Image.asset(
        'assets/images/confrika_app_icon.png',
        fit: BoxFit.contain,
      ),
    );
  }
}

/// Renders the ConFriKa Add Logo badge (App Emblem + Savanna Green "+" badge)
/// used on "+ Add Elder / Family Member" and "+ Add Phrase / Tonal Profile" actions.
class ConFriKaAddLogoBadge extends StatelessWidget {
  final double size;

  const ConFriKaAddLogoBadge({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ConFriKaAppLogo(size: size),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * 0.48,
              height: size * 0.48,
              decoration: BoxDecoration(
                color: ConFriKaColors.savannaGreen,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Icon(
                Icons.add,
                size: size * 0.34,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders the ConFrika wordmark as a single word with all three brand colours
/// flowing across it as a gradient (ocean → sunset → green). Keeps the colours
/// but reads as one word, never "Con Fri ka".
class ConFriKaWordmark extends StatelessWidget {
  final double fontSize;

  const ConFriKaWordmark({super.key, this.fontSize = 20});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          ConFriKaColors.oceanBlue,
          ConFriKaColors.sunsetOrange,
          ConFriKaColors.savannaGreen,
        ],
        stops: [0.0, 0.52, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(
        'ConFrika',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
          color: Colors.white, // replaced by the shader
        ),
      ),
    );
  }
}

/// Renders the signature 3-segment horizontal color bar from the PDF cover.
class ConFriKaTriColorBar extends StatelessWidget {
  final double height;

  const ConFriKaTriColorBar({super.key, this.height = 5});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: const Row(
        children: [
          Expanded(child: ColoredBox(color: ConFriKaColors.oceanBlue)),
          Expanded(child: ColoredBox(color: ConFriKaColors.sunsetOrange)),
          Expanded(child: ColoredBox(color: ConFriKaColors.savannaGreen)),
        ],
      ),
    );
  }
}
