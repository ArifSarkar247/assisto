import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import 'family_screen.dart';

/// First-run onboarding — a quick "wow" in under a minute: see what Assisto
/// does, then jump straight into a real task (add a parent's medicine, or just
/// start chatting). Shown once; sets the 'onboarded' flag.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await Settings.setBool('onboarded', true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String t(String bn, String e) => en ? e : bn;
    final slides = [
      (Icons.chat_bubble_outline, t('শুধু বলুন', 'Just tell me'),
          t('"৫০০ টাকা খরচ খাবার", "কাল ৮টায় ওষুধ মনে করিয়ে দিও" — বাংলা বা English, লিখে বা বলে।',
              '"500 taka food expense", "remind me medicine at 8" — Bangla or English, text or voice.')),
      (Icons.diversity_1_outlined, t('পরিবারের খেয়াল', 'Care for family'),
          t('বাবা-মায়ের ওষুধের সময়, স্কুল, ইমার্জেন্সি — সব এক জায়গায়।',
              "Parents' medicines, school, emergencies — all in one place.")),
      (Icons.lock_outline, t('আপনার হাতেই নিয়ন্ত্রণ', 'You stay in control'),
          t('ডাটা বিক্রি হয় না; কিছু করার আগে অনুমতি নেয়; অফলাইনেও চলে।',
              'Data is never sold; it asks before acting; works offline too.')),
    ];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.topRight,
            child: TextButton(onPressed: _finish, child: Text(t('এড়িয়ে যান', 'Skip'))),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pc,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: slides.length,
              itemBuilder: (_, i) {
                final s = slides[i];
                return Padding(
                  padding: const EdgeInsets.all(Gap.xxl),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(
                      height: 96, width: 96,
                      decoration: BoxDecoration(
                          gradient: Brand.gradient, shape: BoxShape.circle),
                      child: Icon(s.$1, size: 46, color: Colors.white),
                    ),
                    const SizedBox(height: Gap.xl),
                    Text(s.$2, textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: Gap.md),
                    Text(s.$3, textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5)),
                  ]),
                );
              },
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (int i = 0; i < slides.length; i++)
              AnimatedContainer(
                duration: Motion.fast,
                margin: const EdgeInsets.all(3),
                height: 8,
                width: _page == i ? 22 : 8,
                decoration: BoxDecoration(
                  color: _page == i ? scheme.primary : scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.lg),
            child: Column(children: [
              if (_page < slides.length - 1)
                FilledButton(
                  onPressed: () => _pc.nextPage(
                      duration: Motion.base, curve: Curves.easeOut),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  child: Text(t('পরবর্তী', 'Next')),
                )
              else ...[
                FilledButton.icon(
                  onPressed: () async {
                    await _finish();
                    if (context.mounted) {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const FamilyScreen()));
                    }
                  },
                  icon: const Icon(Icons.medication_outlined),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  label: Text(t('পরিবারের ওষুধ যোগ করে শুরু করি', "Start — add a family member's medicine")),
                ),
                const SizedBox(height: Gap.sm),
                TextButton(onPressed: _finish, child: Text(t('শুধু চ্যাট শুরু করি', 'Just start chatting'))),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
