import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'circle_chat_screen.dart';

/// Search ACROSS all circle chats. Because the server stores ciphertext only,
/// search is done ON-DEVICE: we pull each accepted member's messages, decrypt
/// them locally (crypto/e2e.dart), and match the query over the decrypted text.
/// The server never sees the query term matched against content.
///
/// Matching mirrors core/logic/circle_messaging.match_message (token-AND over
/// case-folded text). Deleted messages are skipped.
class CircleSearchScreen extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  final IdentityKeyPair identity;
  const CircleSearchScreen({super.key, required this.members, required this.identity});

  @override
  State<CircleSearchScreen> createState() => _CircleSearchScreenState();
}

class _CircleSearchHit {
  final Map<String, dynamic> member;
  final String text;
  final DateTime at;
  const _CircleSearchHit(this.member, this.text, this.at);
}

class _CircleSearchScreenState extends State<CircleSearchScreen> {
  final _e2e = SoftwareE2E();
  final _index = <_CircleSearchHit>[];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _buildIndex();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  /// Pull + decrypt each accepted member's chat once, into a local index.
  Future<void> _buildIndex() async {
    final me = context.read<AppState>().user?.id;
    for (final member in widget.members) {
      final id = member['id'];
      final peer = _peerPub(member);
      if (peer == null) continue;
      try {
        final r = await _api.getJson('/circle/$id/messages');
        final raw = ((r['results'] ?? r['messages'] ?? []) as List).cast<Map<String, dynamic>>();
        for (final env in raw) {
          if ('${env['deleted'] ?? ''}' == 'everyone') continue;
          if ('${env['content_type'] ?? 'text'}' != 'text') continue;
          final text = _decrypt(env, peer, me);
          if (text == null || text.isEmpty) continue;
          final at = DateTime.tryParse('${env['created_at'] ?? ''}')?.toLocal() ?? DateTime.now();
          _index.add(_CircleSearchHit(member, text, at));
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }

  Uint8List? _peerPub(Map<String, dynamic> member) {
    final b64 = member['public_key'] as String?;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  String? _decrypt(Map<String, dynamic> env, Uint8List peer, int? me) {
    try {
      final ct = Ciphertext(
        scheme: '${env['scheme'] ?? _e2e.scheme}',
        ciphertextB64: '${env['ciphertext'] ?? ''}',
        nonceB64: '${env['nonce'] ?? ''}',
        senderKeyId: '${env['sender_key_id'] ?? ''}',
      );
      return _e2e.decrypt(self: widget.identity, senderPublicKey: peer, ct: ct);
    } catch (_) {
      return null;
    }
  }

  List<_CircleSearchHit> get _results {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final terms = q.split(RegExp(r'\s+'));
    final hits = _index.where((h) {
      final hay = h.text.toLowerCase();
      return terms.every((tk) => hay.contains(tk));
    }).toList();
    hits.sort((a, b) => b.at.compareTo(a.at));
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(hintText: _t.circleSearchAll, border: InputBorder.none),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _query.trim().isEmpty
              ? _hint(scheme)
              : results.isEmpty
                  ? Center(child: Text(_t.circleSearchNoResults, style: TextStyle(color: scheme.onSurfaceVariant)))
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final h = results[i];
                        final name = '${h.member['name'] ?? ''}';
                        return ListTile(
                          leading: CircleAvatar(
                              child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase())),
                          title: Text(name),
                          subtitle: Text(h.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                            builder: (_) => CircleChatScreen(member: h.member, identity: widget.identity),
                          )),
                        );
                      },
                    ),
    );
  }

  Widget _hint(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 48, color: scheme.primary.withValues(alpha: 0.6)),
              const SizedBox(height: Gap.md),
              Text(_t.circleSearchHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ],
          ),
        ),
      );
}
