import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'cctv_grid_screen.dart' show ctmRoleName; // cctvteam
import 'cctv_team_screens.dart'; // cctvteam
import 'cctv_team_source.dart'; // cctvteam
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../../widgets/fam_empty.dart' show famDigits;

/// cctv1 FAMILY VIEWERS: up to 5 family members who get the same alerts and
/// can see snapshots — read-only (no marking, no settings, no live view).
class WatchmanViewersScreen extends StatefulWidget {
  final WatchmanSource source;
  final int siteId;

  /// cctvteam: role per person (family / manager / guard + cameras + live)
  final CctvTeamSource? team;
  const WatchmanViewersScreen({super.key, required this.source, required this.siteId, this.team});

  @override
  State<WatchmanViewersScreen> createState() => _WatchmanViewersScreenState();
}

class _WatchmanViewersScreenState extends State<WatchmanViewersScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];
  final _phone = TextEditingController();
  bool _adding = false;
  String? _addError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _rows = wmList((await widget.source.viewers(widget.siteId))['viewers']);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add([String? phone, String? name]) async {
    final t = AppLocalizations.of(context);
    final number = (phone ?? _phone.text).trim();
    if (number.isEmpty) return;
    setState(() {
      _adding = true;
      _addError = null;
    });
    try {
      await widget.source.addViewer(widget.siteId, number);
      if (phone == null) _phone.clear();
      await _load();
      if (mounted && name != null && name.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.cvvViewerAdded(name))));
      }
    } catch (e) {
      _addError = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _adding = false);
  }

  /// cctvveh: family / manager picked from My Circle in ONE tap (the phone
  /// comes from Circle — nobody types a number twice).
  Future<void> _fromCircle() async {
    final t = AppLocalizations.of(context);
    final row = await pickCirclePerson(context,
        title: t.cvvFromCircle,
        subtitle: t.wmFamilyBody,
        already: {for (final v in _rows) (v['phone'] ?? '').toString()});
    if (row == null || !mounted) return;
    await _add('${row['phone'] ?? ''}', '${row['name'] ?? ''}');
  }

  Future<void> _remove(Map<String, dynamic> v) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.wmRemoveViewerTitle),
        content: Text(t.wmRemoveViewerBody((v['name'] ?? '').toString())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.wmCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.wmRemove)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.source.removeViewer(widget.siteId, (v['user_id'] as num).toInt());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.wmFamily)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)), children: [
              if (_error == null && _rows.isEmpty)
                CvEmptyBlock(
                  compact: true,
                  icon: Icons.family_restroom_rounded,
                  title: t.cvvViewersEmptyTitle,
                  benefit: t.cvvViewersEmptyBenefit,
                  primaryIcon: Icons.group_add_rounded,
                  primaryLabel: t.cvvFromCircle,
                  onPrimary: _adding ? null : _fromCircle,
                  steps: [t.cvvViewersStep1, t.cvvViewersStep2, t.cvvViewersStep3],
                )
              else ...[
                Text(t.wmFamilyBody),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const ValueKey('wm-viewers-circle'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
                  icon: const Icon(Icons.group_add_rounded),
                  label: Text(t.cvvFromCircle),
                  onPressed: _adding ? null : _fromCircle,
                ),
              ],
              const SizedBox(height: 16),
              Text(t.cvvOrTypeNumber, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                    labelText: t.wmFamilyPhone, hintText: '01XXXXXXXXX', border: const OutlineInputBorder()),
              ),
              if (_addError != null) ...[
                const SizedBox(height: 8),
                Text(_addError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _phone,
                builder: (_, v, __) => OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: _adding
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(t.wmFamilyAdd),
                  // disabled until a number is typed (never a dead tap)
                  onPressed: _adding || v.text.trim().isEmpty ? null : _add,
                ),
              ),
              const Divider(height: 28),
              if (_error != null) Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
              if (widget.team != null && _rows.isNotEmpty)
                Text(t.ctmTapToSetRole, style: Theme.of(context).textTheme.bodySmall),
              for (final v in _rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
                  title: Text((v['name'] ?? '').toString().isEmpty ? t.wmFamilyNoName : v['name'].toString()),
                  subtitle: Text([
                    famDigits(context, (v['phone'] ?? '').toString()),
                    if (v['role'] != null) ctmRoleName(t, v['role'].toString()),
                    if (v['role'] == 'guard' || v['all_cameras'] == false)
                      t.ctmCamerasCount(famDigits(context, '${(v['cameras'] as List?)?.length ?? 0}')),
                    if (v['live_ok'] == true) t.ctmLiveOkShort,
                  ].join(' · ')),
                  // cctvteam: tap → what this person may see
                  onTap: widget.team == null
                      ? null
                      : () async {
                          if (await showCctvRoleSheet(context, widget.team!, siteId: widget.siteId, viewer: v)) {
                            await _load();
                          }
                        },
                  trailing: IconButton(
                    tooltip: t.wmRemove,
                    icon: const Icon(Icons.person_remove_alt_1_outlined),
                    onPressed: () => _remove(v),
                  ),
                ),
            ]),
    );
  }
}
