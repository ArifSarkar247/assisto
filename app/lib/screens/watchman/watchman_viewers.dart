import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';

/// cctv1 FAMILY VIEWERS: up to 5 family members who get the same alerts and
/// can see snapshots — read-only (no marking, no settings, no live view).
class WatchmanViewersScreen extends StatefulWidget {
  final WatchmanSource source;
  final int siteId;
  const WatchmanViewersScreen({super.key, required this.source, required this.siteId});

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

  Future<void> _add() async {
    final t = AppLocalizations.of(context);
    if (_phone.text.trim().isEmpty) return;
    setState(() {
      _adding = true;
      _addError = null;
    });
    try {
      await widget.source.addViewer(widget.siteId, _phone.text.trim());
      _phone.clear();
      await _load();
    } catch (e) {
      _addError = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _adding = false);
  }

  Future<void> _remove(Map<String, dynamic> v) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
          : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
              Text(t.wmFamilyBody),
              const SizedBox(height: 12),
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
                builder: (_, v, __) => FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
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
              if (_error == null && _rows.isEmpty) Text(t.wmFamilyEmpty),
              for (final v in _rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
                  title: Text((v['name'] ?? '').toString().isEmpty ? t.wmFamilyNoName : v['name'].toString()),
                  subtitle: Text((v['phone'] ?? '').toString()),
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
