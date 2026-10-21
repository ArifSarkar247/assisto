// c1-contacts — REAL phonebook source. Kept OUT of lib/ until the integrator
// adds `flutter_contacts` + READ_CONTACTS (see .phaseB/proposals/c1-contacts.md).
// Copy to app/lib/services/device_contacts_source.dart in the native build.
//
// Written against:
//   flutter_contacts 1.1.9+2 (MIT):  FlutterContacts.getContacts(
//       withProperties: true), Contact.displayName, Contact.phones[].number,
//       FlutterContacts.addListener / removeListener.
//   permission_handler ^11.3.1 (MIT, already in pubspec): Permission.contacts
//       .status / .request(), openAppSettings().
//
// LAZY + CRASH-GUARDED (owner rule):
//   * Nothing here runs at app launch. The object is created by
//     ContactsSources.create() only when the Contacts screen opens.
//   * The OS prompt is requested only after the in-app disclosure (Allow).
//   * Every plugin call is wrapped in try/catch: a MissingPluginException,
//     a SecurityException or an OEM quirk degrades to
//     ContactsPermission.unavailable / an empty list — never a crash.
//   * The change listener (an Android ContentObserver inside the plugin) is
//     registered only while the screen listens and removed on cancel.
import 'dart:async';

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'contacts_source.dart';

class DeviceContactsSource implements ContactsSource {
  DeviceContactsSource();

  StreamController<void>? _changes;
  void Function()? _listener;

  @override
  bool get available => true;

  ContactsPermission _map(PermissionStatus s) {
    if (s.isGranted || s.isLimited) return ContactsPermission.granted;
    if (s.isPermanentlyDenied || s.isRestricted) {
      return ContactsPermission.permanentlyDenied;
    }
    return ContactsPermission.denied;
  }

  @override
  Future<ContactsPermission> status() async {
    try {
      return _map(await Permission.contacts.status);
    } catch (_) {
      return ContactsPermission.unavailable;
    }
  }

  @override
  Future<ContactsPermission> request() async {
    try {
      return _map(await Permission.contacts.request());
    } catch (_) {
      return ContactsPermission.unavailable;
    }
  }

  @override
  Future<List<DeviceContact>> read() async {
    try {
      if (!(await Permission.contacts.status).isGranted) return const [];
      final list = await FlutterContacts.getContacts(
          withProperties: true, withPhoto: false, withThumbnail: false);
      return [
        for (final c in list)
          if (c.phones.isNotEmpty)
            DeviceContact(
              name: c.displayName,
              numbers: [for (final p in c.phones) p.number],
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Stream<void> get changes {
    _changes ??= StreamController<void>.broadcast(
      onListen: () {
        try {
          _listener = () => _changes?.add(null);
          FlutterContacts.addListener(_listener!);
        } catch (_) {}
      },
      onCancel: () {
        try {
          if (_listener != null) FlutterContacts.removeListener(_listener!);
        } catch (_) {}
        _listener = null;
      },
    );
    return _changes!.stream;
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
