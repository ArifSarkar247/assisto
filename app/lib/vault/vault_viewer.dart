// vault100 — in-app document viewer: decrypted bytes stay in MEMORY (no
// plaintext temp file for another app to read), pinch-zoom, screenshots
// blocked (FLAG_SECURE) while open. Non-image files get an honest line and an
// explicit "open with another app" (which does write a temporary copy).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../photo_studio/ps_engines.dart' show ChannelSecureScreen, SecureScreen;
import '../theme.dart' show AType, Gap;

class VaultViewer extends StatefulWidget {
  final Uint8List bytes;
  final String title;
  final bool fromOfflineCopy;
  final SecureScreen secure;
  const VaultViewer(
      {super.key,
      required this.bytes,
      required this.title,
      this.fromOfflineCopy = false,
      this.secure = const ChannelSecureScreen()});

  @override
  State<VaultViewer> createState() => _VaultViewerState();
}

class _VaultViewerState extends State<VaultViewer> {
  @override
  void initState() {
    super.initState();
    widget.secure.enable();
  }

  @override
  void dispose() {
    widget.secure.disable();
    super.dispose();
  }

  Future<void> _openExternally() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/vault_view_${DateTime.now().millisecondsSinceEpoch}');
    await f.writeAsBytes(widget.bytes, flush: true);
    await OpenFilex.open(f.path);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        bottom: widget.fromOfflineCopy
            ? PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.offline_pin_rounded, size: 16),
                    const SizedBox(width: Gap.xs),
                    Text(t.vaultOpenedFromPhone, style: AType.bodySmall),
                  ]),
                ),
              )
            : null,
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.memory(
            widget.bytes,
            semanticLabel: widget.title,
            gaplessPlayback: true,
            errorBuilder: (ctx, _, __) => Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.insert_drive_file_rounded, size: 48),
                const SizedBox(height: Gap.sm),
                Text(t.vaultNoPreview, textAlign: TextAlign.center),
                const SizedBox(height: Gap.md),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: _openExternally,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(t.vaultOpenWithApp),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
