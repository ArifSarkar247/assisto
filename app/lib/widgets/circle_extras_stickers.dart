import 'package:flutter/material.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Sticker + GIF picker (M2 item 9).
///
/// STICKERS: we ship ORIGINAL vector sticker packs (NOT copied from any other
/// app). Pack ids + sticker ids mirror core/logic/circle_extras.STICKER_PACKS.
/// The actual vector assets are bundled by the integrator (asset ids resolve to
/// our drawn SVG/vector files); here we render a clean placeholder tile keyed by
/// id so the picker works today and swaps to the real asset when bundled. A
/// sent built-in sticker travels as a tiny {pack_id, sticker_id} ref (no bytes).
/// User-made stickers (cut from the user's OWN photo on-device) are key-gated
/// like other media.
///
/// GIF: Tenor/GIPHY need an OWNER key. With no key we show the clean "available
/// when GIF key added" state and NEVER bundle or proxy provider assets.

class StickerPackData {
  final String id;
  final String Function(AppLocalizations) name;
  final List<String> stickerIds;
  const StickerPackData(this.id, this.name, this.stickerIds);
}

const kStickerPacks = <StickerPackData>[
  StickerPackData('assisto_hearts', _heartsName,
      ['heart_wave', 'heart_grow', 'heart_two', 'heart_spark']),
  StickerPackData('assisto_faces', _facesName,
      ['smile', 'wink', 'cry', 'laugh', 'think', 'sleep']),
  StickerPackData('assisto_bangla', _banglaName,
      ['thik_ache', 'darun', 'dhonnobad', 'valobasha']),
];

String _heartsName(AppLocalizations t) => t.circleExtrasPackHearts;
String _facesName(AppLocalizations t) => t.circleExtrasPackFaces;
String _banglaName(AppLocalizations t) => t.circleExtrasPackBangla;

/// A sent built-in sticker reference (matches circle_extras.build_builtin_sticker_ref).
Map<String, dynamic> builtinStickerRef(String packId, String stickerId) => {
      'kind': 'sticker',
      'source': 'builtin',
      'pack_id': packId,
      'sticker_id': stickerId,
    };

/// Bottom sheet that offers Stickers + GIFs in two tabs.
class StickerGifSheet extends StatefulWidget {
  final bool mediaBytesAvailable; // encrypted media bucket (user stickers)
  final String? gifProviderKey; // owner Tenor/GIPHY key (null => gated)
  final ValueChanged<Map<String, dynamic>> onSticker;
  final ValueChanged<Map<String, dynamic>>? onGif;
  final VoidCallback? onMakeSticker;
  const StickerGifSheet({
    super.key,
    required this.mediaBytesAvailable,
    required this.gifProviderKey,
    required this.onSticker,
    this.onGif,
    this.onMakeSticker,
  });

  @override
  State<StickerGifSheet> createState() => _StickerGifSheetState();
}

class _StickerGifSheetState extends State<StickerGifSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: SizedBox(
        height: 420,
        child: Column(
          children: [
            TabBar(controller: _tabs, tabs: [
              Tab(child: Text(t.circleExtrasStickers, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
              Tab(child: Text(t.circleExtrasGifTitle, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            ]),
            Expanded(
              child: TabBarView(controller: _tabs, children: [
                _stickersTab(t),
                _gifTab(t),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stickersTab(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        for (final pack in kStickerPacks) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(pack.name(t),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final s in pack.stickerIds)
                _StickerTile(
                  packId: pack.id,
                  stickerId: s,
                  onTap: () {
                    widget.onSticker(builtinStickerRef(pack.id, s));
                    Navigator.of(context).maybePop();
                  },
                ),
            ],
          ),
        ],
        const Divider(),
        ListTile(
          leading: const Icon(Icons.auto_fix_high_outlined),
          title: Text(t.circleExtrasMakeSticker),
          enabled: widget.mediaBytesAvailable,
          subtitle: widget.mediaBytesAvailable
              ? null
              : Text(t.circleExtrasStickerGated,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          onTap: widget.mediaBytesAvailable ? widget.onMakeSticker : null,
        ),
      ],
    );
  }

  Widget _gifTab(AppLocalizations t) {
    if (widget.gifProviderKey == null || widget.gifProviderKey!.isEmpty) {
      return _GifGatedState(message: t.circleExtrasGifGated);
    }
    return _GifSearch(
      providerKey: widget.gifProviderKey!,
      onGif: (g) {
        widget.onGif?.call(g);
        Navigator.of(context).maybePop();
      },
    );
  }
}

class _StickerTile extends StatelessWidget {
  final String packId;
  final String stickerId;
  final VoidCallback onTap;
  const _StickerTile(
      {required this.packId, required this.stickerId, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Placeholder tile: the integrator swaps this for the bundled ORIGINAL
    // vector asset `assets/stickers/$packId/$stickerId.svg`.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        alignment: Alignment.center,
        child: Icon(_iconFor(stickerId), color: scheme.primary, size: 30),
      ),
    );
  }

  IconData _iconFor(String id) {
    if (id.startsWith('heart')) return Icons.favorite;
    switch (id) {
      case 'smile':
        return Icons.sentiment_satisfied_alt;
      case 'wink':
        return Icons.sentiment_very_satisfied;
      case 'cry':
        return Icons.sentiment_very_dissatisfied;
      case 'laugh':
        return Icons.emoji_emotions;
      case 'think':
        return Icons.psychology_alt;
      case 'sleep':
        return Icons.bedtime;
      default:
        return Icons.emoji_symbols;
    }
  }
}

class _GifGatedState extends StatelessWidget {
  final String message;
  const _GifGatedState({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gif_box_outlined,
                size: 44, color: scheme.primary.withValues(alpha: 0.6)),
            const SizedBox(height: Gap.md),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

/// With an owner key present, the client issues the search directly to the
/// provider (Tenor/GIPHY) — ONLY the query leaves the device. The actual HTTP
/// call + result model are wired by the integrator behind [onQuery]; here we
/// render the search field + a family-safe note + results grid.
class _GifSearch extends StatefulWidget {
  final String providerKey;
  final ValueChanged<Map<String, dynamic>> onGif;
  const _GifSearch({required this.providerKey, required this.onGif});

  @override
  State<_GifSearch> createState() => _GifSearchState();
}

class _GifSearchState extends State<_GifSearch> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: TextField(
            autofocus: true,
            decoration: InputDecoration(
              hintText: t.circleExtrasGifSearchHint,
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill)),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Row(
            children: [
              Icon(Icons.verified_user_outlined,
                  size: 14, color: scheme.primary),
              const SizedBox(width: Gap.xs),
              Text(t.circleExtrasGifFamilySafe,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(
          child: _q.trim().isEmpty
              ? const SizedBox.shrink()
              // Integrator wires the provider call here (query -> result urls);
              // until then show an empty-results state so the flow is testable.
              : Center(
                  child: Text(t.circleExtrasGifNoResults,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
        ),
      ],
    );
  }
}
