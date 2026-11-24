import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../theme/nova_theme.dart';
import '../widgets/glass.dart';
import '../widgets/pressable.dart';
import 'ai_privacy_screen.dart';
import 'food_result_screen.dart';
import 'report_result_screen.dart';
import 'scan_result_screen.dart';

enum ScanMode { prescription, report, food }

String _modeLabel(ScanMode m) => switch (m) {
      ScanMode.prescription => 'Prescription',
      ScanMode.report => 'Report',
      ScanMode.food => 'Food',
    };

/// 04 Scan — full-bleed camera with floating glass controls, plus the
/// "Reading details…" processing state.
///
/// The shutter opens the system camera and the photo button opens the photo
/// library (image_picker). The preview behind is still a mock; a live preview
/// with the `camera` package is a later upgrade.
class ScanCameraScreen extends StatefulWidget {
  const ScanCameraScreen({super.key, this.initialMode = ScanMode.prescription});
  final ScanMode initialMode;

  @override
  State<ScanCameraScreen> createState() => _ScanCameraScreenState();
}

class _ScanCameraScreenState extends State<ScanCameraScreen> {
  late ScanMode _mode = widget.initialMode;
  bool _flash = false;
  bool _processing = false;

  final ImagePicker _picker = ImagePicker();

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pick(ImageSource source) async {
    if (_processing) return;
    final mode = _mode;
    final api = ApiClient.instance;
    final owner = api.aiAccountId;
    if (owner == null) return;
    HapticFeedback.mediumImpact();
    setState(() => _processing = true);
    try {
      if (!await ensureAiConsent(context) || !mounted) return;
      final XFile? file;
      try {
        file = await _picker.pickImage(
          source: source,
          maxWidth: mode == ScanMode.food ? 1280 : 2300,
          maxHeight: mode == ScanMode.food ? 1280 : 2300,
          imageQuality: 90,
          requestFullMetadata: false,
        );
      } catch (_) {
        _toast('Could not open the camera or photos. Check the app permissions.');
        return;
      }
      if (file == null || !mounted || !_sameAccount(owner)) return;
      final bytes = await file.readAsBytes();
      if (!mounted || !_sameAccount(owner)) return;
      String? text;
      if (mode == ScanMode.food) {
        final approved = await showDialog<bool>(
          context: context,
          builder: (_) => FoodPhotoReview(image: bytes),
        );
        if (approved != true) return;
      } else {
        String draft;
        String? extractionMessage;
        try {
          draft = await api.extractMedicalText(file);
          if (draft.trim().isEmpty) extractionMessage = 'No text was read. You can type the clinical details below.';
        } on ApiException {
          draft = '';
          extractionMessage = 'Could not read this photo privately. You can type the clinical details below.';
        }
        if (!mounted || !_sameAccount(owner)) return;
        text = await showDialog<String>(
          context: context,
          builder: (_) => MedicalTextReview(text: draft, extractionMessage: extractionMessage, image: bytes),
        );
        if (text == null) return;
      }
      if (!mounted || !_sameAccount(owner)) return;
      final Widget result;
      if (mode == ScanMode.prescription) {
        final scan = await api.scanPrescription(text ?? '');
        result = ScanResultScreen(scan: scan, imageBytes: bytes);
      } else if (mode == ScanMode.report) {
        final report = await api.scanReport(text ?? '');
        result = ReportResultScreen(
          scan: report,
          imageBytes: bytes,
          onConfirm: (date, rows) => api.confirmLabReport(report, owner, date, rows),
        );
      } else {
        final food = await api.scanFood(file);
        result = FoodResultScreen(scan: food, imageBytes: bytes);
      }
      if (!mounted || !_sameAccount(owner)) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => result,
      ));
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  bool _sameAccount(String owner) => ApiClient.instance.aiAccountId == owner;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    // Camera UI always uses dark glass with white content, in both app modes.
    return Theme(
      data: NovaTheme.dark(),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: const Color(0xFF1A1D20),
          body: Stack(
            children: [
              Positioned.fill(child: _MockPreview(mode: _mode)),
              Center(
                child: Transform.translate(
                  offset: const Offset(0, -40),
                  child: SizedBox(
                    width: 326,
                    height: 260,
                    child: CustomPaint(painter: _FrameCornersPainter()),
                  ),
                ),
              ),
              Positioned(
                top: pad.top + 4,
                left: NovaSpace.margin,
                right: NovaSpace.margin,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GlassIconButton(
                      icon: CupertinoIcons.xmark,
                      label: 'Close',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    _ModeSwitch(mode: _mode, onChanged: (m) {
                      if (!_processing) setState(() => _mode = m);
                    }),
                    GlassIconButton(
                      icon: _flash ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt_slash,
                      label: _flash ? 'Flash on' : 'Flash off',
                      iconSize: 22,
                      onTap: () => setState(() => _flash = !_flash),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: pad.bottom + 150,
                child: Center(
                  child: Glass(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    child: Text(
                      switch (_mode) {
                        ScanMode.prescription => 'Hold the label steady inside the frame',
                        ScanMode.report => 'Keep the whole results table in view',
                        ScanMode.food => 'Fit the whole plate inside the frame',
                      },
                      style: NovaType.footnote.copyWith(fontWeight: FontWeight.w500, color: Colors.white),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 44,
                right: 44,
                bottom: pad.bottom + 28,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GlassIconButton(
                      icon: CupertinoIcons.photo,
                      label: 'Choose from photo library',
                      size: 52,
                      iconSize: 24,
                      onTap: _processing ? null : () => _pick(ImageSource.gallery),
                    ),
                    _Shutter(onTap: _processing ? null : () => _pick(ImageSource.camera)),
                    const GlassIconButton(icon: CupertinoIcons.clock, label: 'Recent scans', size: 52, iconSize: 24),
                  ],
                ),
              ),
              if (_processing) const Positioned.fill(child: _ProcessingOverlay()),
            ],
          ),
        ),
      ),
    );
  }
}

class MedicalTextReview extends StatefulWidget {
  const MedicalTextReview({super.key, required this.text, this.extractionMessage, this.image});

  final String text;
  final String? extractionMessage;
  final Uint8List? image;

  @override
  State<MedicalTextReview> createState() => _MedicalTextReviewState();
}

class _MedicalTextReviewState extends State<MedicalTextReview> {
  late final _text = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review text before sharing'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Only the text below may be sent to Google Gemini. Remove names, addresses, IDs and other '
          'identifiers. Correct any reading errors and keep the clinical details and instructions.',
        ),
        if (widget.image case final image?) ...[
          const SizedBox(height: 8),
          InteractiveViewer(
            child: Image.memory(image, height: 130, fit: BoxFit.contain, semanticLabel: 'Original photo for comparison'),
          ),
        ],
        if (widget.extractionMessage != null) ...[
          const SizedBox(height: 8),
          Text(widget.extractionMessage!),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          decoration: const InputDecoration(labelText: 'Clinical text'),
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          minLines: 4,
          maxLines: 8,
          maxLength: 10000,
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ValueListenableBuilder(
        valueListenable: _text,
        builder: (context, value, _) => FilledButton(
          onPressed: value.text.trim().isEmpty ? null : () {
            final reviewed = _text.text.trim();
            if (reviewed.isNotEmpty) Navigator.pop(context, reviewed);
          },
          child: const Text('Share text with Gemini'),
        ),
      ),
    ],
  );
}

class FoodPhotoReview extends StatelessWidget {
  const FoodPhotoReview({super.key, required this.image});
  final Uint8List image;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review food photo'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Google Gemini will receive this photo after NOVA removes its metadata. '
          'Only share a photo of your food. Cancel if faces, documents or other identifying details are visible.',
        ),
        const SizedBox(height: 12),
        Image.memory(image, height: 180, fit: BoxFit.contain),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Share food photo')),
    ],
  );
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});
  final ScanMode mode;
  final ValueChanged<ScanMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Glass(
      height: 44,
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ScanMode.values)
            Pressable(
              onTap: () => onChanged(m),
              selected: m == mode,
              semanticLabel: _modeLabel(m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: m == mode ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(NovaRadius.capsule),
                ),
                child: Text(
                  _modeLabel(m),
                  style: NovaType.subhead.copyWith(
                    fontWeight: FontWeight.w600,
                    color: m == mode ? const Color(0xFF1C1C1E) : Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Take photo',
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
        alignment: Alignment.center,
        child: Container(width: 62, height: 62, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white)),
      ),
    );
  }
}

class _MockPreview extends StatelessWidget {
  const _MockPreview({required this.mode});
  final ScanMode mode;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.12),
          radius: 0.9,
          colors: [Color(0xFF2E3337), Color(0xFF23272B), Color(0xFF1A1D20)],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Center(
        child: Transform.translate(
          offset: const Offset(0, -40),
          child: ExcludeSemantics(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: mode == ScanMode.food ? const _MockPlate() : const _MockPrescription(),
            ),
          ),
        ),
      ),
    );
  }
}

class _MockPrescription extends StatelessWidget {
  const _MockPrescription();

  Widget _line(double w, {Color color = const Color(0xFFB9B4A5), double h = 6}) =>
      Container(width: w, height: h, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)));

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.052,
      child: Container(
        width: 270,
        height: 180,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F3EA),
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 30, offset: Offset(0, 10))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('RX', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: Color(0xFF4A4A4A))),
              const Spacer(),
              _line(70),
            ]),
            const SizedBox(height: 10),
            _line(200, color: const Color(0xFF8C8779), h: 8),
            const SizedBox(height: 8),
            _line(140),
            const SizedBox(height: 8),
            _line(170),
            const SizedBox(height: 8),
            _line(95),
            const Spacer(),
            Row(children: [_line(50), const Spacer(), _line(90)]),
          ],
        ),
      ),
    );
  }
}

class _MockPlate extends StatelessWidget {
  const _MockPlate();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 200,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFECE9E1),
        boxShadow: [BoxShadow(color: Color(0x73000000), blurRadius: 36, offset: Offset(0, 12))],
      ),
      child: CustomPaint(painter: _PlatePainter()),
    );
  }
}

class _PlatePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, 78, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFFC9C4B6));
    canvas.drawOval(Rect.fromCenter(center: c.translate(0, 14), width: 96, height: 46), Paint()..color = const Color(0xFFD9C7A1));
    canvas.drawOval(Rect.fromCenter(center: c.translate(0, -6), width: 64, height: 34), Paint()..color = const Color(0xFFB6D2A3));
    canvas.drawCircle(c.translate(-10, 12), 7, Paint()..color = const Color(0xFFE89B6F));
    canvas.drawCircle(c.translate(16, 14), 6, Paint()..color = const Color(0xFFE89B6F));
  }

  @override
  bool shouldRepaint(_PlatePainter oldDelegate) => false;
}

class _FrameCornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const r = 22.0, l = 34.0;
    final w = size.width, h = size.height;
    const radius = Radius.circular(r);
    canvas.drawPath(Path()..moveTo(0, l)..lineTo(0, r)..arcToPoint(const Offset(r, 0), radius: radius)..lineTo(l, 0), p);
    canvas.drawPath(Path()..moveTo(w - l, 0)..lineTo(w - r, 0)..arcToPoint(Offset(w, r), radius: radius)..lineTo(w, l), p);
    canvas.drawPath(Path()..moveTo(w, h - l)..lineTo(w, h - r)..arcToPoint(Offset(w - r, h), radius: radius)..lineTo(w - l, h), p);
    canvas.drawPath(Path()..moveTo(l, h)..lineTo(r, h)..arcToPoint(Offset(0, h - r), radius: radius)..lineTo(0, h - l), p);
  }

  @override
  bool shouldRepaint(_FrameCornersPainter oldDelegate) => false;
}

/// Captured image with a shimmer sweep and "Reading details…".
class _ProcessingOverlay extends StatefulWidget {
  const _ProcessingOverlay();

  @override
  State<_ProcessingOverlay> createState() => _ProcessingOverlayState();
}

class _ProcessingOverlayState extends State<_ProcessingOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                final x = -2.0 + 4 * _c.value;
                return Container(
                  width: 270,
                  height: 180,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      begin: Alignment(x - 1, 0),
                      end: Alignment(x + 1, 0),
                      colors: [
                        Colors.white.withValues(alpha: 0.08),
                        Colors.white.withValues(alpha: 0.3),
                        Colors.white.withValues(alpha: 0.08),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            Semantics(
              liveRegion: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CupertinoActivityIndicator(color: Colors.white),
                  const SizedBox(width: 10),
                  Text('Reading details…', style: NovaType.headline.copyWith(color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
