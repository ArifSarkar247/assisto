import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../notifications.dart';
import 'crm_common.dart';

/// Fast "log activity + set next follow-up" sheet for the lead-detail screen.
///
/// The sales-exec's 10-second task after a call/visit: record WHAT HAPPENED and
/// WHEN to follow up next. One-handed flow — tap a type chip, type a one-liner,
/// optionally pick a next-follow-up date, hit save.
///
/// On save it:
///   * logs an Activity via `logAction(leadId, kind, subject, body)`, and
///   * if a date was picked, writes `next_follow_up` on the LEAD via
///     `updateLead` — this is the field that actually drives the CRM Today
///     screen (server `today` reads `lead.next_follow_up`). NOTE: the CRM API's
///     `setNextStep` sets a DEAL's `next_step`/`next_step_due`, NOT the lead's
///     `next_follow_up`, so it would never populate Today — hence `updateLead`.
///
/// Returns true if anything was saved (so the caller refreshes the timeline).
class CrmLogActivitySheet extends StatefulWidget {
  final int leadId;
  final String? currentFollowUp;
  const CrmLogActivitySheet(
      {super.key, required this.leadId, this.currentFollowUp});

  static Future<bool?> show(BuildContext context,
      {required int leadId, String? currentFollowUp}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: CrmLogActivitySheet(
            leadId: leadId, currentFollowUp: currentFollowUp),
      ),
    );
  }

  @override
  State<CrmLogActivitySheet> createState() => _CrmLogActivitySheetState();
}

/// Activity TYPE chips → the `kind` string the backend accepts.
/// Backend Activity.KINDS: call, meeting, task, note, email, whatsapp, stage,
/// system. There is NO "visit" kind, so Visit maps to `meeting` (a visit IS an
/// in-person meeting) rather than silently falling back to `call` server-side.
typedef _ActType = ({String kind, IconData icon, String Function(AppLocalizations) label});

final List<_ActType> _types = [
  (kind: 'call', icon: Icons.call, label: (t) => t.crmCall),
  (kind: 'meeting', icon: Icons.groups_outlined, label: (t) => t.crmMeetingType),
  (kind: 'meeting', icon: Icons.place_outlined, label: (t) => t.crmVisitType),
  (kind: 'note', icon: Icons.sticky_note_2_outlined, label: (t) => t.crmNoteType),
];

class _CrmLogActivitySheetState extends State<CrmLogActivitySheet> {
  int _typeIdx = 0;
  final _note = TextEditingController();
  DateTime? _followUp;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final cur = widget.currentFollowUp;
    if (cur != null && cur.isNotEmpty) {
      _followUp = DateTime.tryParse(cur);
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _followUp ?? now.add(const Duration(days: 1)),
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _followUp = picked);
  }

  /// One-tap relative follow-up preset (e.g. "Tomorrow", "In 3 days"). Sets
  /// `_followUp` to that many days from today at DATE granularity, so it matches
  /// `_fmt` and the server's date-only `next_follow_up`. Renders selected when
  /// the current pick lands on this preset's day; tapping a selected chip again
  /// clears it. Disabled while saving.
  Widget _preset(String label, int days) {
    final target = DateTime.now().add(Duration(days: days));
    final day = DateTime(target.year, target.month, target.day);
    final selected = _followUp != null &&
        _followUp!.year == day.year &&
        _followUp!.month == day.month &&
        _followUp!.day == day.day;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: _saving
          ? null
          : (_) => setState(() => _followUp = selected ? null : day),
    );
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final api = CrmApi.of(context);
      final type = _types[_typeIdx];
      await api.logAction(widget.leadId, type.kind,
          subject: type.label(t), body: _note.text.trim());
      if (_followUp != null) {
        await api.updateLead(
            widget.leadId, {'next_follow_up': _fmt(_followUp!)});
      }
      // Mirror the bill/subscription reminder pattern: schedule a best-effort
      // local notification so the rep is nudged on the follow-up day. Stable id
      // per lead → cancel+reschedule on change; cleared date cancels. Skip past
      // dates (schedule() already no-ops on past times, but guard explicitly).
      // Fully guarded — reminders are best-effort and never block the save.
      try {
        final localId = 'crm-followup-${widget.leadId}';
        await Notifications.cancel(localId);
        if (_followUp != null) {
          final f = _followUp!;
          final when = DateTime(f.year, f.month, f.day, 9);
          if (when.isAfter(DateTime.now())) {
            await Notifications.schedule(
                localId, t.crmNextFollowUp, type.label(t), when);
          }
        }
      } catch (_) {/* best-effort: the follow-up reminder is optional; the activity is saved */}
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.crmActionLogged)));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(CrmError.from(e).textFor(context))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.crmLogActivity,
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          // ---- type chips (one tap) ----
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (int i = 0; i < _types.length; i++)
              ChoiceChip(
                avatar: Icon(_types[i].icon,
                    size: 18,
                    color: _typeIdx == i
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant),
                label: Text(_types[i].label(t)),
                selected: _typeIdx == i,
                onSelected: _saving ? null : (_) => setState(() => _typeIdx = i),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // ---- note ----
          TextField(
            controller: _note,
            enabled: !_saving,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: t.crmWhatHappened,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Gap.md),
          // ---- quick-preset follow-up chips (one tap) ----
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _preset(t.remTomorrow, 1),
            _preset(t.inboxSnooze3d, 3),
            _preset(t.remSnoozeNextWeek, 7),
          ]),
          const SizedBox(height: Gap.sm),
          // ---- optional next follow-up ----
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _pickDate,
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(
                  _followUp == null
                      ? t.crmNextFollowUp
                      : '${t.crmNextFollowUp}: ${_fmt(_followUp!)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (_followUp != null)
              IconButton(
                tooltip: t.close,
                icon: const Icon(Icons.clear, size: 18),
                onPressed: _saving ? null : () => setState(() => _followUp = null),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // ---- save ----
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(t.save),
            ),
          ),
        ]),
      ),
    );
  }
}
