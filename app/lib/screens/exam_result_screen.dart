import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Exam-result day (module-5 "Life").
///
///   - A WATCHER for a user-provided PUBLIC result URL and/or expected date.
///     We never scrape behind auth; the backend polls only the public page the
///     user pasted. On result day we show a traffic-spike note instead of
///     faking a result (results sites get hammered).
///   - A shareable result CARD built ONLY from values the user enters.
///
/// Mirrors core.logic.exam.
class ExamResultScreen extends StatefulWidget {
  const ExamResultScreen({super.key});
  @override
  State<ExamResultScreen> createState() => _ExamResultScreenState();
}

class _ExamResultScreenState extends State<ExamResultScreen> {
  final _label = TextEditingController();
  final _url = TextEditingController();
  DateTime? _expected;

  // result card fields (user-entered only)
  final _name = TextEditingController();
  final _roll = TextEditingController();
  final _board = TextEditingController();
  final _gpa = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    _name.dispose();
    _roll.dispose();
    _board.dispose();
    _gpa.dispose();
    super.dispose();
  }

  // Mirror exam.watcher_phase.
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
    try {
      await context.read<AppState>().api.postJson('/exam/watcher', {
        'label': _label.text.trim(),
        'url': url,
        'expected_date': _expected?.toIso8601String(),
        'roll': _roll.text.trim(),
        'board': _board.text.trim(),
      });
      messenger.showSnackBar(SnackBar(content: Text(t.examWatcherSaved)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.examWatcherSavedLocal)));
    }
  }

  Future<void> _openUrl() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // Mirror exam.result_card (English rendering; server builds the locale copy).
  String _buildCard() {
    final t = AppLocalizations.of(context);
    final lines = <String>[];
    final header = _label.text.trim().isEmpty ? t.examCardDefaultHeader : _label.text.trim();
    lines.add(header);
    if (_name.text.trim().isNotEmpty) lines.add('${t.examFieldName}: ${_name.text.trim()}');
    if (_roll.text.trim().isNotEmpty) lines.add('${t.examFieldRoll}: ${_roll.text.trim()}');
    if (_board.text.trim().isNotEmpty) lines.add('${t.examFieldBoard}: ${_board.text.trim()}');
    if (_gpa.text.trim().isNotEmpty) lines.add('${t.examFieldGpa}: ${_gpa.text.trim()}');
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final phase = _phase();
    final df = DateFormat('d MMM yyyy');
    return Scaffold(
      appBar: AppBar(title: Text(t.examTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          // watcher setup
          _sectionTitle(t.examWatcherSection),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _label,
            decoration: InputDecoration(labelText: t.examLabelField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: t.examUrlField,
              helperText: t.examUrlHelper,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.open_in_new),
                onPressed: _openUrl,
              ),
            ),
          ),
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
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(t.examWatch),
              onPressed: _saveWatcher,
            ),
          ),
          const SizedBox(height: Gap.sm),
          _phaseBanner(t, phase),

          const Divider(height: Gap.xl),

          // result card
          _sectionTitle(t.examCardSection),
          const SizedBox(height: Gap.xs),
          Text(t.examCardNote, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: Gap.sm),
          TextField(controller: _name, decoration: InputDecoration(labelText: t.examFieldName, isDense: true)),
          const SizedBox(height: Gap.xs),
          TextField(controller: _roll, decoration: InputDecoration(labelText: t.examFieldRoll, isDense: true)),
          const SizedBox(height: Gap.xs),
          TextField(controller: _board, decoration: InputDecoration(labelText: t.examFieldBoard, isDense: true)),
          const SizedBox(height: Gap.xs),
          TextField(controller: _gpa, decoration: InputDecoration(labelText: t.examFieldGpa, isDense: true)),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.share, size: 16),
              label: Text(t.examShareCard),
              onPressed: () {
                final text = _buildCard();
                Share.share(text);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _phaseBanner(AppLocalizations t, ({String state, int days}) phase) {
    if (phase.state == 'waiting') {
      return _banner(Icons.schedule, Brand.blue,
          t.examWaiting(phase.days));
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
        Expanded(child: Text(msg, style: TextStyle(color: color, fontSize: 13))),
      ]),
    );
  }

  Widget _sectionTitle(String s) =>
      Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15));
}
