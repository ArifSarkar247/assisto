import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';

/// Legal viewer (launch gap C). In-app reader for the privacy policy, terms,
/// health disclaimer and Play data-safety summary. Every page is a DRAFT and
/// carries the owner-review stamp the backend returns.
class LegalScreen extends StatefulWidget {
  const LegalScreen({super.key});
  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  List<Map<String, dynamic>> _index = [];
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _index = await context.read<AppState>().api.legalIndex();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.legalTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off, size: 40),
                  const SizedBox(height: 8),
                  Text(t.legalOffline),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                      onPressed: _load, child: Text(t.retry)),
                ]))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final p in _index)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(p['title'] ?? ''),
                          subtitle: Text(p['stamp'] ?? '',
                              style: const TextStyle(fontSize: 12)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  _LegalPage(pageKey: p['key'] as String),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _LegalPage extends StatefulWidget {
  final String pageKey;
  const _LegalPage({required this.pageKey});
  @override
  State<_LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<_LegalPage> {
  Map<String, dynamic>? _page;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _page = await context.read<AppState>().api.legalPage(widget.pageKey);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_page?['title'] ?? t.legalTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off, size: 40),
                  const SizedBox(height: 8),
                  Text(t.legalOffline),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                      onPressed: _load, child: Text(t.retry)),
                ]))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(children: [
                        Icon(Icons.warning_amber_rounded,
                            color: scheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_page?['stamp'] ?? '',
                              style: TextStyle(
                                  color: scheme.onErrorContainer,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    if (_page?['last_updated'] != null)
                      Text(
                        '${t.legalLastUpdated}: ${_page!['last_updated']}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    const SizedBox(height: 12),
                    Text(_page?['body'] ?? '',
                        style: const TextStyle(fontSize: 14, height: 1.5)),
                  ],
                ),
    );
  }
}
