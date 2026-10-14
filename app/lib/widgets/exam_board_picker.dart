import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// ADVANCED exam-result support widgets (SPEC v2.1 §21).
///
/// OFFICIAL-SOURCE-ONLY by construction: a real result can only ever be read
/// from the official Bangladesh education-board portal, opened by the user in
/// their browser. We NEVER scrape it and NEVER render a result inside the app
/// (that would risk showing a stale or fabricated value). These widgets only:
///   - let the user pick their board + exam (so the watcher is labelled right),
///   - open the official portal honestly ("checks the official board site"),
///   - warn when a pasted URL is NOT an official board domain.
///
/// Mirrors core.logic.exam (BOARDS, EXAM_TYPES, OFFICIAL_RESULTS_PORTAL,
/// is_official_result_url, official_check_target).

// The single official public result portal (mirrors exam.OFFICIAL_RESULTS_PORTAL).
const String kOfficialResultsPortal =
    'https://eboardresults.com/en/ebr.app/home/';

// Canonical official domains (mirrors exam.OFFICIAL_RESULT_DOMAINS).
const List<String> kOfficialResultDomains = [
  'educationboardresults.gov.bd',
  'eboardresults.com',
  'results.ebaube.gov.bd',
];

/// True only for the sanctioned official board domains.
/// Mirrors exam.is_official_result_url.
bool isOfficialResultUrl(String url) {
  final u = url.trim().toLowerCase();
  if (!(u.startsWith('http://') || u.startsWith('https://'))) return false;
  for (final d in kOfficialResultDomains) {
    if (u.contains('://$d') || u.contains('.$d') || u.contains('/$d')) {
      return true;
    }
  }
  return false;
}

/// Board + exam-type codes with localized labels (mirrors exam.BOARDS / EXAM_TYPES).
class ExamRefData {
  ExamRefData._();

  static const boards = [
    'dhaka', 'rajshahi', 'chittagong', 'khulna', 'barisal',
    'sylhet', 'comilla', 'dinajpur', 'mymensingh', 'madrasah', 'technical',
  ];

  static const examTypes = ['ssc', 'hsc', 'jsc', 'psc', 'dakhil', 'alim'];

  static String boardName(AppLocalizations t, String code) {
    switch (code) {
      case 'dhaka':
        return t.examBoardDhaka;
      case 'rajshahi':
        return t.examBoardRajshahi;
      case 'chittagong':
        return t.examBoardChattogram;
      case 'khulna':
        return t.examBoardKhulna;
      case 'barisal':
        return t.examBoardBarishal;
      case 'sylhet':
        return t.examBoardSylhet;
      case 'comilla':
        return t.examBoardCumilla;
      case 'dinajpur':
        return t.examBoardDinajpur;
      case 'mymensingh':
        return t.examBoardMymensingh;
      case 'madrasah':
        return t.examBoardMadrasah;
      case 'technical':
        return t.examBoardTechnical;
    }
    return code;
  }

  static String examName(AppLocalizations t, String code) {
    switch (code) {
      case 'ssc':
        return t.examTypeSsc;
      case 'hsc':
        return t.examTypeHsc;
      case 'jsc':
        return t.examTypeJsc;
      case 'psc':
        return t.examTypePsc;
      case 'dakhil':
        return t.examTypeDakhil;
      case 'alim':
        return t.examTypeAlim;
    }
    return code;
  }
}

/// Exam-type + board dropdowns. Values are codes; callbacks report the picked
/// code (or null to clear).
class ExamBoardPicker extends StatelessWidget {
  final String? exam;
  final String? board;
  final ValueChanged<String?> onExam;
  final ValueChanged<String?> onBoard;

  const ExamBoardPicker({
    super.key,
    required this.exam,
    required this.board,
    required this.onExam,
    required this.onBoard,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Row(children: [
      Expanded(
        child: DropdownButtonFormField<String>(
          initialValue: exam,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t.examFieldExam,
            isDense: true,
          ),
          items: [
            for (final c in ExamRefData.examTypes)
              DropdownMenuItem(value: c, child: Text(ExamRefData.examName(t, c))),
          ],
          onChanged: onExam,
        ),
      ),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: DropdownButtonFormField<String>(
          initialValue: board,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t.examFieldBoard,
            isDense: true,
          ),
          items: [
            for (final c in ExamRefData.boards)
              DropdownMenuItem(value: c, child: Text(ExamRefData.boardName(t, c))),
          ],
          onChanged: onBoard,
        ),
      ),
    ]);
  }
}

/// A clearly-labelled "check on the OFFICIAL board site" action. It opens the
/// official portal in the browser — it NEVER shows a result inside Assisto.
class ExamOfficialCheck extends StatelessWidget {
  const ExamOfficialCheck({super.key});

  Future<void> _open(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse(kOfficialResultsPortal);
    final ok = await canLaunchUrl(uri);
    if (ok) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(t.examCouldNotOpen)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          icon: const Icon(Icons.verified_outlined, size: 18),
          label: Text(t.examCheckOfficial),
          onPressed: () => _open(context),
        ),
      ),
      const SizedBox(height: Gap.xs),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.shield_outlined, size: 14, color: scheme.secondary),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(
            t.examOfficialOnlyNote,
            style: TextStyle(fontSize: 11.5, color: scheme.secondary, height: 1.35),
          ),
        ),
      ]),
    ]);
  }
}
