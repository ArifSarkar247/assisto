// aifinal PART 7g: a photo question asking for an EDIT offers Photo Studio.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/chat_vision/chat_photo.dart';

void main() {
  test('edit intent (en + bn) vs. a question about the photo', () {
    expect(wantsPhotoEdit('remove the background please'), isTrue);
    expect(wantsPhotoEdit('make a passport photo'), isTrue);
    expect(wantsPhotoEdit('এটা এডিট করো'), isTrue);
    expect(wantsPhotoEdit('ব্যাকগ্রাউন্ড সাদা'), isTrue);
    expect(wantsPhotoEdit('what is in this photo?'), isFalse);
    expect(wantsPhotoEdit('which medicine is this?'), isFalse);
  });
}
