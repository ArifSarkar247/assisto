import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

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
  bool _backendReady = true; // false => key-gated backend pending (honest empty)
  bool _loadFailed = false; // true => transient fetch error (offer Retry)
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<Map<String, dynamic>> _items = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final r = await _api.getJson('/circle/groups/${widget.groupId}/media');
      _items = ((r['items'] ?? r['results'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      // A 'backend_ready:false' marker means storage is still key-gated (an
      // honest pending-empty, not an error). Anything else that throws is a
      // real fetch error -> Retry.
      _backendReady = r['backend_ready'] != false;
      _loadFailed = false;
    } catch (e) {
      _loadFailed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Per-item cache/download affordance label. Mirrors
  /// core/logic/circle_media.cache_status: a gated blob shows "available when
  /// storage is on"; a real blob shows "saved on device" / "tap to download".
  String _cacheLabel(Map<String, dynamic> m) {
    if (m['cached_locally'] == true) return _t.grpMediaCached;
    if (m['cache_expired'] == true) return _t.grpMediaDownloadAgain;
    if (_backendReady) return _t.grpMediaDownload;
    return _t.grpMediaGated;
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
          : _loadFailed
              ? _errorRetry(scheme)
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
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                m['cached_locally'] == true
                                    ? Icons.download_done_outlined
                                    : Icons.download_outlined,
                                size: 12,
                                color: scheme.outline,
                              ),
                              const SizedBox(width: Gap.xs),
                              Flexible(
                                child: Text(_cacheLabel(m),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: scheme.outline)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  /// §21 error state for the media grid: honest message + Retry.
  Widget _errorRetry(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: Gap.md),
              Text(honestFailText(_t, _failCause, otherwise: _t.grpMediaLoadFailed),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                onPressed: _load,
                label: Text(_t.grpRetry),
              ),
            ],
          ),
        ),
      );
}
