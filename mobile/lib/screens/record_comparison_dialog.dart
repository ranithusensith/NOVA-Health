import 'package:flutter/material.dart';

import '../data/record_comparison.dart';

typedef ComparisonConsent = ({
  RecordComparison comparison,
  List<String> sources
});

class RecordComparisonDialog extends StatefulWidget {
  const RecordComparisonDialog({super.key});

  @override
  State<RecordComparisonDialog> createState() => _RecordComparisonDialogState();
}

class _RecordComparisonDialogState extends State<RecordComparisonDialog> {
  var _comparison = RecordComparison.sleepSteps;
  final _approved = <String>{};

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Compare records'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NOVA compares saved records from the last seven completed local days. '
              'This comparison stays in NOVA. Record data and results are never sent to Google Gemini.',
            ),
            const SizedBox(height: 12),
            DropdownButton<RecordComparison>(
              isExpanded: true,
              value: _comparison,
              items: [
                for (final comparison in RecordComparison.values)
                  DropdownMenuItem(
                      value: comparison, child: Text(comparison.label)),
              ],
              onChanged: (value) {
                if (value == null || value == _comparison) return;
                setState(() {
                  _comparison = value;
                  _approved.clear();
                });
              },
            ),
            const Text('Allow NOVA to read for this comparison'),
            for (final entry in _comparison.sources.entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _approved.contains(entry.key),
                title: Text(entry.value),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _approved.add(entry.key);
                  } else {
                    _approved.remove(entry.key);
                  }
                }),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _approved.length == _comparison.sources.length
                ? () => Navigator.pop<ComparisonConsent>(
                      context,
                      (comparison: _comparison, sources: _approved.toList()),
                    )
                : null,
            child: const Text('Compare'),
          ),
        ],
      );
}
