import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../call_avatar.dart';
import 'group_call.dart';

/// callsB: "Add person" during a call — my ACCEPTED My Circle contacts who
/// are not in the call yet. Tapping one rings them with the normal incoming
/// call (the server enforces the 4-person cap, contacts-only and the rate
/// limit; this sheet shows its answer honestly).
class AddPersonSheet extends StatefulWidget {
  const AddPersonSheet({
    super.key,
    required this.loadContacts,
    required this.onAdd,
    required this.inCallMemberIds,
    required this.seatsLeft,
  });

  /// GET /circle/members (accepted contacts only).
  final Future<List<Map<String, dynamic>>> Function() loadContacts;
  final Future<AddPersonResult> Function(int memberId) onAdd;

  /// My Circle ids of the people already ringing / in the call.
  final Set<int> inCallMemberIds;
  final int seatsLeft;

  static Future<void> show(BuildContext context,
      {required Future<List<Map<String, dynamic>>> Function() loadContacts,
      required GroupCallSessionLike session}) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.75,
        child: AddPersonSheet(
          loadContacts: loadContacts,
          onAdd: session.addPerson,
          inCallMemberIds: session.inCallMemberIds,
          seatsLeft: session.seatsLeft,
        ),
      ),
    );
  }

  @override
  State<AddPersonSheet> createState() => _AddPersonSheetState();
}

String addResultText(AppLocalizations t, AddPersonResult r) => switch (r) {
      AddPersonResult.ok => '',
      AddPersonResult.full => t.cgAddFull,
      AddPersonResult.notContact => t.cgAddNotContact,
      AddPersonResult.alreadyIn => t.cgAddAlreadyIn,
      AddPersonResult.rateLimited => t.cgAddRateLimited,
      AddPersonResult.blocked => t.cgAddBlocked,
      AddPersonResult.upgrade => t.cgAddUpgrade,
      AddPersonResult.ended => t.cgAddEnded,
      AddPersonResult.failed => t.cgAddFailed,
    };

class _AddPersonSheetState extends State<AddPersonSheet> {
  List<Map<String, dynamic>>? _contacts;
  bool _failed = false;
  int? _busy;
  final Set<int> _rung = {};
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _failed = false;
      _contacts = null;
    });
    try {
      final list = await widget.loadContacts();
      if (!mounted) return;
      setState(() => _contacts = list
          .where((m) => '${m['state'] ?? 'accepted'}' == 'accepted')
          .toList());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  int get _seats => widget.seatsLeft - _rung.length;

  Future<void> _add(Map<String, dynamic> m) async {
    final id = (m['id'] as num?)?.toInt();
    if (id == null || _busy != null) return;
    setState(() {
      _busy = id;
      _message = '';
    });
    final r = await widget.onAdd(id);
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = null;
      if (r == AddPersonResult.ok) {
        _rung.add(id);
        _message = t.cgAddPersonRinging(_name(m));
      } else {
        _message = addResultText(t, r);
      }
    });
  }

  String _name(Map<String, dynamic> m) {
    final nick = '${m['nickname'] ?? ''}'.trim();
    return nick.isNotEmpty ? nick : '${m['name'] ?? m['display_name'] ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final list = (_contacts ?? const <Map<String, dynamic>>[])
        .where((m) => !widget.inCallMemberIds.contains((m['id'] as num?)?.toInt()))
        .toList();
    return SafeArea(
      child: Column(
        key: const Key('add-person-sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
            child: Text(t.cgAddPersonTitle,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Text(t.cgAddPersonHint,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
              child: Semantics(
                liveRegion: true,
                child: Text(_message,
                    key: const Key('add-person-message'),
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
          Expanded(
            child: _failed
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t.cgAddFailed, textAlign: TextAlign.center),
                      const SizedBox(height: Gap.sm),
                      OutlinedButton(onPressed: _load, child: Text(t.retry)),
                    ]),
                  )
                : _contacts == null
                    ? const Center(child: CircularProgressIndicator())
                    : list.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(Gap.xl),
                              child: Text(t.cgAddPersonNone,
                                  textAlign: TextAlign.center),
                            ),
                          )
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) {
                              final m = list[i];
                              final id = (m['id'] as num?)?.toInt() ?? -1;
                              final rung = _rung.contains(id);
                              final full = _seats <= 0 && !rung;
                              return ListTile(
                                key: Key('add-person-$id'),
                                minTileHeight: 56,
                                leading: CallAvatar(
                                    name: _name(m),
                                    photoUrl: '${m['photo'] ?? ''}',
                                    version: '${m['photo_v'] ?? ''}',
                                    radius: 20,
                                    onDark: false),
                                title: Text(_name(m),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: rung ? Text(t.cgRinging) : null,
                                trailing: _busy == id
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : FilledButton.tonal(
                                        key: Key('add-person-btn-$id'),
                                        style: FilledButton.styleFrom(
                                            minimumSize: const Size(64, 48)),
                                        onPressed: rung || full || _busy != null
                                            ? null
                                            : () => _add(m),
                                        child: Text(t.cgAdd),
                                      ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
