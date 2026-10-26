// booking1: gallery states for test/screenshots_test.dart (and therefore the
// a11y guideline sweep + dead-button sweep) — the booking bot.
import 'package:flutter/material.dart';

import 'package:assisto/screens/booking/booking_biz_screen.dart';
import 'package:assisto/screens/booking/booking_detail_screen.dart';
import 'package:assisto/screens/booking/booking_setup_screen.dart';
import 'package:assisto/screens/booking/my_bookings_screen.dart';

import 'booking1_fakes.dart';

final Map<String, Widget Function(String)> booking1Shots = {
  'bkg_first_run': (_) => BookingBizScreen(source: FakeBooking('empty')),
  'bkg_today': (_) => BookingBizScreen(source: FakeBooking('data'), guide: false),
  'bkg_today_guide': (_) => BookingBizScreen(source: FakeBooking('data'), guide: true),
  'bkg_upcoming': (_) => BookingBizScreen(source: FakeBooking('data'), guide: false, initialTab: 1),
  'bkg_day_view': (_) => BookingBizScreen(source: FakeBooking('data'), guide: false, initialTab: 2),
  'bkg_feature_off': (_) => BookingBizScreen(source: FakeBooking('off'), guide: false),
  'bkg_offline': (_) => BookingBizScreen(source: FakeBooking('offline'), guide: false),
  'bkg_load_error': (_) => BookingBizScreen(source: FakeBooking('fail'), guide: false),
  'bkg_staff_not_set_up': (_) => BookingBizScreen(source: FakeBooking('staff'), guide: false),
  'bkg_setup_services': (_) => BookingSetupScreen(source: FakeBooking('data'), initial: const {
        'services': [
          {'id': 1, 'name': 'Haircut', 'duration_min': 30, 'buffer_min': 10, 'price_bdt': 300}
        ]
      }),
  'bkg_setup_hours': (_) => BookingSetupScreen(source: FakeBooking('data'), initial: const {}, initialStep: 1),
  'bkg_setup_rules': (_) => BookingSetupScreen(
      source: FakeBooking('data'), initial: const {'slug': 'rupa-salon', 'plan_ok': true}, initialStep: 2),
  'bkg_detail_requested': (_) => BookingDetailScreen(
      source: FakeBooking('data'), bookingId: 2, initial: FakeBooking.row(2, 'requested', thread: 9)),
  'bkg_detail_confirmed': (_) => BookingDetailScreen(
      source: FakeBooking('data'), bookingId: 1, initial: FakeBooking.row(1, 'confirmed')),
  'bkg_my_bookings': (_) => MyBookingsScreen(source: FakeBooking('mine'), guide: false),
  'bkg_my_empty': (_) => MyBookingsScreen(source: FakeBooking('empty')),
  'bkg_book_link': (_) => BookWithBusinessScreen(source: FakeBooking('mine')),
  'bkg_book_pick': (_) => BookWithBusinessScreen(source: FakeBooking('mine'), slug: 'rupa-salon'),
};
