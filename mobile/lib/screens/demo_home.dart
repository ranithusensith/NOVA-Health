import 'package:flutter/widgets.dart';

import '../theme/nova_theme.dart';
import '../data/weather.dart';
import 'weather_card.dart';
import '../widgets/content.dart';
import '../widgets/states.dart';

enum _DemoScan {
  prescription('Prescription', 'Sample medicine A · 1 tablet · once daily'),
  lab('Lab report', 'Sample analyte · ≤0.40 mg/L · date unknown'),
  food('Meal photo', 'Sample rice and vegetables · 430 kcal');

  const _DemoScan(this.title, this.result);
  final String title;
  final String result;
}

/// The demo only accepts bundled samples and saves them in this screen's memory.
class DemoHome extends StatefulWidget {
  const DemoHome({super.key});

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  _DemoScan? _preview;
  final _saved = <_DemoScan>{};

  @override
  Widget build(BuildContext context) {
    final colors = context.nova;
    final preview = _preview;
    return ColoredBox(
      color: colors.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: ListView(
              padding: const EdgeInsets.all(NovaSpace.margin),
              children: [
                Semantics(
                  header: true,
                  child: Text('Demo mode',
                      style: NovaType.largeTitle
                          .copyWith(color: colors.textPrimary)),
                ),
                const SizedBox(height: 8),
                Text(
                  'Synthetic samples only. Demo saves stay in memory and clear when the app restarts.',
                  style: NovaType.body.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: 24),
                const SectionLabel('Try a sample scan'),
                for (final sample in _DemoScan.values) ...[
                  NovaButton(
                    label: 'Preview ${sample.title.toLowerCase()}',
                    kind: NovaButtonKind.secondary,
                    onPressed: () => setState(() => _preview = sample),
                  ),
                  const SizedBox(height: 8),
                ],
                if (preview != null) ...[
                  const SizedBox(height: 16),
                  NovaCard(
                    tone: NovaCardTone.tinted,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${preview.title} preview',
                            style: NovaType.headline
                                .copyWith(color: colors.textPrimary)),
                        const SizedBox(height: 8),
                        Text(preview.result,
                            style: NovaType.body
                                .copyWith(color: colors.textPrimary)),
                        const SizedBox(height: 16),
                        NovaButton(
                          label: 'Save to demo',
                          onPressed: _saved.contains(preview)
                              ? null
                              : () => setState(() => _saved.add(preview)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const SectionLabel('Saved demo samples'),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _saved.isEmpty
                        ? 'No demo samples saved.'
                        : _saved.map((sample) => sample.title).join('\n'),
                    style: NovaType.body.copyWith(color: colors.textPrimary),
                  ),
                ),
                const SizedBox(height: 24),
                const NovaCard(
                  child: WeatherDetails(
                    status: WeatherStatus.demo,
                    snapshot: WeatherSnapshot(
                      status: WeatherStatus.demo,
                      current: WeatherConditions(temperature: 27, feelsLike: 29, humidity: 61, condition: 'Partly cloudy'),
                      forecast: [WeatherDay('Sample day', low: 21, high: 28, precipitation: 20, condition: 'Partly cloudy')],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
