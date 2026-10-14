import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Capture + share helper for Monthly Money Wrapped cards (feature #63, §21).
///
/// Mirrors the proven RepaintBoundary->PNG->share_plus flow already used by
/// emergency_card_view.dart, kept in its own file so the Wrapped screen can
/// share the currently-visible story card as a festival-style image.
///
/// Read-only: it only renders what the screen already drew from real recap
/// data; it computes nothing and invents nothing.
class WrappedShare {
  /// Capture a GlobalKey'd RepaintBoundary to a PNG file in the temp dir.
  /// Returns null if the boundary isn't painted yet. Caller shares the file.
  static Future<File?> captureToFile(GlobalKey key,
      {String fileName = 'money_wrapped.png'}) async {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final obj = ctx.findRenderObject();
    if (obj is! RenderRepaintBoundary) return null;
    final ui.Image image = await obj.toImage(pixelRatio: 3.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$fileName');
    await f.writeAsBytes(bytes.buffer.asUint8List());
    return f;
  }

  /// Share the captured card as an image (with a text caption fallback).
  /// Returns false if the boundary wasn't ready (caller falls back to text).
  static Future<bool> shareAsImage(GlobalKey key, String caption) async {
    final f = await captureToFile(key);
    if (f == null) return false;
    await Share.shareXFiles([XFile(f.path)], text: caption);
    return true;
  }

  /// Plain-text share fallback (used when capture isn't possible).
  static Future<void> shareAsText(String text) => Share.share(text);
}
