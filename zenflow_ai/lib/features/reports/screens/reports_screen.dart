import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zenflow_ai/features/reports/providers/reports_provider.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportsFilter _filter = ReportsFilter.thisWeek;
  // 0 = Workouts, 1 = Calories
  int _chartMode = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dataAsync = ref.watch(reportsProvider(_filter));

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App Bar ────────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            floating: true,
            expandedHeight: 110,
            backgroundColor: theme.colorScheme.surface,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                'Reports',
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface),
              ),
              titlePadding:
                  const EdgeInsetsDirectional.only(start: 20, bottom: 16),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── Filter Chips ──────────────────────────────────
                _FilterChips(
                  selected: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: 20),

                // ── Chart Mode Toggle ─────────────────────────────
                _SegmentedToggle(
                  selected: _chartMode,
                  labels: const ['Workouts', 'Calories'],
                  onChanged: (i) => setState(() => _chartMode = i),
                ),
                const SizedBox(height: 20),

                // ── Chart ─────────────────────────────────────────
                dataAsync.when(
                  data: (data) => data.isEmpty
                      ? _EmptyState(filter: _filter)
                      : _ChartCard(
                          data: data,
                          chartMode: _chartMode,
                          filter: _filter,
                        ),
                  loading: () => const _ChartSkeleton(),
                  error: (e, _) => _ErrorState(message: e.toString(),
                      onRetry: () => ref.invalidate(reportsProvider(_filter))),
                ),

                const SizedBox(height: 20),

                // ── Summary Cards ─────────────────────────────────
                dataAsync.when(
                  data: (data) => _SummaryRow(data: data),
                  loading: () => const _SummaryRowSkeleton(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Filter Chips ──────────────────────────────────────────────────────────────

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onChanged});
  final ReportsFilter selected;
  final ValueChanged<ReportsFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const filters = [
      (ReportsFilter.today, 'Today'),
      (ReportsFilter.thisWeek, 'This Week'),
      (ReportsFilter.overall, 'Overall'),
    ];
    return Row(
      children: filters
          .map((pair) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(pair.$2,
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          color: selected == pair.$1
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurface)),
                  selected: selected == pair.$1,
                  onSelected: (_) => onChanged(pair.$1),
                  selectedColor: theme.colorScheme.primary,
                  checkmarkColor: theme.colorScheme.onPrimary,
                  backgroundColor:
                      theme.colorScheme.surfaceContainerHighest,
                  side: BorderSide.none,
                ),
              ))
          .toList(),
    );
  }
}

// ── Segmented Toggle ──────────────────────────────────────────────────────────

class _SegmentedToggle extends StatelessWidget {
  const _SegmentedToggle(
      {required this.selected,
      required this.labels,
      required this.onChanged});
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: List.generate(labels.length, (i) {
          final isSelected = selected == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface.withOpacity(0.6)),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ── Chart Card ────────────────────────────────────────────────────────────────

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.data,
    required this.chartMode,
    required this.filter,
  });

  final ReportsData data;
  final int chartMode;
  final ReportsFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCalories = chartMode == 1;
    final barColor =
        isCalories ? const Color(0xFFFF7043) : theme.colorScheme.primary;
    final label = isCalories ? 'kcal' : 'workouts';

    final bars = data.entries.asMap().entries.map((e) {
      final entry = e.value;
      final yVal =
          isCalories ? entry.calories.toDouble() : entry.workouts.toDouble();
      return BarChartGroupData(
        x: e.key,
        barRods: [
          BarChartRodData(
            toY: yVal,
            color: barColor,
            width: _barWidth(data.entries.length),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            backDrawRodData: BackgroundBarChartRodData(
              show: true,
              toY: _maxY(isCalories) * 1.1,
              color: barColor.withOpacity(0.06),
            ),
          ),
        ],
      );
    }).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 20, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isCalories ? 'Calories Burned' : 'Workouts Completed',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: theme.colorScheme.onSurface),
          ),
          Text(
            _subLabel(filter),
            style: GoogleFonts.inter(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withOpacity(0.45)),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 200,
            child: BarChart(
              BarChartData(
                maxY: _maxY(isCalories) * 1.15,
                minY: 0,
                barGroups: bars,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: _maxY(isCalories) / 4,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                    strokeWidth: 1,
                    dashArray: [4, 4],
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 38,
                      interval: _maxY(isCalories) / 4,
                      getTitlesWidget: (v, _) => Text(
                        v.toInt().toString(),
                        style: GoogleFonts.inter(
                            fontSize: 10,
                            color: theme.colorScheme.onSurface.withOpacity(0.4)),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i >= data.entries.length) return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _shortDate(data.entries[i].date),
                            style: GoogleFonts.inter(
                                fontSize: 10,
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.45)),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) =>
                        theme.colorScheme.inverseSurface,
                    getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                      '${rod.toY.toInt()} $label',
                      GoogleFonts.inter(
                          color: theme.colorScheme.onInverseSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 12),
                    ),
                  ),
                ),
              ),
              swapAnimationDuration: const Duration(milliseconds: 400),
              swapAnimationCurve: Curves.easeInOut,
            ),
          ),
        ],
      ),
    );
  }

  double _maxY(bool isCalories) {
    if (data.entries.isEmpty) return 10;
    final max = isCalories
        ? data.entries.map((e) => e.calories).reduce((a, b) => a > b ? a : b)
        : data.entries.map((e) => e.workouts).reduce((a, b) => a > b ? a : b);
    return max <= 0 ? 10 : max.toDouble();
  }

  double _barWidth(int count) {
    if (count <= 2) return 32;
    if (count <= 7) return 22;
    return 14;
  }

  String _shortDate(String date) {
    final parts = date.split('-');
    if (parts.length < 3) return date;
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final m = int.tryParse(parts[1]) ?? 1;
    return '${months[m - 1]} ${parts[2]}';
  }

  String _subLabel(ReportsFilter f) {
    switch (f) {
      case ReportsFilter.today: return 'Today';
      case ReportsFilter.thisWeek: return 'Last 7 days';
      case ReportsFilter.overall: return 'All time';
    }
  }
}

// ── Summary Row ───────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.data});
  final ReportsData data;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _SummaryCard(
                label: 'Workouts',
                value: data.totalWorkouts.toString(),
                icon: Icons.fitness_center_rounded,
                color: Theme.of(context).colorScheme.primary)),
        const SizedBox(width: 12),
        Expanded(
            child: _SummaryCard(
                label: 'Calories',
                value: '${data.totalCalories} kcal',
                icon: Icons.local_fire_department_rounded,
                color: const Color(0xFFFF7043))),
        const SizedBox(width: 12),
        Expanded(
            child: _SummaryCard(
                label: 'Minutes',
                value: data.totalMinutes.toString(),
                icon: Icons.timer_outlined,
                color: Colors.purple)),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 8),
          Text(value,
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: theme.colorScheme.onSurface),
              overflow: TextOverflow.ellipsis),
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 10,
                  color: theme.colorScheme.onSurface.withOpacity(0.5))),
        ],
      ),
    );
  }
}

// ── Empty / Error / Skeleton States ──────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});
  final ReportsFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = filter == ReportsFilter.today
        ? 'No workouts today yet.'
        : filter == ReportsFilter.thisWeek
            ? 'No workouts this week.'
            : 'No workout history yet.';

    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.35)),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bar_chart_rounded,
                size: 48, color: theme.colorScheme.onSurface.withOpacity(0.15)),
            const SizedBox(height: 12),
            Text(label,
                style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontSize: 14)),
            const SizedBox(height: 4),
            Text('Complete a workout to see your stats.',
                style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface.withOpacity(0.3),
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded,
              color: theme.colorScheme.error, size: 36),
          const SizedBox(height: 8),
          Text('Could not load reports.',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onErrorContainer)),
          const SizedBox(height: 4),
          Text(message,
              style: GoogleFonts.inter(
                  fontSize: 11,
                  color: theme.colorScheme.onErrorContainer.withOpacity(0.6)),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          FilledButton.tonal(
              onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
    );
  }
}

class _SummaryRowSkeleton extends StatelessWidget {
  const _SummaryRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(
          3,
          (i) => Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i < 2 ? 12 : 0),
                  child: Container(
                    height: 90,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              )),
    );
  }
}
