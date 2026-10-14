import '../l10n/app_localizations.dart';

/// chal_bank.dart — the DAILY CHALLENGE / QUIZ bank + deterministic engine,
/// a VERBATIM mirror of backend/core/logic/daily_challenges.py (#173, §21).
///
/// The bank's STRUCTURE (item ids, category, kind, correct-answer index, option
/// count) lives here as pure data. The bank's TEXT (question / options /
/// explanation, bilingual) is served from AppLocalizations getters keyed by the
/// item id, so this file holds ZERO Bangla literals — every user-facing string
/// resolves through [resolve] against the active locale.
///
/// Determinism: [daily] maps an ISO date to a bank index via the date's
/// proleptic ordinal modulo the bank size (same day => same item, +1 per day,
/// wraps). Scoring, streak and the points summary mirror the backend exactly so
/// the UI is identical offline and reproducible.
///
/// Points are a COUNT only — the referral/points seam redeems them to Premium;
/// this engine never grants a plan or holds money.

class ChalItem {
  final String itemId;
  final String cat; // finance | health | safety | general
  final String kind; // quiz | task
  final String question;
  final List<String> options;
  final int? answer; // correct option index (quiz) / null (task)
  final String explain;
  const ChalItem({
    required this.itemId,
    required this.cat,
    required this.kind,
    required this.question,
    required this.options,
    required this.answer,
    required this.explain,
  });
}

/// Scoring result (mirror of backend score()).
class ChalScore {
  final bool correct;
  final int points;
  final String kind;
  final dynamic answer;
  const ChalScore(this.correct, this.points, this.kind, this.answer);
}

/// Aggregate summary (mirror of backend summarise()).
class ChalSummary {
  final int totalPoints;
  final int totalCompleted;
  final int correctCount;
  final int quizAttempts;
  final int? accuracy;
  final int currentStreak;
  final int longestStreak;
  final bool doneToday;
  const ChalSummary(
      this.totalPoints,
      this.totalCompleted,
      this.correctCount,
      this.quizAttempts,
      this.accuracy,
      this.currentStreak,
      this.longestStreak,
      this.doneToday);
}

// Structural definition of one bank entry (no text — text is localized).
class _Def {
  final String id;
  final String cat;
  final String kind;
  final int optionCount; // 0 for task
  final int? answer;
  const _Def(this.id, this.cat, this.kind, this.optionCount, this.answer);
}

class ChalBank {
  // POINTS POLICY — mirror of backend constants (OWNER REVIEW; holds no money).
  static const int pointsCorrect = 10;
  static const int pointsTry = 2;
  static const int pointsTask = 5;

  static const List<String> categories = [
    'finance',
    'health',
    'safety',
    'general'
  ];

  // ORDER IS LOAD-BEARING: it must match BANK order in daily_challenges.py so
  // the date->index rotation picks the SAME item on both sides.
  static const List<_Def> defs = [
    _Def('fin_emergency_fund', 'finance', 'quiz', 4, 1),
    _Def('fin_interest_compound', 'finance', 'quiz', 4, 1),
    _Def('fin_budget_5030_20', 'finance', 'quiz', 4, 2),
    _Def('fin_inflation', 'finance', 'quiz', 4, 0),
    _Def('fin_save_task', 'finance', 'task', 0, null),
    _Def('health_water', 'health', 'quiz', 4, 1),
    _Def('health_handwash', 'health', 'quiz', 4, 1),
    _Def('health_sleep', 'health', 'quiz', 4, 1),
    _Def('health_salt', 'health', 'quiz', 4, 1),
    _Def('health_walk_task', 'health', 'task', 0, null),
    _Def('safe_password', 'safety', 'quiz', 4, 1),
    _Def('safe_otp', 'safety', 'quiz', 4, 1),
    _Def('safe_2fa', 'safety', 'quiz', 4, 1),
    _Def('safe_link', 'safety', 'quiz', 4, 1),
    _Def('safe_backup_task', 'safety', 'task', 0, null),
    _Def('gen_bd_capital', 'general', 'quiz', 4, 1),
    _Def('gen_language_day', 'general', 'quiz', 4, 0),
    _Def('gen_water_boil', 'general', 'quiz', 4, 1),
    _Def('gen_continents', 'general', 'quiz', 4, 1),
    _Def('gen_learn_task', 'general', 'task', 0, null),
    _Def('fin_scam_invest', 'finance', 'quiz', 4, 1),
  ];

  static final Map<String, _Def> _byId = {for (final d in defs) d.id: d};

  // ------------------------------------------------------------ date math
  static const List<int> _mdays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  static bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);

  static List<int>? _ymd(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    final parts = s.trim().split('-');
    if (parts.length < 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return [y, m, d];
  }

  static int? dateOrdinal(String? s) {
    final ymd = _ymd(s);
    if (ymd == null) return null;
    final y = ymd[0], m = ymd[1], d = ymd[2];
    var days = 0;
    for (var yy = 1; yy < y; yy++) {
      days += _isLeap(yy) ? 366 : 365;
    }
    for (var mm = 1; mm < m; mm++) {
      days += _mdays[mm - 1] + ((mm == 2 && _isLeap(y)) ? 1 : 0);
    }
    return days + d;
  }

  static int? dailyIndex(String? date) {
    if (defs.isEmpty) return null;
    final o = dateOrdinal(date);
    if (o == null) return null;
    return o % defs.length;
  }

  // ------------------------------------------------------------ bank access
  /// The deterministic challenge for [date], localized via [tr]. Null on a bad
  /// date so the caller shows an honest "no challenge" state.
  static ChalItem? daily(AppLocalizations tr, String date, bool isBn) {
    final idx = dailyIndex(date);
    if (idx == null) return null;
    return resolve(tr, defs[idx], isBn);
  }

  static ChalItem? byId(AppLocalizations tr, String itemId, bool isBn) {
    final d = _byId[itemId];
    if (d == null) return null;
    return resolve(tr, d, isBn);
  }

  /// Resolve a structural def into a fully-localized [ChalItem]. All text comes
  /// from AppLocalizations getters keyed `chalBank_<id>_q/_oN/_x`. (isBn is
  /// unused because gen-l10n already returns the active locale's string; it is
  /// accepted for symmetry with the backend signature and future offline use.)
  static ChalItem resolve(AppLocalizations tr, _Def d, bool isBn) {
    return ChalItem(
      itemId: d.id,
      cat: d.cat,
      kind: d.kind,
      question: _q(tr, d.id),
      options: [for (var i = 0; i < d.optionCount; i++) _opt(tr, d.id, i)],
      answer: d.answer,
      explain: _x(tr, d.id),
    );
  }

  // ------------------------------------------------------------ scoring
  static ChalScore score(String itemId, dynamic answer) {
    final d = _byId[itemId];
    if (d == null) return const ChalScore(false, 0, '', null);
    if (d.kind == 'task') {
      final done = answer != null && answer != false && answer != '';
      return ChalScore(done, done ? pointsTask : 0, 'task', answer);
    }
    if (answer == null || answer == '') {
      return const ChalScore(false, 0, 'quiz', null);
    }
    final chosen = answer is int ? answer : int.tryParse(answer.toString());
    if (chosen == null) return ChalScore(false, 0, 'quiz', answer);
    final correct = chosen == d.answer;
    return ChalScore(correct, correct ? pointsCorrect : pointsTry, 'quiz', chosen);
  }

  // ------------------------------------------------------------ streak/summary
  static Set<String> _completedDays(List<Map<String, dynamic>> rows) {
    final days = <String>{};
    for (final r in rows) {
      final d = (r['date'] ?? '').toString();
      if (dateOrdinal(d) == null) continue;
      if (r['answer'] == null) continue;
      days.add(d.trim());
    }
    return days;
  }

  static int streak(List<Map<String, dynamic>> rows, String today) {
    final days = _completedDays(rows);
    final t = dateOrdinal(today);
    if (t == null || days.isEmpty) return 0;
    final ordinals = <int>{};
    for (final d in days) {
      final o = dateOrdinal(d);
      if (o != null) ordinals.add(o);
    }
    int anchor;
    if (ordinals.contains(t)) {
      anchor = t;
    } else if (ordinals.contains(t - 1)) {
      anchor = t - 1;
    } else {
      return 0;
    }
    var run = 0, cur = anchor;
    while (ordinals.contains(cur)) {
      run++;
      cur--;
    }
    return run;
  }

  static int longestStreak(List<Map<String, dynamic>> rows) {
    final set = <int>{};
    for (final d in _completedDays(rows)) {
      final o = dateOrdinal(d);
      if (o != null) set.add(o);
    }
    final ordinals = set.toList()..sort();
    if (ordinals.isEmpty) return 0;
    var best = 1, run = 1;
    for (var i = 1; i < ordinals.length; i++) {
      if (ordinals[i] == ordinals[i - 1] + 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    return best;
  }

  static ChalSummary summarise(List<Map<String, dynamic>> rows, String today) {
    final completed = rows.where((r) => r['answer'] != null).toList();
    var totalPoints = 0;
    for (final r in completed) {
      totalPoints += (r['points'] as num?)?.toInt() ?? 0;
    }
    final quiz = completed.where((r) => (r['kind'] ?? '') == 'quiz').toList();
    final correct = quiz.where((r) => r['correct'] == true).length;
    final int? accuracy =
        quiz.isEmpty ? null : (correct * 100 / quiz.length).round();
    final doneToday = _completedDays(completed).contains(today.trim());
    return ChalSummary(
      totalPoints,
      completed.length,
      correct,
      quiz.length,
      accuracy,
      streak(completed, today),
      longestStreak(completed),
      doneToday,
    );
  }

  // ------------------------------------------------------------ text lookup
  // Each item id maps to getters: question, option 0..3, explanation. Keeping
  // this switch explicit (vs reflection) is deliberate — gen-l10n getters are
  // static, so this is the single localized seam for the bank text.
  static String _q(AppLocalizations tr, String id) {
    switch (id) {
      case 'fin_emergency_fund':
        return tr.chalBankFinEmergencyFundQ;
      case 'fin_interest_compound':
        return tr.chalBankFinInterestCompoundQ;
      case 'fin_budget_5030_20':
        return tr.chalBankFinBudget503020Q;
      case 'fin_inflation':
        return tr.chalBankFinInflationQ;
      case 'fin_save_task':
        return tr.chalBankFinSaveTaskQ;
      case 'health_water':
        return tr.chalBankHealthWaterQ;
      case 'health_handwash':
        return tr.chalBankHealthHandwashQ;
      case 'health_sleep':
        return tr.chalBankHealthSleepQ;
      case 'health_salt':
        return tr.chalBankHealthSaltQ;
      case 'health_walk_task':
        return tr.chalBankHealthWalkTaskQ;
      case 'safe_password':
        return tr.chalBankSafePasswordQ;
      case 'safe_otp':
        return tr.chalBankSafeOtpQ;
      case 'safe_2fa':
        return tr.chalBankSafe2faQ;
      case 'safe_link':
        return tr.chalBankSafeLinkQ;
      case 'safe_backup_task':
        return tr.chalBankSafeBackupTaskQ;
      case 'gen_bd_capital':
        return tr.chalBankGenBdCapitalQ;
      case 'gen_language_day':
        return tr.chalBankGenLanguageDayQ;
      case 'gen_water_boil':
        return tr.chalBankGenWaterBoilQ;
      case 'gen_continents':
        return tr.chalBankGenContinentsQ;
      case 'gen_learn_task':
        return tr.chalBankGenLearnTaskQ;
      case 'fin_scam_invest':
        return tr.chalBankFinScamInvestQ;
    }
    return id;
  }

  static String _x(AppLocalizations tr, String id) {
    switch (id) {
      case 'fin_emergency_fund':
        return tr.chalBankFinEmergencyFundX;
      case 'fin_interest_compound':
        return tr.chalBankFinInterestCompoundX;
      case 'fin_budget_5030_20':
        return tr.chalBankFinBudget503020X;
      case 'fin_inflation':
        return tr.chalBankFinInflationX;
      case 'fin_save_task':
        return tr.chalBankFinSaveTaskX;
      case 'health_water':
        return tr.chalBankHealthWaterX;
      case 'health_handwash':
        return tr.chalBankHealthHandwashX;
      case 'health_sleep':
        return tr.chalBankHealthSleepX;
      case 'health_salt':
        return tr.chalBankHealthSaltX;
      case 'health_walk_task':
        return tr.chalBankHealthWalkTaskX;
      case 'safe_password':
        return tr.chalBankSafePasswordX;
      case 'safe_otp':
        return tr.chalBankSafeOtpX;
      case 'safe_2fa':
        return tr.chalBankSafe2faX;
      case 'safe_link':
        return tr.chalBankSafeLinkX;
      case 'safe_backup_task':
        return tr.chalBankSafeBackupTaskX;
      case 'gen_bd_capital':
        return tr.chalBankGenBdCapitalX;
      case 'gen_language_day':
        return tr.chalBankGenLanguageDayX;
      case 'gen_water_boil':
        return tr.chalBankGenWaterBoilX;
      case 'gen_continents':
        return tr.chalBankGenContinentsX;
      case 'gen_learn_task':
        return tr.chalBankGenLearnTaskX;
      case 'fin_scam_invest':
        return tr.chalBankFinScamInvestX;
    }
    return '';
  }

  static String _opt(AppLocalizations tr, String id, int i) {
    switch ('${id}_$i') {
      case 'fin_emergency_fund_0':
        return tr.chalBankFinEmergencyFundO0;
      case 'fin_emergency_fund_1':
        return tr.chalBankFinEmergencyFundO1;
      case 'fin_emergency_fund_2':
        return tr.chalBankFinEmergencyFundO2;
      case 'fin_emergency_fund_3':
        return tr.chalBankFinEmergencyFundO3;
      case 'fin_interest_compound_0':
        return tr.chalBankFinInterestCompoundO0;
      case 'fin_interest_compound_1':
        return tr.chalBankFinInterestCompoundO1;
      case 'fin_interest_compound_2':
        return tr.chalBankFinInterestCompoundO2;
      case 'fin_interest_compound_3':
        return tr.chalBankFinInterestCompoundO3;
      case 'fin_budget_5030_20_0':
        return tr.chalBankFinBudget503020O0;
      case 'fin_budget_5030_20_1':
        return tr.chalBankFinBudget503020O1;
      case 'fin_budget_5030_20_2':
        return tr.chalBankFinBudget503020O2;
      case 'fin_budget_5030_20_3':
        return tr.chalBankFinBudget503020O3;
      case 'fin_inflation_0':
        return tr.chalBankFinInflationO0;
      case 'fin_inflation_1':
        return tr.chalBankFinInflationO1;
      case 'fin_inflation_2':
        return tr.chalBankFinInflationO2;
      case 'fin_inflation_3':
        return tr.chalBankFinInflationO3;
      case 'health_water_0':
        return tr.chalBankHealthWaterO0;
      case 'health_water_1':
        return tr.chalBankHealthWaterO1;
      case 'health_water_2':
        return tr.chalBankHealthWaterO2;
      case 'health_water_3':
        return tr.chalBankHealthWaterO3;
      case 'health_handwash_0':
        return tr.chalBankHealthHandwashO0;
      case 'health_handwash_1':
        return tr.chalBankHealthHandwashO1;
      case 'health_handwash_2':
        return tr.chalBankHealthHandwashO2;
      case 'health_handwash_3':
        return tr.chalBankHealthHandwashO3;
      case 'health_sleep_0':
        return tr.chalBankHealthSleepO0;
      case 'health_sleep_1':
        return tr.chalBankHealthSleepO1;
      case 'health_sleep_2':
        return tr.chalBankHealthSleepO2;
      case 'health_sleep_3':
        return tr.chalBankHealthSleepO3;
      case 'health_salt_0':
        return tr.chalBankHealthSaltO0;
      case 'health_salt_1':
        return tr.chalBankHealthSaltO1;
      case 'health_salt_2':
        return tr.chalBankHealthSaltO2;
      case 'health_salt_3':
        return tr.chalBankHealthSaltO3;
      case 'safe_password_0':
        return tr.chalBankSafePasswordO0;
      case 'safe_password_1':
        return tr.chalBankSafePasswordO1;
      case 'safe_password_2':
        return tr.chalBankSafePasswordO2;
      case 'safe_password_3':
        return tr.chalBankSafePasswordO3;
      case 'safe_otp_0':
        return tr.chalBankSafeOtpO0;
      case 'safe_otp_1':
        return tr.chalBankSafeOtpO1;
      case 'safe_otp_2':
        return tr.chalBankSafeOtpO2;
      case 'safe_otp_3':
        return tr.chalBankSafeOtpO3;
      case 'safe_2fa_0':
        return tr.chalBankSafe2faO0;
      case 'safe_2fa_1':
        return tr.chalBankSafe2faO1;
      case 'safe_2fa_2':
        return tr.chalBankSafe2faO2;
      case 'safe_2fa_3':
        return tr.chalBankSafe2faO3;
      case 'safe_link_0':
        return tr.chalBankSafeLinkO0;
      case 'safe_link_1':
        return tr.chalBankSafeLinkO1;
      case 'safe_link_2':
        return tr.chalBankSafeLinkO2;
      case 'safe_link_3':
        return tr.chalBankSafeLinkO3;
      case 'gen_bd_capital_0':
        return tr.chalBankGenBdCapitalO0;
      case 'gen_bd_capital_1':
        return tr.chalBankGenBdCapitalO1;
      case 'gen_bd_capital_2':
        return tr.chalBankGenBdCapitalO2;
      case 'gen_bd_capital_3':
        return tr.chalBankGenBdCapitalO3;
      case 'gen_language_day_0':
        return tr.chalBankGenLanguageDayO0;
      case 'gen_language_day_1':
        return tr.chalBankGenLanguageDayO1;
      case 'gen_language_day_2':
        return tr.chalBankGenLanguageDayO2;
      case 'gen_language_day_3':
        return tr.chalBankGenLanguageDayO3;
      case 'gen_water_boil_0':
        return tr.chalBankGenWaterBoilO0;
      case 'gen_water_boil_1':
        return tr.chalBankGenWaterBoilO1;
      case 'gen_water_boil_2':
        return tr.chalBankGenWaterBoilO2;
      case 'gen_water_boil_3':
        return tr.chalBankGenWaterBoilO3;
      case 'gen_continents_0':
        return tr.chalBankGenContinentsO0;
      case 'gen_continents_1':
        return tr.chalBankGenContinentsO1;
      case 'gen_continents_2':
        return tr.chalBankGenContinentsO2;
      case 'gen_continents_3':
        return tr.chalBankGenContinentsO3;
      case 'fin_scam_invest_0':
        return tr.chalBankFinScamInvestO0;
      case 'fin_scam_invest_1':
        return tr.chalBankFinScamInvestO1;
      case 'fin_scam_invest_2':
        return tr.chalBankFinScamInvestO2;
      case 'fin_scam_invest_3':
        return tr.chalBankFinScamInvestO3;
    }
    return '';
  }
}
