import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import 'link_open.dart';
import 'link_preview_client.dart';

/// circlea — links in CHANNEL posts (plaintext, not end-to-end encrypted,
/// moderatable): the preview and the safe-link check come from the SERVER's
/// SSRF-safe fetcher (POST /links/preview | /links/check, context=channel),
/// so a follower's phone never contacts the linked site just by scrolling.
/// Chats never use this file (their URLs never leave the phone).

final Map<String, LinkPreviewData?> _cache = {};

/// Server check for [openLinkSafely] / [LinkifiedText] in a channel post.
Future<Map<String, dynamic>?> channelLinkCheck(BuildContext context, String url) async {
  try {
    final j = await context
        .read<AppState>()
        .api
        .postJson('/links/check', {'url': url, 'context': 'channel'});
    return j;
  } catch (_) {
    return null;
  }
}

class ChannelLinkPreview extends StatefulWidget {
  const ChannelLinkPreview({super.key, required this.url});
  final String url;
  @override
  State<ChannelLinkPreview> createState() => _ChannelLinkPreviewState();
}

class _ChannelLinkPreviewState extends State<ChannelLinkPreview> {
  LinkPreviewData? _data;

  @override
  void initState() {
    super.initState();
    if (_cache.containsKey(widget.url)) {
      _data = _cache[widget.url];
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    LinkPreviewData? d;
    try {
      final j = await context
          .read<AppState>()
          .api
          .postJson('/links/preview', {'url': widget.url, 'context': 'channel'});
      d = LinkPreviewData.fromServer(j);
    } catch (_) {
      d = null;
    }
    _cache[widget.url] = d;
    if (mounted) setState(() => _data = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: () => openLinkSafely(context, widget.url,
            serverCheck: (u) => channelLinkCheck(context, u)),
        child: AbsorbPointer(child: LinkPreviewCard(data: d)),
      ),
    );
  }
}
