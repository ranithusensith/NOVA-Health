import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/health_repository.dart';
import '../data/scan_models.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import 'scan_camera_screen.dart';

/// Food scan result. Values are AI estimates, editable, and nothing is saved
/// until the user confirms.
class FoodResultScreen extends StatefulWidget {
  const FoodResultScreen({super.key, required this.scan, this.imageBytes});

  final FoodScan scan;
  final Uint8List? imageBytes;

  @override
  State<FoodResultScreen> createState() => _FoodResultScreenState();
}

class _FoodResultScreenState extends State<FoodResultScreen> {
  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  late final TextEditingController _description = TextEditingController(text: widget.scan.description);
  late final TextEditingController _calories = TextEditingController(text: '${widget.scan.calories}');
  late final TextEditingController _protein = TextEditingController(text: _fmt(widget.scan.proteinG));
  late final TextEditingController _carbs = TextEditingController(text: _fmt(widget.scan.carbsG));
  late final TextEditingController _fat = TextEditingController(text: _fmt(widget.scan.fatG));

  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_description, _calories, _protein, _carbs, _fat]) {
      c.dispose();
    }
    super.dispose();
  }

  double _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;

  Future<void> _confirm() async {
    if (_saving) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final description = _description.text.trim();
    if (description.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Give the meal a name.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final db = Supabase.instance.client;
      await db.from('meal_logs').insert({
        'user_id': db.auth.currentUser!.id,
        'description': description,
        'calories': _num(_calories).round(),
        'nutrients': {
          'protein_g': _num(_protein),
          'carbs_g': _num(_carbs),
          'fat_g': _num(_fat),
        },
        'source': 'scan',
        'status': 'confirmed', // the user has just confirmed these values
      });
      HealthRepository.notifyChanged();
      navigator.popUntil((r) => r.isFirst);
      messenger.showSnackBar(SnackBar(content: Text('$description saved')));
    } catch (e) {
      debugPrint('Saving meal failed: $e');
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(const SnackBar(content: Text('Could not save. Check your connection and try again.')));
    }
  }

  void _retake() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ScanCameraScreen(initialMode: ScanMode.food),
      ),
    );
  }

  Widget _row(NovaColors c, String label, TextEditingController controller,
      {String? suffix, bool numeric = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: NovaType.subhead.copyWith(color: c.textSecondary)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
              style: NovaType.body.copyWith(color: c.textPrimary),
              cursorColor: c.primary,
              decoration: InputDecoration.collapsed(hintText: label),
            ),
          ),
          if (suffix != null) Text(suffix, style: NovaType.subhead.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final lowConfidence = widget.scan.confidence < 0.6;

    Widget divider() => Divider(height: 0.5, thickness: 0.5, color: c.separator);

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64, NovaSpace.margin, pad.bottom + 180),
            children: [
              Semantics(
                header: true,
                child: Text('Check the meal', style: NovaType.largeTitle.copyWith(color: c.textPrimary)),
              ),
              const SizedBox(height: 4),
              Text(
                'These are rough estimates from your photo. Edit anything that looks off before saving.',
                style: NovaType.subhead.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: NovaSpace.gap),
              if (widget.imageBytes != null) ...[
                ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(NovaRadius.card),
                    child: Image.memory(widget.imageBytes!, height: 200, width: double.infinity, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(height: NovaSpace.gap),
              ],
              if (lowConfidence) ...[
                NovaCard(
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 22, color: c.warningContent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'The photo was hard to read. Please check the numbers.',
                          style: NovaType.subhead.copyWith(color: c.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.gap),
              ],
              NovaCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _row(c, 'Meal', _description, numeric: false),
                    divider(),
                    _row(c, 'Calories', _calories, suffix: 'kcal'),
                    divider(),
                    _row(c, 'Protein', _protein, suffix: 'g'),
                    divider(),
                    _row(c, 'Carbs', _carbs, suffix: 'g'),
                    divider(),
                    _row(c, 'Fat', _fat, suffix: 'g'),
                  ],
                ),
              ),
              const SizedBox(height: NovaSpace.gap),
              Text(
                'AI estimate, nothing is saved until you confirm.\nGuidance, not medical advice.',
                textAlign: TextAlign.center,
                style: NovaType.footnote.copyWith(color: c.textSecondary),
              ),
            ],
          ),
          Positioned(
            top: pad.top + 4,
            left: NovaSpace.margin,
            child: GlassBackButton(label: 'Scan', onTap: _retake),
          ),
          Positioned(
            left: NovaSpace.margin,
            right: NovaSpace.margin,
            bottom: (pad.bottom > 0 ? pad.bottom : 12) + 6,
            child: Glass(
              radius: NovaRadius.sheet,
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NovaButton(
                    label: _saving ? 'Saving…' : 'Confirm and save',
                    onPressed: _saving ? null : _confirm,
                  ),
                  const SizedBox(height: 4),
                  NovaButton(label: 'Retake photo', kind: NovaButtonKind.plain, height: 44, onPressed: _retake),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
