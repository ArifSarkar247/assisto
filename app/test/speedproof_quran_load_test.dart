// speedproof: the bundled Quran text is unpacked + parsed off the UI thread
// (QuranStore._load -> Isolate.run) and still yields the full, exact data.
import 'package:assisto/quran/quran_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load() parses all 114 suras / 6236 ayas in a background isolate', () async {
    QuranStore.debugPreload(null);
    final d = await QuranStore.load();
    expect(d.suras.length, 114);
    expect(d.arabic.length, QuranStore.totalAyas);
    expect(d.english.length, QuranStore.totalAyas);
    expect(d.uthmani.length, QuranStore.totalAyas);
    expect(d.suras[1].ayas, 286); // Al-Baqarah
    expect(d.arabic.every((l) => l.isNotEmpty), isTrue);
    // loads once: the same data object the second time
    expect(identical(await QuranStore.load(), d), isTrue);
    QuranStore.debugPreload(null);
  });
}
