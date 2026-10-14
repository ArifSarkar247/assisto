import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// GROUP MEDIA — the shared-media grid reached from the group ⋮ "Group media".
///
/// Lists the media items shared in this group (photo / video / doc refs). Media
/// blobs are still key-gated (encrypted-blob storage lands later), so each cell
/// renders a typed placeholder with its caption rather than a dead thumbnail —
/// an honest "needs storage key" state, never a dead tap. When the media key
/// is on, the integrator swaps the placeholder for the decrypted thumbnail.
///
/// Backend seam: GET /circle/groups/<id>/media -> {items:[{id, kind, caption}]}.
class GroupMediaScreen extends StatefulWidget {
  final String groupId;
  const GroupMediaScreen({super.key, required this.groupId});

  @override
  State<GroupMediaScreen> createState() => _GroupMediaScreenState();
}

class _GroupMediaScreenState extends State<GroupMediaScreen> {
  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _items = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.getJson('/circle/groups/${widget.groupId}/media');
      _items = ((r['items'] ?? r['results'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _items = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'video':
        return Icons.videocam_outlined;
      case 'doc':
      case 'file':
        return Icons.description_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      default:
        return Icons.image_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t.grpMenuGroupMedia)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Text(
                      _backendReady
                          ? _t.grpMediaEmpty
                          : _t.circleBackendPending,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(Gap.md),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: Gap.sm,
                    crossAxisSpacing: Gap.sm,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final m = _items[i];
                    final kind = '${m['kind'] ?? 'photo'}';
                    final caption = '${m['caption'] ?? ''}';
                    return Container(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius:
                            BorderRadius.circular(Radii.sm),
                      ),
                      padding: const EdgeInsets.all(Gap.sm),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(_iconFor(kind),
                              color: scheme.onSurfaceVariant),
                          if (caption.isNotEmpty) ...[
                            const SizedBox(height: Gap.xs),
                            Text(caption,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: scheme.onSurfaceVariant)),
                          ],
                          const SizedBox(height: Gap.xs),
                          Text(_t.grpMediaGated,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.outline)),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
