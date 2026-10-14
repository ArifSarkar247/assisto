import 'dart:convert';
import '../state.dart';

/// Job Hunter ADVANCED — local, offline-first store + shared constants
/// (feature 37, SPEC v2.1 §21). Mirrors the deterministic backend FSM in
/// backend/core/logic/job_hunter.py. Bookmarks, per-job notes, interview-prep
/// ticks, company notes and reminder-dismissals live locally (SharedPreferences
/// via [Settings]) so Saved/Tracker stay usable OFFLINE — the server only owns
/// the JobApplication rows (title/company/jd/status/applied_at/followup_at).
///
/// NEVER scrapes. Discovery ships a small CURATED SAMPLE with an honest
/// "connect a source" state until an official job-source API / owner feed key
/// is configured server-side.

/// Pipeline stages — keep in lock-step with job_hunter.PIPELINE / TERMINAL.
const kStageMatched = 'matched';
const kStageSaved = 'saved';
const kStageApplied = 'applied';
const kStageInterview = 'interview';
const kStageOffer = 'offer';
const kStageRejected = 'rejected';
const kStageWithdrawn = 'withdrawn';

/// Ordered display spine (terminal stages excluded), mirroring PIPELINE.
const kPipeline = [kStageMatched, kStageSaved, kStageApplied, kStageInterview, kStageOffer];
const kTerminal = {kStageOffer, kStageRejected, kStageWithdrawn};

/// Legal transitions (mirror of job_hunter._TRANSITIONS). Used to show only the
/// moves the server will accept, so the tracker never offers an impossible one.
const Map<String, List<String>> kTransitions = {
  kStageMatched: [kStageSaved, kStageApplied, kStageRejected, kStageWithdrawn],
  kStageSaved: [kStageApplied, kStageMatched, kStageRejected, kStageWithdrawn],
  kStageApplied: [kStageInterview, kStageRejected, kStageWithdrawn],
  kStageInterview: [kStageOffer, kStageRejected, kStageWithdrawn],
  kStageOffer: [],
  kStageRejected: [],
  kStageWithdrawn: [],
};

List<String> nextStages(String from) => kTransitions[from] ?? const [];

int pipelineIndex(String status) {
  if (status == kStageRejected || status == kStageWithdrawn) return -1;
  final i = kPipeline.indexOf(status);
  return i < 0 ? 0 : i;
}

/// Filter enumerations (stable keys; labels localised in the UI via ARB).
const kCategories = ['it', 'accounts', 'sales', 'ngo', 'garments', 'education',
    'engineering', 'health', 'gov', 'other'];
const kJobTypes = ['full_time', 'part_time', 'contract', 'remote', 'internship'];
const kExperience = ['entry', 'mid', 'senior'];

/// A discovery filter set. Empty strings / nulls mean the filter is off.
class JobFilter {
  String query, category, location, jobType, experience;
  int? minSalary, maxSalary;
  JobFilter({this.query = '', this.category = '', this.location = '',
      this.jobType = '', this.experience = '', this.minSalary, this.maxSalary});

  bool get isActive =>
      category.isNotEmpty || location.isNotEmpty || jobType.isNotEmpty ||
      experience.isNotEmpty || minSalary != null || maxSalary != null;

  int get activeCount => [
        category.isNotEmpty, location.isNotEmpty, jobType.isNotEmpty,
        experience.isNotEmpty, minSalary != null || maxSalary != null,
      ].where((e) => e).length;

  /// Mirror of job_hunter.matches_filters — a job with NO stated salary is
  /// never hidden by a salary filter (we don't invent numbers).
  bool matches(Map<String, dynamic> job) {
    if (query.trim().isNotEmpty) {
      final hay = ['title', 'company', 'jd', 'location', 'category']
          .map((k) => (job[k] ?? '').toString())
          .join(' ')
          .toLowerCase();
      if (!hay.contains(query.trim().toLowerCase())) return false;
    }
    if (category.isNotEmpty && job['category'] != category) return false;
    if (location.isNotEmpty &&
        !(job['location'] ?? '').toString().toLowerCase().contains(location.toLowerCase())) {
      return false;
    }
    if (jobType.isNotEmpty && job['job_type'] != jobType) return false;
    if (experience.isNotEmpty && job['experience'] != experience) return false;
    final sal = job['salary'];
    if (sal is num) {
      if (minSalary != null && sal < minSalary!) return false;
      if (maxSalary != null && sal > maxSalary!) return false;
    }
    return true;
  }
}

/// Deterministic salary insight over a set — SOURCE-NOTED, never invented.
/// Returns null when no job in the set states a salary (honest "no data").
Map<String, dynamic>? salaryInsight(List<Map<String, dynamic>> jobs, {String category = ''}) {
  final vals = jobs
      .where((j) => (category.isEmpty || j['category'] == category) && j['salary'] is num)
      .map((j) => (j['salary'] as num).toInt())
      .toList()
    ..sort();
  if (vals.isEmpty) return null;
  return {'count': vals.length, 'min': vals.first, 'max': vals.last,
      'median': vals[vals.length ~/ 2]};
}

/// Local-only persistence (offline-capable). All keys are namespaced so they
/// never collide with other modules and carry no sensitive data.
class JobsLocal {
  static const _savedKey = 'jobs.saved.ids';          // bookmarked job ids (sample+server)
  static String _noteKey(int id) => 'jobs.note.$id';
  static String _companyNoteKey(String c) => 'jobs.cnote.${c.toLowerCase().trim()}';
  static String _prepKey(int id) => 'jobs.prep.$id';   // ticked checklist item ids
  static String _dismissKey(int id) => 'jobs.remdismiss.$id';

  static Future<Set<String>> savedIds() async {
    final raw = await Settings.getString(_savedKey);
    if (raw == null || raw.isEmpty) return {};
    return (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
  }

  static Future<void> toggleSaved(String id) async {
    final s = await savedIds();
    s.contains(id) ? s.remove(id) : s.add(id);
    await Settings.setString(_savedKey, jsonEncode(s.toList()));
  }

  static Future<bool> isSaved(String id) async => (await savedIds()).contains(id);

  static Future<String> note(int id) async => (await Settings.getString(_noteKey(id))) ?? '';
  static Future<void> setNote(int id, String v) => Settings.setString(_noteKey(id), v);

  static Future<String> companyNote(String c) async =>
      (await Settings.getString(_companyNoteKey(c))) ?? '';
  static Future<void> setCompanyNote(String c, String v) =>
      Settings.setString(_companyNoteKey(c), v);

  static Future<Set<int>> prepTicks(int id) async {
    final raw = await Settings.getString(_prepKey(id));
    if (raw == null || raw.isEmpty) return {};
    return (jsonDecode(raw) as List).map((e) => e as int).toSet();
  }

  static Future<void> setPrepTicks(int id, Set<int> ticks) =>
      Settings.setString(_prepKey(id), jsonEncode(ticks.toList()));

  static Future<bool> reminderDismissed(int id) async =>
      await Settings.getBool(_dismissKey(id), false);
  static Future<void> dismissReminder(int id) => Settings.setBool(_dismissKey(id), true);
}

/// Deterministic interview-prep checklist — mirrors job_hunter.interview_checklist.
/// Text comes from ARB (bilingual); here we only define the stable id/key order.
const kPrepKeys = [
  'jobsPrepResearch', 'jobsPrepMapSkills', 'jobsPrepPractise',
  'jobsPrepQuestions', 'jobsPrepLogistics', 'jobsPrepDocs', 'jobsPrepThankYou',
];

/// CURATED SAMPLE discovery feed — shown until a real source is connected.
/// NOT scraped from anyone; representative BD roles so the UI is explorable.
/// Each carries a source string so salary insight can be honestly attributed.
const kSampleSource = 'Assisto sample';
const List<Map<String, dynamic>> kSampleJobs = [
  {'id': -1, 'title': 'Junior Software Engineer', 'company': 'Brain Station 23',
    'category': 'it', 'location': 'Dhaka', 'salary': 45000, 'job_type': 'full_time',
    'experience': 'entry', 'jd': 'React, Node.js, REST APIs, Git.'},
  {'id': -2, 'title': 'Accounts Officer', 'company': 'Square Group',
    'category': 'accounts', 'location': 'Dhaka', 'salary': 35000, 'job_type': 'full_time',
    'experience': 'mid', 'jd': 'Tally, VAT, ledger, reconciliation.'},
  {'id': -3, 'title': 'Field Sales Executive', 'company': 'Pran-RFL',
    'category': 'sales', 'location': 'Chattogram', 'salary': 28000, 'job_type': 'full_time',
    'experience': 'entry', 'jd': 'Distribution, retail sales, target.'},
  {'id': -4, 'title': 'Programme Officer', 'company': 'BRAC',
    'category': 'ngo', 'location': 'Khulna', 'salary': 52000, 'job_type': 'contract',
    'experience': 'mid', 'jd': 'Monitoring, reporting, community mobilisation.'},
  {'id': -5, 'title': 'Remote Flutter Developer', 'company': 'Kaz Software',
    'category': 'it', 'location': 'Remote', 'salary': 70000, 'job_type': 'remote',
    'experience': 'senior', 'jd': 'Flutter, Dart, state management, CI.'},
  {'id': -6, 'title': 'Production Supervisor', 'company': 'Ha-Meem Group',
    'category': 'garments', 'location': 'Gazipur', 'salary': 30000, 'job_type': 'full_time',
    'experience': 'mid', 'jd': 'Line balancing, quality, team handling.'},
];
