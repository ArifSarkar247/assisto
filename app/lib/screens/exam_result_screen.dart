import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/exam_board_picker.dart';
import '../widgets/exam_gpa_explainer.dart';
import '../widgets/exam_result_card.dart';
import '../widgets/exam_student_watch.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../services/action_feedback.dart'; // db1
import '../notifications.dart'; // f6

/// ADVANCED exam-result module (SPEC v2.1 §21) for BD board/university results
/// (SSC / HSC / JSC / PSC / Dakhil / Alim …).
///
/// OFFICIAL-SOURCE-ONLY, NEVER-FABRICATE guarantees (the whole point):
///   - A result-day WATCHER (exam + roll + board + reg + expected date). On
///     result day it NEVER shows a fabricated result; it shows an honest
///     traffic-spike note and a button that opens the OFFICIAL board site.
///   - CHECK RESULT opens the official educationboardresults / eboardresults
///     portal in the browser. Assisto does not scrape it or render a result.
///   - A pasted URL that is NOT an official board domain is flagged, not trusted.
///   - A shareable festival-style result CARD built ONLY from values the user
///     types off their own slip, with an "entered by you" footnote.
///   - A GPA / grade EXPLAINER using the board's PUBLIC scale (not a result).
///   - A COUNTDOWN to the expected result date.
///   - MULTI-STUDENT watch for parents / teachers.
///
/// Mirrors core.logic.exam.
class ExamResultScreen extends StatefulWidget {
  const ExamResultScreen({super.key});
  @override
  State<ExamResultScreen> createState() => _ExamResultScreenState();
}

class _ExamResultScreenState extends State<ExamResultScreen> {
  // watcher
  final _label = TextEditingController();
  final _url = TextEditingController();
  final _reg = TextEditingController();
  final _roll = TextEditingController();
  String? _exam;
  String? _board;
  DateTime? _expected;
  bool _saving = false;

  // result card (user-entered only)
  final _name = TextEditingController();
  final _year = TextEditingController();
  final _cardRoll = TextEditingController();
  final _gpa = TextEditingController();
  final _grade = TextEditingController();

  // multi-student watch
  final List<ExamStudent> _students = [ExamStudent()];

  @override
  void initState() {
    super.initState();
    // Live preview of the share card + GPA band as the user types.
    for (final c in [_name, _year, _cardRoll, _gpa, _grade, _label, _url, _roll, _reg]) {
      c.addListener(_onEdit);
    }
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      _label, _url, _reg, _roll, _name, _year, _cardRoll, _gpa, _grade
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ({String state, int days}) _phase() {
    final exp = _expected;
    if (exp == null) return (state: 'watching', days: 0);
    final today = DateUtils.dateOnly(DateTime.now());
    final d = DateUtils.dateOnly(exp);
    if (today.isBefore(d)) return (state: 'waiting', days: d.difference(today).inDays);
    return (state: 'watching', days: 0);
  }

  Future<void> _saveWatcher() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final url = _url.text.trim();
    if (url.isNotEmpty && !(url.startsWith('http://') || url.startsWith('https://'))) {
      messenger.showSnackBar(SnackBar(content: Text(t.examUrlInvalid)));
      return;
    }
    if (url.isEmpty && _expected == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.examUrlOrDateRequired)));
      return;
    }
    // Honest: if they pasted a non-official URL, say so (but still allow it).
    if (url.isNotEmpty && !isOfficialResultUrl(url)) {
      messenger.showSnackBar(SnackBar(content: Text(t.examUrlNotOfficial)));
    }
    final students = _students
        .where((s) => !s.isBlank)
        .map((s) => s.toJson())
        .toList();
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.postJson('/exam/watcher', {
        'label': _label.text.trim(),
        'url': url,
        'expected_date': _expected?.toIso8601String(),
        'roll': _roll.text.trim(),
        'reg': _reg.text.trim(),
        'board': _board ?? '',
        'exam': _exam ?? '',
        'students': students,
      });
      // f6: the server keeps the watcher but never notifies, so the
      // result-day reminder is a REAL local notification on this phone.
      final exp = _expected;
      if (exp != null) {
        final label = _label.text.trim();
        await Notifications.schedule(
            examReminderId(url, exp),
            label.isEmpty ? t.examTitle : label,
            t.f6ExamResultDayBody,
            DateTime(exp.year, exp.month, exp.day, 9));
      }
      messenger.showSnackBar(SnackBar(
          content: Text(exp != null ? t.f6ExamWatcherSavedReminder : t.examWatcherSaved)));
    } catch (_) {
      // f6: never "saved on this device" — nothing was saved.
      messenger.showSnackBar(SnackBar(content: Text(t.saveFailed)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openUrl() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    await openForUser(context, Uri.parse(url), // db1
        where: 'exam.openBoard', mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final phase = _phase();
    final df = DateFormat('d MMM yyyy', appDateLocale(context));
    final urlText = _url.text.trim();
    final urlFlag = urlText.isNotEmpty && !isOfficialResultUrl(urlText);

    return Scaffold(
      appBar: AppBar(title: Text(t.examTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          // ---- result-day watcher -------------------------------------
          _sectionTitle(t.examWatcherSection),
          const SizedBox(height: Gap.sm),
          ExamBoardPicker(
            exam: _exam,
            board: _board,
            onExam: (v) => setState(() => _exam = v),
            onBoard: (v) => setState(() => _board = v),
          ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _roll,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.examFieldRoll, isDense: true),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: _reg,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.examFieldReg, isDense: true),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _label,
            decoration: InputDecoration(labelText: t.examLabelField, isDense: true),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: t.examUrlField,
              helperText: t.examUrlHelper,
              helperMaxLines: 3,
              isDense: true,
              suffixIcon: IconButton(tooltip: AppLocalizations.of(context).open,
                icon: const Icon(Icons.open_in_new),
                onPressed: _openUrl,
              ),
            ),
          ),
          if (urlFlag) ...[
            const SizedBox(height: Gap.xs),
            _banner(Icons.info_outline, Brand.warning, t.examUrlNotOfficial),
          ],
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(_expected == null
                ? t.examPickDate
                : t.examExpectedOn(df.format(_expected!))),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _expected ?? DateTime.now(),
                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) setState(() => _expected = d);
            },
          ),
          if (_expected != null && phase.state == 'waiting') ...[
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: ExamCountdownChip(expected: _expected!),
            ),
          ],
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.notifications_active_outlined),
              label: Text(_saving ? t.examSaving : t.examWatch),
              onPressed: _saving ? null : _saveWatcher,
            ),
          ),
          const SizedBox(height: Gap.sm),
          _phaseBanner(t, phase),

          const Divider(height: Gap.xl),

          // ---- check on the official site -----------------------------
          _sectionTitle(t.examCheckSection),
          const SizedBox(height: Gap.sm),
          const ExamOfficialCheck(),

          const Divider(height: Gap.xl),

          // ---- multi-student watch ------------------------------------
          _sectionTitle(t.examStudentsSection),
          const SizedBox(height: Gap.xs),
          Text(t.examStudentsNote,
              style: AType.bodySmall.copyWith(color: Colors.grey)),
          const SizedBox(height: Gap.sm),
          ExamStudentWatch(
            students: _students,
            onAdd: () => setState(() => _students.add(ExamStudent())),
            onRemove: (i) => setState(() => _students.removeAt(i)),
            onChanged: (i, l, r) {
              _students[i].label = l;
              _students[i].roll = r;
              setState(() {});
            },
          ),

          const Divider(height: Gap.xl),

          // ---- GPA / grade explainer ----------------------------------
          _sectionTitle(t.examExplainerSection),
          const SizedBox(height: Gap.sm),
          ExamGpaExplainer(enteredGpa: _gpa.text),

          const Divider(height: Gap.xl),

          // ---- shareable result card (user-entered only) --------------
          _sectionTitle(t.examCardSection),
          const SizedBox(height: Gap.xs),
          Text(t.examCardNote,
              style: AType.bodySmall.copyWith(color: Colors.grey)),
          const SizedBox(height: Gap.sm),
          TextField(controller: _name, decoration: InputDecoration(labelText: t.examFieldName, isDense: true)),
          const SizedBox(height: Gap.xs),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _cardRoll,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.examFieldRoll, isDense: true),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: _year,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.examFieldYear, isDense: true),
              ),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _gpa,
                decoration: InputDecoration(labelText: t.examFieldGpa, isDense: true),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: _grade,
                decoration: InputDecoration(labelText: t.examFieldGrade, isDense: true),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          ExamResultCard(
            name: _name.text,
            examCode: _exam ?? '',
            boardCode: _board ?? '',
            year: _year.text,
            roll: _cardRoll.text,
            gpa: _gpa.text,
            grade: _grade.text,
          ),
        ],
      ),
    );
  }

  Widget _phaseBanner(AppLocalizations t, ({String state, int days}) phase) {
    if (phase.state == 'waiting') {
      return _banner(Icons.schedule, Brand.blue, t.examWaiting(phase.days));
    }
    // watching / result day -> traffic-spike note (honest, no fake result)
    return _banner(Icons.warning_amber_rounded, Brand.warning, t.examTrafficSpikeNote);
  }

  Widget _banner(IconData icon, Color color, String msg) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(msg, style: AType.bodyMedium.copyWith(color: color))),
      ]),
    );
  }

  Widget _sectionTitle(String s) =>
      Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold));
}

/// f6: stable local-notification id for a watcher (re-saving overwrites).
String examReminderId(String url, DateTime expected) =>
    'exam-${expected.year}-${expected.month}-${expected.day}-${url.hashCode & 0xffff}';
