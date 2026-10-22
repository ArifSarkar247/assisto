/// c1-contacts — the phonebook behind an interface, so the screen never
/// pretends it read contacts it could not read.
///
/// * [UnavailableContactsSource] (this build): `available == false`. The
///   screen says honestly that reading the phonebook arrives in the next
///   update and offers find-by-number instead. It never returns fake rows.
/// * `DeviceContactsSource` (next native build): kept OUT of lib/ at
///   `.phaseB/pending_native/c1/device_contacts_source.dart` until the
///   integrator adds the plugin + READ_CONTACTS (see
///   `.phaseB/proposals/c1-contacts.md`). It is created lazily on the
///   contacts screen only (never at launch) and every call is try/catch
///   guarded so a plugin failure degrades to [ContactsPermission.unavailable].
library;

import 'dart:async';
import 'device_contacts_source.dart';

/// One phonebook entry: a display name and its raw numbers (as typed on the
/// phone). Raw numbers stay ON the device — only salted hashes are uploaded.
class DeviceContact {
  const DeviceContact({required this.name, required this.numbers});

  final String name;
  final List<String> numbers;
}

enum ContactsPermission { granted, denied, permanentlyDenied, unavailable }

abstract class ContactsSource {
  /// False when this build cannot read the phonebook at all.
  bool get available;

  /// Current permission without prompting.
  Future<ContactsPermission> status();

  /// Ask the OS for READ_CONTACTS. Call ONLY after the in-app disclosure.
  Future<ContactsPermission> request();

  /// Read the phonebook. Only valid after [request] returned granted.
  Future<List<DeviceContact>> read();

  /// Fires when the phonebook changes (the screen re-syncs). May never fire.
  Stream<void> get changes;

  /// Open the app's system settings page (after a permanent denial).
  Future<bool> openSettings();
}

/// The honest default for builds without the native contacts plugin.
class UnavailableContactsSource implements ContactsSource {
  const UnavailableContactsSource();

  @override
  bool get available => false;

  @override
  Future<ContactsPermission> status() async => ContactsPermission.unavailable;

  @override
  Future<ContactsPermission> request() async => ContactsPermission.unavailable;

  @override
  Future<List<DeviceContact>> read() async => const [];

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<bool> openSettings() async => false;
}

/// Process-wide factory: the real phonebook ([DeviceContactsSource],
/// flutter_contacts). Tests swap it (or inject a source into the screen).
/// A factory (not an instance) keeps creation lazy: nothing is touched until
/// the contacts screen opens.
class ContactsSources {
  ContactsSources._();

  static ContactsSource Function() factory = () => DeviceContactsSource();

  static ContactsSource create() {
    try {
      return factory();
    } catch (_) {
      return const UnavailableContactsSource();
    }
  }
}
