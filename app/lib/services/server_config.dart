import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// SERVER-ADDRESS SWAP — the config surface that holds an optional runtime
/// override for the backend base URL (#179, SPEC v2.1 §21, ADVANCED).
///
/// WHY A SEPARATE SURFACE (and not api.dart):
/// [AppConfig.apiBase] is a COMPILE-TIME const baked into api.dart's request
/// helpers, which this change must NOT touch. So the swap is modelled honestly:
/// this store persists the owner's chosen base URL + validates + probes
/// reachability on its OWN [http.Client], and exposes [effectiveBase]. The
/// integrator wires api.dart to read [ServerConfig.effectiveBase] once (a tiny,
/// documented change) so the override takes effect app-wide. Until then the
/// screen still validates, probes, persists and reverts — it is honest that an
/// app relaunch (or the one-line api.dart wiring) applies the change, and never
/// claims a swap it can't prove reachable.
///
/// SAFE REVERT: the shipped default ([AppConfig.apiBase]) is always one tap
/// away; clearing the override restores it.
class ServerConfig {
  ServerConfig._();

  static const _prefsKey = 'server_base_override';

  /// Reachability probe states.
  /// idle        — not checked yet
  /// checking    — probe in flight
  /// reachable   — /health answered ok
  /// unreachable — connected but not a healthy Assisto backend
  /// error       — network/timeout/other
  static const probeIdle = 'idle';
  static const probeChecking = 'checking';
  static const probeReachable = 'reachable';
  static const probeUnreachable = 'unreachable';
  static const probeError = 'error';

  /// The compiled-in default the app ships with.
  static String get shippedDefault => AppConfig.apiBase;

  /// Read the persisted override (null if none / if it equals the default).
  static Future<String?> readOverride() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_prefsKey);
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// The base URL that SHOULD be used: the override if set, else the shipped
  /// default. (The integrator points api.dart at this.)
  static Future<String> effectiveBase() async {
    final o = await readOverride();
    return o ?? AppConfig.apiBase;
  }

  /// Persist a validated override. Pass null/empty to clear (safe revert).
  static Future<void> saveOverride(String? base) async {
    final p = await SharedPreferences.getInstance();
    final norm = normalize(base ?? '');
    if (norm == null || norm == AppConfig.apiBase) {
      await p.remove(_prefsKey);
    } else {
      await p.setString(_prefsKey, norm);
    }
  }

  // ----------------------------------------------------------- validation

  /// Validate + normalize a user-typed base URL. Returns the normalized origin
  /// (scheme://host[:port], no trailing slash, no path) or null if invalid.
  /// PURE — no network. Rules: must be http/https, must have a host, must NOT
  /// carry a path/query/fragment (a base is an origin only).
  static String? normalize(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    Uri? u;
    try {
      u = Uri.parse(trimmed);
    } catch (_) {
      return null;
    }
    if (u.scheme != 'http' && u.scheme != 'https') return null;
    if (u.host.isEmpty) return null;
    if (u.hasQuery || u.fragment.isNotEmpty) return null;
    if (u.path.isNotEmpty && u.path != '/') return null;
    final port = u.hasPort ? ':${u.port}' : '';
    return '${u.scheme}://${u.host}$port';
  }

  /// Problem code for invalid input (for localized error copy), or '' if OK.
  /// 'empty' | 'bad_scheme' | 'no_host' | 'has_path' | 'parse'.
  static String validateProblem(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return 'empty';
    Uri u;
    try {
      u = Uri.parse(trimmed);
    } catch (_) {
      return 'parse';
    }
    if (u.scheme != 'http' && u.scheme != 'https') return 'bad_scheme';
    if (u.host.isEmpty) return 'no_host';
    if (u.hasQuery || u.fragment.isNotEmpty) return 'has_path';
    if (u.path.isNotEmpty && u.path != '/') return 'has_path';
    return '';
  }

  // ----------------------------------------------------------- reachability

  /// Probe a base URL's `/api/v1/health` on an INDEPENDENT client (does not
  /// touch api.dart). Returns one of the probe* constants. [latencyMs] is
  /// filled in [ProbeResult]. Honest: only returns [probeReachable] when the
  /// server answers 200 with the expected health shape.
  static Future<ProbeResult> probe(String base,
      {Duration timeout = const Duration(seconds: 6)}) async {
    final norm = normalize(base);
    if (norm == null) {
      return const ProbeResult(probeError, 0, 0);
    }
    final client = http.Client();
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse('$norm${AppConfig.apiPrefix}/health');
      final r = await client.get(uri).timeout(timeout);
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      if (r.statusCode == 200 &&
          (r.body.contains('"status"') || r.body.contains('ok'))) {
        return ProbeResult(probeReachable, r.statusCode, ms);
      }
      return ProbeResult(probeUnreachable, r.statusCode, ms);
    } on TimeoutException {
      sw.stop();
      return ProbeResult(probeError, 0, sw.elapsedMilliseconds);
    } catch (_) {
      sw.stop();
      return ProbeResult(probeError, 0, sw.elapsedMilliseconds);
    } finally {
      client.close();
    }
  }
}

/// Result of a reachability probe: a state constant + the HTTP status (0 if
/// none) + round-trip latency in ms.
class ProbeResult {
  final String state;
  final int status;
  final int latencyMs;
  const ProbeResult(this.state, this.status, this.latencyMs);
}
