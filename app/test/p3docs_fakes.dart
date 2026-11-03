// p3docs: in-memory VaultE2EBackend for tests + the screenshot gallery.
import 'dart:typed_data';

import 'package:assisto/vault/vault_e2e_api.dart';

class FakeE2E implements VaultE2EBackend {
  FakeE2E([Map<String, dynamic>? state]) {
    if (state != null) st = state;
  }

  Map<String, dynamic> st = {'ok': true, 'recovery_wrap': false, 'helpers': [], 'sealed_docs': 0, 'help_inbox': 0};
  String? recovery;
  List<Map<String, dynamic>> inbox = [];
  @override
  Future<Map<String, dynamic>> state() async => st;
  @override
  Future<void> putRecovery(String wrap) async => recovery = wrap;
  @override
  Future<String?> getRecovery() async => recovery;
  @override
  Future<void> deleteRecovery() async => recovery = null;
  @override
  Future<Map<String, dynamic>> peerKey(int memberId) async => {};
  @override
  Future<Map<String, dynamic>> addHelper(int memberId, String wrap, String keyId) async => {'_status': 201};
  @override
  Future<void> deleteHelper(int wrapId) async {}
  @override
  Future<Map<String, dynamic>> requestHelp(int wrapId, String publicKeyB64, String keyId) async => {'_status': 201};
  @override
  Future<Map<String, dynamic>?> helpRequest() async => null;
  @override
  Future<void> cancelHelp() async {}
  @override
  Future<List<Map<String, dynamic>>> helpInbox() async => inbox;
  @override
  Future<Map<String, dynamic>> decideHelp(int id, {required bool approve, String? wrap}) async => {'_status': 200};
  @override
  Future<Map<String, dynamic>> uploadSealed(
          {required String docType, String? expiryDate, required bool expiryAlerts, required String box, Uint8List? file}) async =>
      {'id': 1};
  @override
  Future<Map<String, dynamic>> createShare(int docId, int hours, int maxOpens, Uint8List blob) async =>
      {'url': 'https://lifeassisto.com/d/tok'};
  @override
  Future<List<Map<String, dynamic>>> shares(int docId) async => [];
  @override
  Future<void> revokeShare(int id) async {}
}

