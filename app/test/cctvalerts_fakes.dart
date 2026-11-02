// cctvalerts (W3): a fake alert-types server for widget tests + the gallery.
// Shapes and wording mirror backend/core/cctv_alerts.py types_payload().
import 'package:assisto/screens/watchman/camera_alert_types.dart';

class FakeAlertTypes implements AlertTypesSource {
  final String mode; // hik | imou | fail | savefail
  final String lang;
  final List<Map<String, bool>> saved = [];
  int loads = 0;
  FakeAlertTypes(this.mode, {this.lang = 'en'});

  static const _labels = {
    'person': ['মানুষ', 'Person'],
    'vehicle': ['গাড়ি / মোটরসাইকেল', 'Vehicle'],
    'animal': ['প্রাণী (কুকুর / বিড়াল)', 'Animal (dog / cat)'],
    'line': ['রেখা পার হওয়া', 'Line crossing'],
    'loiter': ['রাতে ২ মিনিটের বেশি ঘোরাঘুরি', 'Loitering over 2 min at night'],
    'covered': ['ক্যামেরা ঢাকা / ঝাপসা', 'Camera covered / blurred'],
    'moved': ['ক্যামেরা সরানো / ঘোরানো', 'Camera moved / turned'],
    'dark': ['ছবি একদম অন্ধকার', 'Picture completely dark'],
    'sd_fail': ['SD কার্ডে সমস্যা', 'SD card problem'],
    'sound': ['জোরে শব্দ', 'Loud sound'],
  };
  static const _notes = {
    'yes': ['এই ক্যামেরা নিজে জানায়', 'This camera reports it'],
    'some': ['কিছু মডেলে আছে — আপনার ক্যামেরা এখনো পাঠায়নি', 'Some models only — your camera has not sent one yet'],
    'server': ['Assisto নিজে ধরে (ক্যামেরার ছবি / সতর্কতা থেকে)', 'Assisto works it out (from the camera\'s pictures / alerts)'],
    'no': ['এই ক্যামেরায় নেই', 'Not on this camera'],
    'seen': ['এই ক্যামেরা পাঠিয়েছে', 'This camera has sent it'],
  };
  static const _hik = {
    'person': 'seen', 'vehicle': 'some', 'animal': 'no', 'line': 'seen', 'loiter': 'some',
    'covered': 'yes', 'moved': 'some', 'dark': 'server', 'sd_fail': 'yes', 'sound': 'some',
  };
  static const _imou = {
    'person': 'seen', 'vehicle': 'some', 'animal': 'some', 'line': 'some', 'loiter': 'server',
    'covered': 'server', 'moved': 'server', 'dark': 'server', 'sd_fail': 'seen', 'sound': 'some',
  };
  final Map<String, bool> _on = {
    'person': true, 'vehicle': true, 'animal': false, 'line': true, 'loiter': true,
    'covered': true, 'moved': true, 'dark': true, 'sd_fail': true, 'sound': false,
  };

  Map<String, dynamic> _payload() {
    final i = lang == 'bn' ? 0 : 1;
    final table = mode == 'imou' ? _imou : _hik;
    final bn = lang == 'bn';
    return {
      'camera': 5,
      'vendor': mode == 'imou' ? 'imou' : 'hikvision',
      'types': [
        for (final k in _labels.keys)
          {
            'kind': k,
            'on': table[k] != 'no' && _on[k] == true,
            'support': table[k] == 'seen' ? 'yes' : table[k],
            'seen': table[k] == 'seen',
            'available': table[k] != 'no',
            'label': _labels[k]![i],
            'note': _notes[table[k]]![i],
          }
      ],
      'night': {
        'source': 'schedule',
        'start': bn ? '২১:০০' : '21:00',
        'end': bn ? '০৯:০০' : '09:00',
        'text': bn ? 'আপনার পাহারার সময়সূচি' : 'your guard schedule',
      },
      'line_today': {'total': 14, 'a_to_b': 9, 'b_to_a': 5},
      'sd': mode == 'imou'
          ? {'state': 'problem', 'text': bn ? 'SD কার্ডে সমস্যা' : 'SD card problem'}
          : {'state': 'ok', 'text': bn ? 'SD কার্ড ঠিক আছে' : 'SD card OK'},
      'ai_used': false,
    };
  }

  @override
  Future<Map<String, dynamic>> load(int cameraId) async {
    // 'fail': the first load fails (offline), "Try again" then works
    if (mode == 'fail' && loads++ == 0) throw Exception('offline');
    return _payload();
  }

  @override
  Future<Map<String, dynamic>> save(int cameraId, Map<String, bool> types) async {
    saved.add(Map.of(types));
    if (mode == 'savefail') throw Exception('offline');
    _on.addAll(types);
    return _payload();
  }
}
