import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../config.dart';
import '../theme.dart';

/// A chat avatar — shows the member's photo when present, else a brand-tinted
/// initial. [photoUrl] may be an https link OR a `data:`/bare base64 blob (the
/// `/me` photo field). ORIGINAL look: Assisto gradient ring on the fallback.
class MsgrAvatar extends StatelessWidget {
  final String name;
  final String photoUrl;
  final double radius;
  const MsgrAvatar(
      {super.key,
      required this.name,
      this.photoUrl = '',
      this.radius = 26});

  @override
  Widget build(BuildContext context) {
    final img = _imageProvider(photoUrl);
    if (img != null) {
      return CircleAvatar(radius: radius, backgroundImage: img);
    }
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
    if (src.isEmpty) return null;
    if (src.startsWith('http')) {
      // Our own backend serves the avatar through an auth-checked view
      // (/me/avatar), so attach the token header for same-host URLs. External
      // avatar links (foreign host) load without it.
      return NetworkImage(src, headers: AppConfig.authHeadersFor(src));
    }
    try {
      final b64 = src.startsWith('data:') ? src.split(',').last : src;
      final bytes = base64Decode(b64);
      return MemoryImage(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    }
  }
}
