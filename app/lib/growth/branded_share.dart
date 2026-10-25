import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../widgets/wrapped_share.dart';
import 'growth_api.dart';

/// p5-growth: share an AI answer (or another card's text) as an Assisto-
/// branded image + text, optionally with the user's own invite link.
///
/// Privacy: the sheet shows a live PREVIEW of exactly what will be shared —
/// only the text the caller passed (the answer the user tapped share on),
/// never the question, the chat, names or numbers from elsewhere. The invite
/// link is the user's own public code and can be switched off.
///
/// Brand: logo C (white logo on the #007AFF → #10C978 gradient). The card
/// uses fixed colours so the shared image looks the same in light and dark.
const kBrandBlue = Color(0xFF007AFF);
const kBrandGreen = Color(0xFF10C978);
const kBrandInk = Color(0xFF0A1A3D);
const _maxCardChars = 700;

String clipForCard(String s) {
  final t = s.trim();
  if (t.length <= _maxCardChars) return t;
  return '${t.substring(0, _maxCardChars).trimRight()}…';
}

/// The shareable card (fixed 340 logical px wide; captured at 3x).
class BrandedShareCard extends StatelessWidget {
  final String label;
  final String body;
  final String? footer;

  const BrandedShareCard(
      {super.key, required this.label, required this.body, this.footer});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      width: 340,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kBrandBlue, kBrandGreen],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Image.asset('assets/branding/logo.png',
                width: 34, height: 34, filterQuality: FilterQuality.medium),
            const SizedBox(width: 8),
            const Text('Assisto',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(label,
                        style: const TextStyle(
                            color: Color(0xFF0057B8),
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                  ),
                Text(clipForCard(body),
                    style: const TextStyle(
                        color: kBrandInk, fontSize: 15, height: 1.45)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: Text(footer ?? '${t.p5CardFooter} · lifeassisto.com',
                  style: const TextStyle(
                      color: Color(0xFF0057B8),
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Open the share sheet. [label] is the small heading on the card
/// (e.g. "Answer from Assisto AI"); [body] is exactly what gets shared.
Future<void> showBrandedShare(BuildContext context,
    {required String body, String? label, String? subject}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => BrandedShareSheet(body: body, label: label, subject: subject),
  );
}

class BrandedShareSheet extends StatefulWidget {
  final String body;
  final String? label;
  final String? subject;

  /// Test/gallery hook: returns `{code, link}` instead of calling /growth/me.
  final Future<Map<String, dynamic>> Function()? inviteLoader;

  const BrandedShareSheet(
      {super.key,
      required this.body,
      this.label,
      this.subject,
      this.inviteLoader});

  @override
  State<BrandedShareSheet> createState() => _BrandedShareSheetState();
}

class _BrandedShareSheetState extends State<BrandedShareSheet> {
  final _cardKey = GlobalKey();
  String _code = '', _link = '';
  bool _withLink = true, _busy = false;

  @override
  void initState() {
    super.initState();
    _loadInvite();
  }

  Future<void> _loadInvite() async {
    try {
      final f = widget.inviteLoader ??
          () => context.read<AppState>().api.growthMe();
      final r = await f().timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _code = (r['code'] ?? '').toString();
        _link = (r['link'] ?? '').toString();
      });
    } catch (_) {
      // no link (offline / signed out): the card shares without it
    }
  }

  bool get _hasLink => _withLink && _link.isNotEmpty;

  String _caption(AppLocalizations t, {required bool full}) {
    final parts = <String>[];
    if (full) parts.add(widget.body.trim());
    if (_hasLink) {
      parts.add('${t.p5CardInviteLine(_code)}\n$_link');
    } else {
      parts.add('Assisto · lifeassisto.com');
    }
    return parts.join('\n\n');
  }

  Future<void> _shareImage(AppLocalizations t) async {
    setState(() => _busy = true);
    try {
      final f = await WrappedShare.captureToFile(_cardKey,
          fileName: 'assisto_share.png');
      if (f == null) {
        await Share.share(_caption(t, full: true), subject: widget.subject);
      } else {
        await Share.shareXFiles([XFile(f.path)],
            text: _caption(t, full: false), subject: widget.subject);
      }
    } catch (_) {
      _fail(t);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _shareText(AppLocalizations t) async {
    try {
      await Share.share(_caption(t, full: true), subject: widget.subject);
    } catch (_) {
      _fail(t);
    }
  }

  void _fail(AppLocalizations t) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(t.p5ShareFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final footer = _hasLink
        ? '${t.p5CardFooter} · ${_link.replaceFirst(RegExp(r'^https?://'), '')}'
        : null;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.p5ShareTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: RepaintBoundary(
                  key: _cardKey,
                  child: BrandedShareCard(
                      label: widget.label ?? t.p5CardAiAnswer,
                      body: widget.body,
                      footer: footer),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(t.p5SharePreviewNote,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            if (_link.isNotEmpty)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _withLink,
                onChanged: (v) => setState(() => _withLink = v),
                title: Text(t.p5ShareIncludeLink),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : () => _shareImage(t),
              icon: const Icon(Icons.image_rounded),
              label: Text(t.p5ShareImage),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _shareText(t),
              icon: const Icon(Icons.notes_rounded),
              label: Text(t.p5ShareText),
            ),
          ],
        ),
      ),
    );
  }
}
