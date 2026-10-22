import 'dart:typed_data';

/// ON-DEVICE photo reading for "image in chat" (h1-home): text recognition
/// (OCR) + basic image labels, free and offline.
///
/// HONEST STATE OF THIS BUILD: the ML Kit plugins are not linked yet
/// (pubspec/native change, see `.phaseB/proposals/h1-home.md` §B), so
/// [createOnDeviceVision] returns [UnavailableOnDeviceVision] and the chat
/// says so plainly. The real implementation is
/// `.phaseB/pending_native/h1/mlkit_on_device_vision.dart.pending`.
///
/// SCRIPT LIMIT (checked): ML Kit on-device text recognition v2 reads Latin,
/// Chinese, Devanagari, Japanese and Korean — NOT Bengali script. On-device
/// reading is therefore English/Latin only; Bangla text is read by the
/// detailed (cloud) answer. [OnDeviceReading.latinOnly] carries that so the
/// UI can say it.
enum OnDeviceStatus { ok, unavailable, failed }

class OnDeviceReading {
  const OnDeviceReading({
    required this.status,
    this.text = '',
    this.labels = const [],
    this.latinOnly = true,
  });
  final OnDeviceStatus status;

  /// All text the phone could read (may be empty).
  final String text;

  /// Basic image labels ("Plant", "Food", "Paper"...), English, best first.
  final List<String> labels;

  /// The recogniser reads Latin script only (Bangla is not read on-device).
  final bool latinOnly;

  static const unavailable = OnDeviceReading(status: OnDeviceStatus.unavailable);
  static const failed = OnDeviceReading(status: OnDeviceStatus.failed);

  bool get ok => status == OnDeviceStatus.ok;
  bool get hasText => text.trim().isNotEmpty;
}

abstract class OnDeviceVision {
  /// False until the ML Kit plugins are linked in the native build.
  bool get available;

  /// Read one photo. Never throws; lazy-initialises on first use only.
  Future<OnDeviceReading> read(Uint8List bytes);
}

class UnavailableOnDeviceVision implements OnDeviceVision {
  const UnavailableOnDeviceVision();
  @override
  bool get available => false;
  @override
  Future<OnDeviceReading> read(Uint8List bytes) async => OnDeviceReading.unavailable;
}

OnDeviceVision createOnDeviceVision() => const UnavailableOnDeviceVision();

/// What kind of photo the on-device reading suggests (pure, testable).
enum PhotoKind { medicine, bill, document, plant, food, other }

class OnDeviceAnswer {
  OnDeviceAnswer._(this.kind, this.text, this.labels);
  final PhotoKind kind;
  final String text;
  final List<String> labels;

  static const _med = [
    'tablet', 'tab.', 'capsule', 'cap.', 'syrup', 'mg', 'ml', 'dose',
    'paracetamol', 'antibiotic', 'medicine', 'pharma', 'rx', 'drug',
  ];
  static const _bill = [
    'total', 'amount', 'bill', 'invoice', 'due', 'vat', 'bdt', 'tk', 'paid',
    'receipt', 'subtotal', 'balance', 'kwh', 'meter',
  ];
  static const _doc = [
    'certificate', 'name', 'date of birth', 'address', 'signature', 'ref',
    'office', 'government', 'letter', 'nid', 'passport',
  ];

  static bool _has(String blob, List<String> words) {
    for (final w in words) {
      if (RegExp(r'(^|[^a-z])' + RegExp.escape(w) + r'($|[^a-z])').hasMatch(blob)) {
        return true;
      }
    }
    return false;
  }

  /// Turn a reading into a short, honest, useful local answer.
  static OnDeviceAnswer from(OnDeviceReading r) {
    final blob = '${r.text}\n${r.labels.join(' ')}'.toLowerCase();
    final labels = r.labels.map((e) => e.toLowerCase()).toList();
    PhotoKind kind;
    if (_has(blob, _med)) {
      kind = PhotoKind.medicine;
    } else if (_has(blob, _bill)) {
      kind = PhotoKind.bill;
    } else if (labels.any((l) => l.contains('plant') || l.contains('flower') ||
        l.contains('leaf') || l.contains('tree'))) {
      kind = PhotoKind.plant;
    } else if (labels.any((l) => l.contains('food') || l.contains('dish') ||
        l.contains('fruit'))) {
      kind = PhotoKind.food;
    } else if (_has(blob, _doc) || r.text.trim().length > 80) {
      kind = PhotoKind.document;
    } else {
      kind = PhotoKind.other;
    }
    return OnDeviceAnswer._(kind, r.text.trim(), r.labels.take(6).toList());
  }
}
