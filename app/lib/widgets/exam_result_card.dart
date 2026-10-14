import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'exam_board_picker.dart';

/// A shareable, festival-style RESULT CARD (SPEC v2.1 §21, ADVANCED).
///
/// Built ONLY from values the user enters on their own result slip — Assisto
/// never fetches, infers, or fabricates a result. Blank fields are simply
/// omitted. The card is a celebratory share graphic (brand gradient), in the
/// same spirit as the festival/Eid cards, with an honest "entered by you"
/// footnote so a forwarded card can't masquerade as an official result.
///
/// Mirrors core.logic.exam.result_card (the server builds the canonical copy).
class ExamResultCard extends StatelessWidget {
  final String name;
  final String examCode; // '' or a code from ExamRefData.examTypes
  final String boardCode; // '' or a code from ExamRefData.boards
  final String year;
  final String roll;
  final String gpa;
  final String grade;

  const ExamResultCard({
    super.key,
    this.name = '',
    this.examCode = '',
    this.boardCode = '',
    this.year = '',
    this.roll = '',
    this.gpa = '',
    this.grade = '',
  });

  String _header(AppLocalizations t) {
    final examName =
        examCode.isEmpty ? t.examCardDefaultHeader : ExamRefData.examName(t, examCode);
    return year.trim().isEmpty ? examName : '$examName ${year.trim()}';
  }

  /// The plain-text share body (mirrors exam.result_card text).
  String buildText(AppLocalizations t) {
    final lines = <String>[_header(t)];
    if (name.trim().isNotEmpty) lines.add('${t.examFieldName}: ${name.trim()}');
    if (roll.trim().isNotEmpty) lines.add('${t.examFieldRoll}: ${roll.trim()}');
    if (boardCode.isNotEmpty) {
      lines.add('${t.examFieldBoard}: ${ExamRefData.boardName(t, boardCode)}');
    }
    if (gpa.trim().isNotEmpty) lines.add('${t.examFieldGpa}: ${gpa.trim()}');
    if (grade.trim().isNotEmpty) lines.add('${t.examFieldGrade}: ${grade.trim()}');
    lines.add(t.examCardEnteredFootnote);
    return lines.join('\n');
  }

  bool get _hasAny =>
      name.trim().isNotEmpty ||
      roll.trim().isNotEmpty ||
      boardCode.isNotEmpty ||
      gpa.trim().isNotEmpty ||
      grade.trim().isNotEmpty ||
      year.trim().isNotEmpty;

  Future<void> _share(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final text = buildText(t);
    try {
      await Share.share(text, subject: _header(t));
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(t.examCardCopied)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the festival-style card preview
      Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.celebration, color: Colors.white, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                _header(t),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          if (!_hasAny)
            Text(t.examCardEmptyHint,
                style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13))
          else ...[
            _row(t.examFieldName, name),
            _row(t.examFieldRoll, roll),
            _row(t.examFieldBoard,
                boardCode.isEmpty ? '' : ExamRefData.boardName(t, boardCode)),
            _row(t.examFieldGpa, gpa),
            _row(t.examFieldGrade, grade),
          ],
          const SizedBox(height: Gap.sm),
          Text(t.examCardEnteredFootnote,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 10.5,
                  height: 1.3)),
        ]),
      ),
      const SizedBox(height: Gap.sm),
      OutlinedButton.icon(
        icon: const Icon(Icons.share, size: 16),
        label: Text(t.examShareCard),
        onPressed: _hasAny ? () => _share(context) : null,
      ),
    ]);
  }

  Widget _row(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label: ',
            style: TextStyle(
                color: Colors.white.withOpacity(0.85),
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        Expanded(
          child: Text(value.trim(),
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}
