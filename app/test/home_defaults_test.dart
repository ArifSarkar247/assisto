import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

/// Owner default home quick buttons (GET /app/home-defaults): used only while
/// the user has not customized; cached; never throws.
void main() {
  const owner = ['emergency', 'money', 'reminders', 'scam', 'nearby', 'notes'];
  Future<Map<String, dynamic>> ok() async => {'quick_buttons': owner, 'count': 6};

  test('not customized -> server default applies and is cached', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await HomeQuickButtons.load(), HomeQuickButtons.defaults);
    expect(await HomeQuickButtons.refreshOwnerDefault(ok), owner);
    // next cold start paints the cached owner default immediately
    expect(await HomeQuickButtons.load(), owner);
    expect(await HomeQuickButtons.ownerDefault(), owner);
    expect(await HomeQuickButtons.isCustomized(), isFalse);
  });

  test('customized -> server default never overrides the user', () async {
    SharedPreferences.setMockInitialValues({});
    final mine = ['budget', 'tax', 'crm', 'jobs', 'scam', 'nearby'];
    await HomeQuickButtons.save(mine);
    expect(await HomeQuickButtons.refreshOwnerDefault(ok), isNull);
    expect(await HomeQuickButtons.load(), mine);
    // but it is still cached, so "Reset" restores the owner default
    expect(await HomeQuickButtons.ownerDefault(), owner);
  });

  test('network error / bad payload -> null, nothing changes', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await HomeQuickButtons.refreshOwnerDefault(() async => throw Exception('offline')), isNull);
    expect(await HomeQuickButtons.refreshOwnerDefault(() async => {'quick_buttons': 'x'}), isNull);
    expect(await HomeQuickButtons.refreshOwnerDefault(() async => <String, dynamic>{}), isNull);
    expect(await HomeQuickButtons.load(), HomeQuickButtons.defaults);
  });

  test('server list is sanitized (unknown dropped, topped up to 6)', () async {
    SharedPreferences.setMockInitialValues({});
    final r = await HomeQuickButtons.refreshOwnerDefault(
        () async => {'quick_buttons': ['scam', 'not_a_route', 'scam']});
    expect(r!.length, 6);
    expect(r.first, 'scam');
    expect(r.toSet().length, 6);
  });
}
