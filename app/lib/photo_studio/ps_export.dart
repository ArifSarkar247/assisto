import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'ps_ads.dart';
import 'ps_backend.dart';
import 'ps_models.dart';
import 'ps_session.dart';

// =========================================================================
// THE export gate — every way an image leaves Photo Studio goes through here.
// =========================================================================
enum GateStatus {
  unlocked,
  cancelled,

  /// The rewarded ad did not load / was closed early. Never a bypass: the
  /// user may retry or use credits.
  adUnavailable,
  insufficient,
  failed,
}

/// What a free user still owes for a job.
class GateNeed {
  const GateNeed(
      {required this.adsRemaining,
      required this.adsTotal,
      this.credits,
      this.lastAdFailed = false,
      this.adsLinked = true});
  final int adsRemaining;
  final int adsTotal;
  final int? credits;
  final bool lastAdFailed;
  final bool adsLinked;
}

enum FundChoice { ads, credits }

/// UI callbacks the gate needs (the sheet in the screen; fakes in tests).
abstract class GateUi {
  /// How to pay. null = the user cancelled.
  Future<FundChoice?> chooseFunding(GateNeed need);

  /// Progress while an ad is verified by the server.
  void verifying(int done, int total) {}
}

class GateGrant {
  const GateGrant(
      {required this.token,
      required this.cornerMark,
      this.resultUrl = '',
      this.aiNote = ''});
  final String token;
  final bool cornerMark;
  final String resultUrl;
  final String aiNote;
}

class GateResult {
  const GateResult(this.status, {this.grant, this.job, this.message = ''});
  final GateStatus status;
  final GateGrant? grant;
  final PsJob? job;
  final String message;
  bool get ok => status == GateStatus.unlocked;
}

class ExportGate {
  ExportGate({
    required this.backend,
    required this.ads,
    this.rewardedUnit = '',
    this.creditsPrice,
    this.pollEvery = const Duration(milliseconds: 800),
    this.pollTries = 12,
  });

  final PsBackend backend;
  final PhotoAdBridge ads;
  final String rewardedUnit;
  final int? creditsPrice;
  final Duration pollEvery;
  final int pollTries;

  /// Make sure [job] is funded (ads SSV-verified or credits taken). Used both
  /// before a cloud run and before an export.
  Future<GateResult> ensureFunded(PsJob job, GateUi ui) async {
    var j = job;
    var lastFailed = false;
    while (!j.funded) {
      final choice = await ui.chooseFunding(GateNeed(
          adsRemaining: j.adsRemaining,
          adsTotal: j.adsRequired,
          credits: creditsPrice,
          lastAdFailed: lastFailed,
          adsLinked: ads.linked));
      if (choice == null) return GateResult(GateStatus.cancelled, job: j);
      if (choice == FundChoice.credits) {
        final r = await backend.fundWithCredits(j.id);
        if (r.ok && r.job != null) {
          j = r.job!;
          continue;
        }
        return GateResult(
            r.status == 402 ? GateStatus.insufficient : GateStatus.failed,
            job: j,
            message: r.message);
      }
      // one rewarded ad, verified ONLY by the server's SSV callback
      final t = await backend.ticket(j.id);
      if (!t.ok) {
        final fresh = await backend.job(j.id);
        if (fresh.job != null) j = fresh.job!;
        if (j.funded) break;
        return GateResult(GateStatus.failed, job: j, message: t.message);
      }
      final unit = '${t.body['rewarded_unit'] ?? ''}'.isNotEmpty
          ? '${t.body['rewarded_unit']}'
          : rewardedUnit;
      final outcome = await ads.showRewardedSsv(unit,
          userId: '${t.body['user_id'] ?? ''}',
          customData: '${t.body['custom_data'] ?? ''}');
      if (outcome != RewardOutcome.earned) {
        lastFailed = true;
        continue; // ask again: retry or credits — never a free unlock
      }
      lastFailed = false;
      final before = j.adsVerified;
      ui.verifying(before, j.adsRequired);
      for (var i = 0; i < pollTries; i++) {
        final r = await backend.job(j.id);
        if (r.job != null) j = r.job!;
        if (j.adsVerified > before || j.funded) break;
        await Future<void>.delayed(pollEvery);
      }
      ui.verifying(j.adsVerified, j.adsRequired);
    }
    return GateResult(GateStatus.unlocked, job: j);
  }

  /// Unlock one export of [job] as [kind].
  Future<GateResult> unlock(PsJob job, ExportKind kind, GateUi ui) async {
    var r = await backend.unlock(job.id, kind);
    if (r.status == 402) {
      final f = await ensureFunded(r.job ?? job, ui);
      if (!f.ok) return f;
      r = await backend.unlock(job.id, kind);
    }
    if (!r.ok) {
      return GateResult(GateStatus.failed, job: job, message: r.message);
    }
    return GateResult(GateStatus.unlocked,
        job: job,
        grant: GateGrant(
            token: '${r.body['token'] ?? ''}',
            cornerMark: r.body['corner_mark'] != false,
            resultUrl: '${r.body['result'] ?? ''}',
            aiNote: '${r.body['ai_note'] ?? ''}'));
  }
}

// =========================================================================
// Rendering the exported file (corner mark + AI metadata)
// =========================================================================
abstract class ExportRenderer {
  /// Full-quality encoded image -> final PNG (corner mark for free users,
  /// AI-edit note in the file metadata).
  Future<Uint8List> render(Uint8List full,
      {required bool cornerMark, required String note, bool generated = false});
}

class UiExportRenderer implements ExportRenderer {
  const UiExportRenderer({this.markText = 'Edited with Assisto'});
  final String markText;

  @override
  Future<Uint8List> render(Uint8List full,
      {required bool cornerMark, required String note, bool generated = false}) async {
    final codec = await ui.instantiateImageCodec(full);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawImage(img, Offset.zero, Paint());
    if (cornerMark) {
      final w = img.width.toDouble(), h = img.height.toDouble();
      final fs = (w < h ? w : h) * 0.028 + 6;
      final tp = TextPainter(
        text: TextSpan(
            text: markText,
            style: TextStyle(
                color: const Color(0xF2FFFFFF),
                fontSize: fs,
                fontWeight: FontWeight.w600,
                shadows: const [Shadow(blurRadius: 3, color: Color(0x99000000))])),
        textDirection: TextDirection.ltr,
      )..layout();
      final pad = fs * 0.7;
      final box = Rect.fromLTWH(w - tp.width - pad * 2.2, h - tp.height - pad * 1.8,
          tp.width + pad * 1.4, tp.height + pad * 0.9);
      canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(fs * 0.5)),
          Paint()..color = const Color(0x55000000));
      tp.paint(canvas, Offset(box.left + pad * 0.7, box.top + pad * 0.45));
    }
    final pic = rec.endRecording();
    final outImg = await pic.toImage(img.width, img.height);
    final data = await outImg.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    outImg.dispose();
    final png = data!.buffer.asUint8List();
    return PngMeta.markAiEdited(png, note: note, generated: generated);
  }
}

// =========================================================================
// Where the file goes
// =========================================================================
enum DeliverResult { done, unavailable, failed }

abstract class ExportSink {
  /// Whether [kind] works in this build (checked BEFORE the gate, so we
  /// never take ads for an exit that can't deliver).
  bool available(ExportKind kind);
  Future<DeliverResult> deliver(ExportKind kind, Uint8List png, String fileName);
}

/// In this build: Save writes to Assisto's own photo folder, Share uses the
/// system sheet, Open-in hands the file to another app. Set-as-wallpaper and
/// Copy-image need plugins that are in the native proposal — reported as
/// unavailable (never faked).
class PlatformExportSink implements ExportSink {
  const PlatformExportSink();

  @override
  bool available(ExportKind kind) =>
      kind == ExportKind.save || kind == ExportKind.share || kind == ExportKind.openIn;

  Future<File> _write(Uint8List png, String fileName) async {
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/Assisto Photos');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/$fileName');
    await f.writeAsBytes(png, flush: true);
    return f;
  }

  @override
  Future<DeliverResult> deliver(ExportKind kind, Uint8List png, String fileName) async {
    if (!available(kind)) return DeliverResult.unavailable;
    try {
      final f = await _write(png, fileName);
      switch (kind) {
        case ExportKind.save:
          return DeliverResult.done;
        case ExportKind.share:
          await Share.shareXFiles([XFile(f.path, mimeType: 'image/png')]);
          return DeliverResult.done;
        case ExportKind.openIn:
          final r = await OpenFilex.open(f.path, type: 'image/png');
          return r.type == ResultType.done ? DeliverResult.done : DeliverResult.failed;
        default:
          return DeliverResult.unavailable;
      }
    } catch (_) {
      return DeliverResult.failed;
    }
  }
}
