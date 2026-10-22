import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../messaging/avatar_cache.dart';
import '../theme.dart';

/// A chat avatar — shows the member's photo when present, else a brand-tinted
/// initial. [photoUrl] may be an https link, a server-relative signed media
/// path ('/api/v1/m/…'), OR a `data:`/bare base64 blob (the `/me` photo
/// field). ORIGINAL look: Assisto gradient ring on the fallback.
///
/// x2-ticks (A3): network photos go through [CachedAvatarImage] — cached in
/// memory + on disk under a STABLE key ([photoV] from the server, else the
/// signed link's path), so the hourly link rotation never refetches and a new
/// photo shows at once. Relative server paths (what peers' `photo` carried —
/// they never showed before) are resolved against the API host. Any load
/// error falls back to the initial (never a broken image).
class MsgrAvatar extends StatelessWidget {
  final String name;
  final String photoUrl;
  final String photoV;
  final double radius;
  const MsgrAvatar(
      {super.key,
      required this.name,
      this.photoUrl = '',
      this.photoV = '',
      this.radius = 26});

  @override
  Widget build(BuildContext context) {
    final fallback = _initial();
    final img = _imageProvider(photoUrl);
    if (img == null) return fallback;
    final d = radius * 2;
    return SizedBox(
      width: d,
      height: d,
      child: ClipOval(
        child: Image(
          image: img,
          width: d,
          height: d,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: (ctx, child, frame, sync) =>
              (frame == null && !sync) ? fallback : child,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }

  Widget _initial() {
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: const BoxDecoration(
          shape: BoxShape.circle, gradient: Brand.gradient),
      alignment: Alignment.center,
      child: Text(initial,
          style: TextStyle(
              color: Colors.white,
              fontSize: radius * 0.8,
              fontWeight: FontWeight.w700)),
    );
  }

  ImageProvider? _imageProvider(String src) {
    final s = src.trim();
    if (s.isEmpty) return null;
    // ('/9j/…' is a bare base64 JPEG, not a path — only '/api/' is ours)
    if (s.startsWith('http') || s.startsWith('/api/')) {
      // Our own backend: auth header added for same-host URLs inside the
      // cache (AppConfig.authHeadersFor); foreign links load without it.
      return CachedAvatarImage(s, photoV: photoV);
    }
    try {
      final b64 = s.startsWith('data:') ? s.split(',').last : s;
      final bytes = base64Decode(b64);
      return MemoryImage(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    }
  }
}
