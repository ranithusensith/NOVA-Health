import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/health_repository.dart';
import '../data/nutrition.dart';
import '../data/scan_models.dart';
import '../services/privacy_diagnostics.dart';
import '../theme/nova_theme.dart';
import '../widgets/content.dart';
import '../widgets/glass.dart';
import 'scan_camera_screen.dart';

/// Food scan result. Values are AI estimates, editable, and nothing is saved
/// until the user confirms.
class FoodResultScreen extends StatefulWidget {
  const FoodResultScreen({
    super.key,
    required this.scan,
    required this.expectedOwner,
    this.imageBytes,
    this.saveMeal,
  });

  final FoodScan scan;
  final Uint8List? imageBytes;
  final String expectedOwner;
  final Future<void> Function(Map<String, dynamic>)? saveMeal;

  @override
  State<FoodResultScreen> createState() => _FoodResultScreenState();
}

class _FoodResultScreenState extends State<FoodResultScreen> {
  static String _fmt(double? value) => value?.toString() ?? '';

  late final TextEditingController _description =
      TextEditingController(text: widget.scan.description);
  late final TextEditingController _calories =
      TextEditingController(text: widget.scan.calories?.toString() ?? '');
  late final TextEditingController _protein =
      TextEditingController(text: _fmt(widget.scan.proteinG));
  late final TextEditingController _carbs =
      TextEditingController(text: _fmt(widget.scan.carbsG));
  late final TextEditingController _fat =
      TextEditingController(text: _fmt(widget.scan.fatG));

  bool _saving = false;
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in [_description, _calories, _protein, _carbs, _fat]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_saving) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!_form.currentState!.validate()) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Correct the highlighted fields before saving.')));
      return;
    }
    final navigator = Navigator.of(context);
    final description = _description.text.trim();
    final row = {
      'user_id': widget.expectedOwner,
      'description': description,
      'calories': NutritionField.calories.parse(_calories.text),
      'nutrients': {
        'protein_g': NutritionField.protein.parse(_protein.text),
        'carbs_g': NutritionField.carbs.parse(_carbs.text),
        'fat_g': NutritionField.fat.parse(_fat.text),
      },
      'source': 'scan',
      'status': 'confirmed',
    };
    setState(() => _saving = true);
    try {
      if (widget.saveMeal case final save?) {
        await save(row);
      } else {
        final db = Supabase.instance.client;
        if (db.auth.currentUser?.id != widget.expectedOwner) {
          throw StateError('Meal review account changed');
        }
        await db.from('meal_logs').insert(row);
      }
      if (!mounted) return;
      HealthRepository.notifyChanged();
      navigator.popUntil((r) => r.isFirst);
      messenger.showSnackBar(SnackBar(content: Text('$description saved')));
    } catch (_) {
      logAppEvent('Saving meal failed');
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(const SnackBar(
          content:
              Text('Could not save. Check your connection and try again.')));
    }
  }

  void _retake() {
    if (_saving) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ScanCameraScreen(initialMode: ScanMode.food),
      ),
    );
  }

  Widget _row(NovaColors c, String label, TextEditingController controller,
      {NutritionField? field}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: NovaType.subhead.copyWith(color: c.textSecondary)),
          ),
          Expanded(
            child: TextFormField(
              key: ValueKey(label),
              controller: controller,
              readOnly: _saving,
              keyboardType: field == null
                  ? TextInputType.text
                  : TextInputType.numberWithOptions(
                      decimal: field != NutritionField.calories),
              style: NovaType.body.copyWith(color: c.textPrimary),
              cursorColor: c.primary,
              decoration: InputDecoration(
                hintText: field == null ? label : 'Unknown',
                suffixText: field?.unit,
                errorMaxLines: 2,
                isDense: true,
              ),
              validator: (text) {
                final input = text ?? '';
                if (field == null) {
                  return input.trim().isEmpty ? 'Give the meal a name.' : null;
                }
                try {
                  field.parse(input);
                  return null;
                } on FormatException catch (error) {
                  return error.message;
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nova;
    final pad = MediaQuery.paddingOf(context);
    final lowConfidence = widget.scan.confidence < 0.6;

    Widget divider() =>
        Divider(height: 0.5, thickness: 0.5, color: c.separator);

    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(NovaSpace.margin, pad.top + 64,
                NovaSpace.margin, pad.bottom + 180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text('Check the meal',
                      style:
                          NovaType.largeTitle.copyWith(color: c.textPrimary)),
                ),
                const SizedBox(height: 4),
                Text(
                  'These are rough estimates from your photo. Correct them before saving, and leave unknown values blank.',
                  style: NovaType.subhead.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: NovaSpace.gap),
                if (widget.imageBytes != null) ...[
                  ExcludeSemantics(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(NovaRadius.card),
                      child: Image.memory(widget.imageBytes!,
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: NovaSpace.gap),
                ],
                if (lowConfidence) ...[
                  NovaCard(
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.exclamationmark_triangle_fill,
                            size: 22, color: c.warningContent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'The photo was hard to read. Please check the numbers.',
                            style:
                                NovaType.subhead.copyWith(color: c.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: NovaSpace.gap),
                ],
                NovaCard(
                  padding: EdgeInsets.zero,
                  child: Form(
                      key: _form,
                      child: Column(
                        children: [
                          _row(c, 'Meal', _description),
                          divider(),
                          _row(c, 'Calories', _calories,
                              field: NutritionField.calories),
                          divider(),
                          _row(c, 'Protein', _protein,
                              field: NutritionField.protein),
                          divider(),
                          _row(c, 'Carbs', _carbs, field: NutritionField.carbs),
                          divider(),
                          _row(c, 'Fat', _fat, field: NutritionField.fat),
                        ],
                      )),
                ),
                const SizedBox(height: NovaSpace.gap),
                Text(
                  'AI estimate, nothing is saved until you confirm.\nGuidance, not medical advice.',
                  textAlign: TextAlign.center,
                  style: NovaType.footnote.copyWith(color: c.textSecondary),
                ),
              ],
            ),
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
                  NovaButton(
                      label: 'Retake photo',
                      kind: NovaButtonKind.plain,
                      height: 44,
                      onPressed: _retake),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
