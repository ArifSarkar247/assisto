import 'dart:async';

import '../api.dart';
import '../l10n/app_localizations.dart';

/// rt2 — WHO failed, so the user is never blamed for our server.
///
/// Reality run 39859999833: `POST /circle/1/call` answered **500** and the
/// call screen said "Couldn't reach Assisto. Please check your internet" —
/// the phone's internet was fine, our server broke. Every honest error line
/// starts from this classification:
///
/// * [FailKind.server]  — the server answered, with a 5xx. Not the user's
///   connection: "Assisto's server had a problem, try again in a moment".
/// * [FailKind.network] — the request never got an answer (socket / DNS /
///   TLS / `http.ClientException`, a timeout): the internet line is honest.
/// * [FailKind.refused] — the server answered 4xx (validation, limits, auth):
///   the caller shows the server's own sentence or its specific line.
enum FailKind { server, network, refused }

/// True for an answer from our server with a 5xx status.
bool isServerFailure(Object e) =>
    e is ApiException && (e.status ?? 0) >= 500;

FailKind failKindOf(Object e) {
  if (e is ApiException) {
    final s = e.status ?? 0;
    if (s >= 500) return FailKind.server;
    if (s >= 400) return FailKind.refused;
    return FailKind.network; // status 0 / unknown: no real answer
  }
  if (e is TimeoutException) return FailKind.network;
  return FailKind.network; // SocketException, ClientException, Handshake...
}

/// The one honest line for a failed load/request: a server 5xx says so;
/// anything else keeps the caller's own [otherwise] text (by default the
/// "check your internet" line, which is then true).
String honestFailText(AppLocalizations t, Object? e, {String? otherwise}) {
  if (e != null && isServerFailure(e)) return t.m3ErrServer;
  return otherwise ?? t.qaLoadFailedRetry;
}

/// qa2 — for an error state that names no cause (title only): a server 5xx
/// adds the "our server had a problem" line; anything else adds nothing.
String? serverFailText(AppLocalizations t, Object? e) =>
    e != null && isServerFailure(e) ? t.m3ErrServer : null;
