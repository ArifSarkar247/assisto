// cctv100: read the text a camera's LABEL QR code carries, so the owner can
// scan the sticker with the phone's own camera / Google Lens, copy, and paste
// here instead of typing a 15-letter serial and a safety code (Assisto adds
// no scanner plugin). Best effort and honest: if nothing is recognised the
// caller says so and the owner types it.
//
// Shapes handled (from public vendor material; to be confirmed on the
// owner's real label — owner_actions/CCTV_GAP_TO_100_BN.md):
//   Imou / Dahua   {SN:7J0A8B9CPAZ1234,DT:IPC-A22EP,SC:L2C3D4,NC:SL}
//                  (older Lechange stickers: RC: instead of SC:)
//   line form      <serial>\n<6-letter verification code>[\n<model>]
//                  (EZVIZ / Hik-Connect stickers print serial + code lines)

class CameraLabel {
  final String serial;
  final String code; // '' when the label text had none
  final String model; // '' when unknown
  const CameraLabel(this.serial, this.code, this.model);
}

final _kv = RegExp(r'\b(SN|SC|RC|DT)\s*[:=]\s*([A-Za-z0-9\-]+)', caseSensitive: false);
final _serialRe = RegExp(r'^[A-Z0-9]{8,20}$');
final _codeRe = RegExp(r'^[A-Za-z0-9]{6,8}$');
final _modelRe = RegExp(r'^[A-Z]{1,5}-[A-Z0-9\-]{2,24}$', caseSensitive: false);

CameraLabel? parseCameraLabel(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty || text.length > 400) return null;
  final m = <String, String>{};
  for (final x in _kv.allMatches(text)) {
    m.putIfAbsent(x.group(1)!.toUpperCase(), () => x.group(2)!);
  }
  final sn = (m['SN'] ?? '').toUpperCase();
  if (_serialRe.hasMatch(sn)) {
    return CameraLabel(sn, m['SC'] ?? m['RC'] ?? '', m['DT'] ?? '');
  }
  // line / whitespace form: first serial-looking token, then a code token
  final toks = text
      .split(RegExp(r'[\s,;|]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !s.contains('.') && !s.contains('/'))
      .toList();
  String serial = '', code = '', model = '';
  for (final tk in toks) {
    if (model.isEmpty && _modelRe.hasMatch(tk)) {
      model = tk;
    } else if (serial.isEmpty && _serialRe.hasMatch(tk.toUpperCase()) &&
        RegExp(r'\d').hasMatch(tk)) {
      serial = tk.toUpperCase();
    } else if (serial.isNotEmpty && code.isEmpty && _codeRe.hasMatch(tk)) {
      code = tk;
    }
  }
  if (serial.isEmpty) return null;
  return CameraLabel(serial, code, model);
}
