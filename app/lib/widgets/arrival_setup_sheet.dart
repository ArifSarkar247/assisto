import '../l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'arrival_model.dart';

/// Result of the safe-arrival setup sheet.
class ArrivalSetupResult {
  final String? place;
  final DateTime eta;
  final List<int> alertIds; // circle/emergency contact ids to alert on miss
  final bool nightMode;
  const ArrivalSetupResult({
    required this.place,
    required this.eta,
    required this.alertIds,
    required this.nightMode,
  });
}

/// ADVANCED setup sheet: destination (optional) + expected-arrival TIME +
/// WHO-TO-ALERT (multi-select from the user's existing circle/emergency
/// contacts — REUSE, no new audience) + night-safety toggle.
///
/// [contacts] is the list the screen already fetched from getEmergency();
/// each item is {id?/name/relation/phone}. Selecting nobody is allowed (the
/// family poll still surfaces an overdue check-in to every circle member).
class ArrivalSetupSheet extends StatefulWidget {
  final String? place;
  final DateTime? eta;
  final List<Map<String, dynamic>> contacts;
  final Set<int> selectedIds;
  final bool nightMode;

  const ArrivalSetupSheet({
    super.key,
    required this.place,
    required this.eta,
    required this.contacts,
    required this.selectedIds,
    required this.nightMode,
  });

  @override
  State<ArrivalSetupSheet> createState() => _ArrivalSetupSheetState();
}

class _ArrivalSetupSheetState extends State<ArrivalSetupSheet> {
  late final TextEditingController _place =
      TextEditingController(text: widget.place ?? '');
  late TimeOfDay _time =
      widget.eta != null ? TimeOfDay.fromDateTime(widget.eta!) : TimeOfDay.now();
  late final Set<int> _selected = {...widget.selectedIds};
  late bool _night = widget.nightMode;

  int? _idOf(Map<String, dynamic> c, int i) =>
      (c['id'] as num?)?.toInt() ?? i; // fall back to index if no id

  @override
  void dispose() {
    _place.dispose();
    super.dispose();
  }

  void _submit() {
    final now = DateTime.now();
    var eta = DateTime(now.year, now.month, now.day, _time.hour, _time.minute);
    if (eta.isBefore(now)) eta = eta.add(const Duration(days: 1));
    Navigator.pop(
      context,
      ArrivalSetupResult(
        place: _place.text.trim().isEmpty ? null : _place.text.trim(),
        eta: eta,
        alertIds: _selected.toList(),
        nightMode: _night,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.contacts;
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppLocalizations.of(context).aSetButton,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _place,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).aDestinationLabel,
              prefixIcon: const Icon(Icons.place_rounded),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule_rounded),
            label: Text('${AppLocalizations.of(context).aByTime}: ${_time.format(context)}'),
            onPressed: () async {
              final picked = await showTimePicker(context: context, initialTime: _time);
              if (picked != null) setState(() => _time = picked);
            },
          ),
          const Divider(height: 24),
          Text(AppLocalizations.of(context).aWhoToAlert,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(AppLocalizations.of(context).aWhoDesc,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 6),
          if (contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(AppLocalizations.of(context).aNoContacts,
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            )
          else
            ...List.generate(contacts.length, (i) {
              final c = contacts[i];
              final id = _idOf(c, i)!;
              final name = (c['name'] ?? '').toString().trim();
              final rel = (c['relation'] ?? '').toString().trim();
              final label = name.isEmpty ? (c['phone'] ?? '').toString() : name;
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(id),
                title: Text(label),
                subtitle: rel.isEmpty ? null : Text(rel),
                onChanged: (v) => setState(() =>
                    v == true ? _selected.add(id) : _selected.remove(id)),
              );
            }),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.nightlight_round_rounded),
            title: Text(AppLocalizations.of(context).aNightSafety),
            subtitle: Text(AppLocalizations.of(context).aNightSafetyDesc,
                style: const TextStyle(fontSize: 12)),
            value: _night,
            onChanged: (v) => setState(() => _night = v),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context).aCancel),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: _submit,
                child: Text(AppLocalizations.of(context).aSave),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
