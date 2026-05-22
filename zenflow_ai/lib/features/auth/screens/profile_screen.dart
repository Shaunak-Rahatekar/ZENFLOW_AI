import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zenflow_ai/features/auth/providers/profile_provider.dart';
import 'package:zenflow_ai/features/auth/screens/auth_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();

  // Known health conditions
  static const _allConditions = [
    'Hypertension', 'Diabetes', 'Back Pain', 'Knee Pain',
    'Asthma', 'Obesity', 'Arthritis', 'Anxiety / Stress',
  ];

  Set<String> _selectedConditions = {};
  String? _fitnessGoal;
  int _dailyMinutes = 30;
  bool _dirty = false;

  static const _goals = ['Weight Loss', 'Muscle Gain', 'Flexibility', 'Stress Relief', 'General Fitness'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _weightCtrl.dispose();
    _heightCtrl.dispose();
    super.dispose();
  }

  void _populateFromProfile(UserProfile p) {
    if (!_dirty) {
      _nameCtrl.text = p.name ?? '';
      _weightCtrl.text = p.weightKg?.toStringAsFixed(1) ?? '';
      _heightCtrl.text = p.heightCm?.toStringAsFixed(0) ?? '';
      _selectedConditions = Set.from(p.healthConditions);
      _fitnessGoal = p.fitnessGoal;
      _dailyMinutes = p.dailyMinutesAvailable;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final weightRaw = _weightCtrl.text.trim();
    final weight = double.tryParse(weightRaw);
    final heightRaw = _heightCtrl.text.trim();
    final height = double.tryParse(heightRaw);

    final profile = ref.read(profileProvider).value;
    final bool weightChanged = weight != profile?.weightKg;
    final bool heightChanged = height != profile?.heightCm;
    final bool conditionsChanged =
        !_setsEqual(_selectedConditions, Set.from(profile?.healthConditions ?? []));
    final bool timeChanged = _dailyMinutes != profile?.dailyMinutesAvailable;
    final bool needsRegen = weightChanged || heightChanged || conditionsChanged || timeChanged;

    await ref.read(profileProvider.notifier).saveAndRegenerate(
          name: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
          weightKg: weight,
          heightCm: height,
          healthConditions: _selectedConditions.toList(),
          fitnessGoal: _fitnessGoal,
          dailyMinutesAvailable: _dailyMinutes,
        );

    if (!mounted) return;
    setState(() => _dirty = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          needsRegen
              ? '✅ Profile saved. New split is being generated…'
              : '✅ Profile saved.',
          style: GoogleFonts.inter(fontWeight: FontWeight.w500),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  bool _setsEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileAsync = ref.watch(profileProvider);

    return profileAsync.when(
      data: (profile) {
        if (profile != null) _populateFromProfile(profile);
        return _buildScaffold(theme, profile, profileAsync.isLoading);
      },
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: _ProfileErrorState(
          message: e.toString(),
          onRetry: () => ref.invalidate(profileProvider),
        ),
      ),
    );
  }

  Widget _buildScaffold(ThemeData theme, UserProfile? profile, bool saving) {
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            pinned: true,
            floating: true,
            expandedHeight: 110,
            backgroundColor: theme.colorScheme.surface,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              title: Text('Profile',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface)),
              titlePadding:
                  const EdgeInsetsDirectional.only(start: 20, bottom: 16),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Log Out',
                onPressed: () async {
                  await Supabase.instance.client.auth.signOut();
                  if (context.mounted) {
                    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const AuthScreen()),
                      (route) => false,
                    );
                  }
                },
              ),
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton(
                    onPressed: saving ? null : _save,
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 20)),
                    child: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('Save',
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),

          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 60),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── Avatar + Email ─────────────────────────────
                _AvatarSection(profile: profile),
                const SizedBox(height: 28),

                Form(
                  key: _formKey,
                  onChanged: () => setState(() => _dirty = true),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Basic Info ─────────────────────────────
                      _SectionHeader(label: 'Basic Info'),
                      const SizedBox(height: 12),

                      _FormField(
                        controller: _nameCtrl,
                        label: 'Full Name',
                        icon: Icons.person_outline_rounded,
                        validator: (_) => null,
                      ),
                      const SizedBox(height: 12),

                      _FormField(
                        controller: _weightCtrl,
                        label: 'Weight (kg)',
                        icon: Icons.monitor_weight_outlined,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                        ],
                        validator: (v) {
                          if (v == null || v.isEmpty) return null;
                          if (double.tryParse(v) == null) return 'Enter a valid number';
                          if (double.parse(v) < 20 || double.parse(v) > 300) {
                            return 'Weight must be between 20–300 kg';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),

                      _FormField(
                        controller: _heightCtrl,
                        label: 'Height (cm)',
                        icon: Icons.height_rounded,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: (v) {
                          if (v == null || v.isEmpty) return null;
                          final h = double.tryParse(v);
                          if (h == null) return 'Enter a valid number';
                          if (h < 100 || h > 250) return 'Height must be 100–250 cm';
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),

                      // ── Daily Time Available ───────────────────
                      _SectionHeader(
                        label: 'Daily Time Available',
                        subtitle: 'How many minutes can you practice each day?',
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _dailyMinutes.toDouble(),
                              min: 10,
                              max: 90,
                              divisions: 16,
                              label: '$_dailyMinutes min',
                              onChanged: (v) => setState(() {
                                _dailyMinutes = v.round();
                                _dirty = true;
                              }),
                            ),
                          ),
                          Container(
                            width: 64,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$_dailyMinutes min',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),

                      // ── Fitness Goal ───────────────────────────
                      _SectionHeader(label: 'Fitness Goal'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _goals.map((goal) {
                          final selected = _fitnessGoal == goal;
                          return ChoiceChip(
                            label: Text(goal,
                                style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: selected
                                        ? Theme.of(context).colorScheme.onPrimary
                                        : Theme.of(context).colorScheme.onSurface)),
                            selected: selected,
                            onSelected: (_) => setState(() {
                              _fitnessGoal = goal;
                              _dirty = true;
                            }),
                            selectedColor: Theme.of(context).colorScheme.primary,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            side: BorderSide.none,
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),

                      // ── Health Conditions ──────────────────────
                      _SectionHeader(
                          label: 'Health Conditions',
                          subtitle: 'Changes trigger AI split regeneration'),
                      const SizedBox(height: 12),

                      _HealthConditionsGrid(
                        allConditions: _allConditions,
                        selected: _selectedConditions,
                        onToggle: (cond) => setState(() {
                          if (_selectedConditions.contains(cond)) {
                            _selectedConditions.remove(cond);
                          } else {
                            _selectedConditions.add(cond);
                          }
                          _dirty = true;
                        }),
                      ),

                      const SizedBox(height: 28),

                      // ── Regenerate Warning ─────────────────────
                      if (_dirty) ...[
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer
                                .withOpacity(0.4),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.auto_awesome_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Saving weight or condition changes will auto-regenerate your 7-day plan.',
                                  style: GoogleFonts.inter(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Widgets ───────────────────────────────────────────────────────────────────

class _AvatarSection extends StatelessWidget {
  const _AvatarSection({required this.profile});
  final UserProfile? profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = (profile?.name?.isNotEmpty ?? false)
        ? profile!.name![0].toUpperCase()
        : '?';
    return Row(
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(initials,
              style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onPrimaryContainer)),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              profile?.name?.isNotEmpty ?? false
                  ? profile!.name!
                  : 'Your Name',
              style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface),
            ),
            if (profile?.email?.isNotEmpty ?? false)
              Text(
                profile!.email!,
                style: GoogleFonts.inter(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withOpacity(0.5)),
              ),
          ],
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.subtitle});
  final String label;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface)),
        if (subtitle != null)
          Text(subtitle!,
              style: GoogleFonts.inter(
                  fontSize: 11,
                  color: theme.colorScheme.primary.withOpacity(0.8))),
      ],
    );
  }
}

class _FormField extends StatelessWidget {
  const _FormField({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.inputFormatters,
    required this.validator,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validator: validator,
      style: GoogleFonts.inter(fontSize: 15, color: theme.colorScheme.onSurface),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(fontSize: 14),
        prefixIcon: Icon(icon, size: 20),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              BorderSide(color: theme.colorScheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.error),
        ),
      ),
    );
  }
}

class _HealthConditionsGrid extends StatelessWidget {
  const _HealthConditionsGrid({
    required this.allConditions,
    required this.selected,
    required this.onToggle,
  });

  final List<String> allConditions;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: allConditions.map((cond) {
        final isSelected = selected.contains(cond);
        return FilterChip(
          label: Text(cond,
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface)),
          selected: isSelected,
          onSelected: (_) => onToggle(cond),
          selectedColor: theme.colorScheme.primary,
          checkmarkColor: theme.colorScheme.onPrimary,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          side: BorderSide.none,
        );
      }).toList(),
    );
  }
}

class _ProfileErrorState extends StatelessWidget {
  const _ProfileErrorState(
      {required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 56, color: theme.colorScheme.error.withOpacity(0.6)),
            const SizedBox(height: 16),
            Text('Could not load profile.',
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(height: 8),
            Text(message,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.5)),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
