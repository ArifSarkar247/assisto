# Dead-button sweep report

Screens: 354 · taps tested: 2009 · DEAD: 0 · skipped: 124

## login

| button | effect |
|---|---|
| #0 FilledButton "Log in" | net, ui-change |
| #1 TextButton "New here? Create a profile" | ui-change |
| #2 TextButton "Forgot password?" | push:page, api:GET /auth/otp/status, net, ui-change |
| #3 TextButton "icon:0xf3ad / Sign in with an SMS code key=login-with-sms" | push:page, ui-change |

## language_picker

| button | effect |
|---|---|
| #0 InkWell "বাংলা / Bangla / icon:0xe159" | SKIP:already the selected option |
| #1 InkWell "English / English / icon:0xef53" | ui-change |
| #2 FilledButton "Continue" | net, platform:plugins.it_nomads.com/flutter_secure_storage#write |

## home_welcome

| button | effect |
|---|---|
| #0 InkWell "icon:0xeeab / Photo Studio / Sharpen and brighten any photo in seconds…" | push:page, api:POST /discover/track GET /photo-studio/config, net, ui-change |
| #1 InkWell "icon:0xf293 / Anti-theft / Protect your phone if it is lost or stolen." | push:page, api:POST /discover/track, net, ui-change |
| #2 TextButton "icon:0xe683 / Edit" | push:sheet, ui-change |
| #3 InkWell "icon:0xee66 / Reminders" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #4 InkWell "icon:0xee33 / Account & Finance" | push:page, ui-change |
| #5 InkWell "icon:0xef4a / Notes/Tasks" | push:page, ui-change |
| #6 InkWell "icon:0xeea9 / Assisto AI" | push:page, ui-change |
| #7 InkWell "icon:0xf089f / Family" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #8 InkWell "icon:0xe3b1 / Documents" | push:page, platform:plugins.it_nomads.com/flutter_secure_storage#read, ui-change, ERROR:async: MissingPluginException(No implementation found for method read on channel plugins.it_nomads.com/flutter_secure_storage) |
| #9 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #10 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #11 IconButton "icon:0xe0a0" | ui-change |
| #12 IconButton "tip:Photo Studio / icon:0xeeab" | push:page, api:GET /photo-studio/config, net, ui-change |
| #13 IconButton "tip:Notifications / icon:0xf237" | push:page, api:GET /notif/reminders POST /notif/opened GET /notif/feed, net, ui-change |
| #14 IconButton "tip:My Circle / icon:0xf08a1" | push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, platform:plugins.it_nomads.com/flutter_secure_storage#read plugins.it_nomads.com/flutter_secure_storage#write, ui-change |

## notification_centre

| button | effect |
|---|---|
| #12 InkWell "Reminders / Tab 1 of 2" | SKIP:already the selected option |
| #0 InkWell "icon:0xee66 / Noon medicine / Oct 14" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #1 FilledButton "icon:0xe156 / Done" | snackbar, api:POST /notif/reminders/reminder:2/done, net, ui-change |
| #2 PopupMenuButton "tip:Snooze / icon:0xf3af / Snooze / icon:0xe098" | push:popup, ui-change |
| #3 InkWell "icon:0xee66 / Netflix renews ৳500 / Oct 14" | push:page, api:LIST subscriptions, ui-change |
| #4 FilledButton "icon:0xe156 / Done" | snackbar, api:POST /notif/reminders/sub:3/done, net, ui-change |
| #5 PopupMenuButton "tip:Snooze / icon:0xf3af / Snooze / icon:0xe098" | push:popup, ui-change |
| #6 InkWell "icon:0xee66 / Client meeting / Oct 14" | push:page, api:LIST appointments, ui-change |
| #7 FilledButton "icon:0xe156 / Done" | snackbar, api:POST /notif/reminders/meeting:4/done, net, ui-change |
| #8 PopupMenuButton "tip:Snooze / icon:0xf3af / Snooze / icon:0xe098" | push:popup, ui-change |
| #9 InkWell "icon:0xf233 / Missed yesterday's medicine / Oct 14" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #10 FilledButton "icon:0xe156 / Done" | snackbar, api:POST /notif/reminders/reminder:1/done, net, ui-change |
| #11 PopupMenuButton "tip:Snooze / icon:0xf3af / Snooze / icon:0xe098" | push:popup, ui-change |
| #13 InkWell "Notifications / 2 / Tab 2 of 2" | api:GET /notif/feed POST /notif/opened, net, ui-change |

## msgr_profile

| button | effect |
|---|---|
| #3 ChoiceChip "My circle" | SKIP:already the selected option |
| #6 ChoiceChip "My circle" | SKIP:already the selected option |
| #0 InkWell "icon:0xf29b" | push:sheet, ui-change |
| #1 TextButton "Change photo" | push:sheet, ui-change |
| #2 InkWell "icon:0xe3b1 / Who sees each field is set per field. / Open privacy set…" | push:page, ui-change |
| #4 ChoiceChip "Family only" | ui-change |
| #5 ChoiceChip "Nobody" | ui-change |
| #7 ChoiceChip "Family only" | ui-change |
| #8 ChoiceChip "Nobody" | ui-change |
| #9 FilledButton "Save" | snackbar, net, ui-change |

## contacts

| button | effect |
|---|---|
| #0 TextButton "icon:0xf379 / How your privacy is protected" | push:sheet, ui-change |
| #1 FilledButton "icon:0xf47d / Allow and find contacts key=c1-allow" | platform:flutter.baseflow.com/permissions/methods#requestPermissions, ui-change |
| #2 TextButton "Not now" | ui-change |
| #3 IconButton "tip:How your privacy is protected / icon:0xf379" | push:sheet, ui-change |
| #4 IconButton "tip:Connection request / icon:0xf117" | push:page, snackbar, api:GET /messenger/request, net, ui-change |

## c1_contacts_disclosure

| button | effect |
|---|---|
| #0 TextButton "icon:0xf379 / How your privacy is protected" | push:sheet, ui-change |
| #1 FilledButton "icon:0xf47d / Allow and find contacts key=c1-allow" | api:GET /messenger/contacts/contract POST /messenger/contacts/match, ui-change |
| #2 TextButton "Not now" | ui-change |
| #3 IconButton "tip:How your privacy is protected / icon:0xf379" | push:sheet, ui-change |
| #4 IconButton "tip:Connection request / icon:0xf117" | push:page, snackbar, api:GET /messenger/request, net, ui-change |

## c1_contacts_synced

| button | effect |
|---|---|
| #0 IconButton "tip:Search by number, e.g. 01712345678 / icon:0xe49c key=c1-search-go" | ui-change |
| #1 FilledButton "icon:0xe155 / Message key=c1-msg-3" | push:page, api:GET /circle/keys/peer/30 GET /circle/t1/gate?kind=member&id=30 GET /circle/30/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #2 IconButton "tip:Call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/30/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change, ERROR:MissingPluginException(No implementation found for method listen on channel FlutterWebRTC.Event) |
| #3 FilledButton "icon:0xe155 / Message key=mr1-msg-4" | snackbar, api:POST /circle/message-request/start, ui-change |
| #4 FilledButton "icon:0xe494 / Add to My Circle key=c1-add-2" | push:sheet, api:GET /rt/events?after=0, net, ui-change |
| #5 IconButton "tip:Message / icon:0xe155 key=mr1-msg-2" | snackbar, api:POST /circle/message-request/start, ui-change |
| #6 TextButton "Invite" | snackbar, api:POST /messenger/invite/sms, net, platform:plugins.flutter.io/url_launcher#canLaunch, ui-change |
| #7 TextButton "Invite" | snackbar, api:POST /messenger/invite/sms, net, platform:plugins.flutter.io/url_launcher#canLaunch, ui-change |
| #8 FilledButton "icon:0xe34d / Share invite link" | api:POST /messenger/invite/share-link, net, platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #9 OutlinedButton "icon:0xf3ad / Invite by SMS" | push:dialog, ui-change |
| #10 TextButton "icon:0xe380 / Copy link" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #11 TextButton "icon:0xf3e3 / See referral points" | push:page, api:GET /referral/balance GET /referral/history, ui-change |
| #12 IconButton "tip:How your privacy is protected / icon:0xf379" | push:sheet, api:GET /rt/events?after=0, net, ui-change |
| #13 IconButton "tip:Connection request / icon:0xf117" | push:page, snackbar, api:GET /messenger/request, net, ui-change |

## m3_add_circle

| button | effect |
|---|---|
| #0 FilledButton "Find key=m3-find" | ui-change |
| #1 ListTile "icon:0xef7e / Pick from phone contacts / See which of your contacts ar… key=m3-pick-contacts" | push:page, api:GET /referral/balance, ui-change |
| #2 ListTile "icon:0xe4f6 / Show my QR code / Or share your invite link key=m3-my-qr" | push:dialog, api:GET /circle/invite?relation=friend, ui-change |
| #3 ListTile "icon:0xe380 / Paste an invite link / Someone sent you their My Circle … key=m3-paste" | push:dialog, platform:flutter/platform#Clipboard.getData, ui-change |

## m3_add_found

| button | effect |
|---|---|
| #0 FilledButton "Find key=m3-find" | api:POST /messenger/contacts/lookup, state-change |
| #1 FilledButton "icon:0xe155 / Message key=mr1-msg-found" | snackbar, api:POST /circle/message-request/start, ui-change |
| #2 ChoiceChip "Family key=m3-rel-family" | ui-change |
| #3 ChoiceChip "Friend key=m3-rel-friend" | ui-change |
| #4 ChoiceChip "Colleague key=m3-rel-colleague" | ui-change |
| #5 ChoiceChip "Custom key=m3-rel-custom" | ui-change |
| #6 FilledButton "icon:0xe571 / Send request key=m3-send" | ui-change |
| #7 ListTile "icon:0xef7e / Pick from phone contacts / See which of your contacts ar… key=m3-pick-contacts" | push:page, api:GET /referral/balance, ui-change |
| #8 ListTile "icon:0xe4f6 / Show my QR code / Or share your invite link key=m3-my-qr" | push:dialog, api:GET /circle/invite?relation=friend, ui-change |
| #9 ListTile "icon:0xe380 / Paste an invite link / Someone sent you their My Circle … key=m3-paste" | push:dialog, platform:flutter/platform#Clipboard.getData, ui-change |

## m3_add_notfound

| button | effect |
|---|---|
| #0 FilledButton "Find key=m3-find" | api:POST /messenger/contacts/lookup, state-change |
| #1 FilledButton "icon:0xf3ad / SMS key=m3-invite-sms" | snackbar, api:POST /messenger/invite/share-link, net, ui-change |
| #2 FilledButton "icon:0xef44 / WhatsApp key=m3-invite-whatsapp" | snackbar, api:POST /messenger/invite/share-link, net, ui-change |
| #3 OutlinedButton "icon:0xf378 / Share link key=m3-invite-share" | snackbar, api:POST /messenger/invite/share-link, net, ui-change |
| #4 ListTile "icon:0xef7e / Pick from phone contacts / See which of your contacts ar… key=m3-pick-contacts" | push:page, api:GET /referral/balance, ui-change |
| #5 ListTile "icon:0xe4f6 / Show my QR code / Or share your invite link key=m3-my-qr" | push:dialog, api:GET /circle/invite?relation=friend, ui-change |
| #6 ListTile "icon:0xe380 / Paste an invite link / Someone sent you their My Circle … key=m3-paste" | push:dialog, platform:flutter/platform#Clipboard.getData, ui-change |

## m3_new_chat

| button | effect |
|---|---|
| #0 ListTile "icon:0xe494 / Add to My Circle key=m3-new-add" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 ListTile "icon:0xf0d8 / New group key=m3-new-group" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 ListTile "icon:0xf08a8 / New community key=m3-new-community" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 ListTile "icon:0xf378 / Invite a friend key=m3-new-invite" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #4 IconButton "tip:Search by number, e.g. 01712345678 / icon:0xe49c key=c1-search-go" | ui-change |
| #5 FilledButton "icon:0xe155 / Message key=c1-msg-3" | push:page, api:GET /circle/keys/peer/30 GET /circle/t1/gate?kind=member&id=30 GET /circle/30/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #6 IconButton "tip:Call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/30/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #7 FilledButton "icon:0xe155 / Message key=mr1-msg-4" | snackbar, api:POST /circle/message-request/start, ui-change |
| #8 FilledButton "icon:0xe494 / Add to My Circle key=c1-add-2" | push:sheet, api:GET /rt/events?after=0, net, ui-change |
| #9 IconButton "tip:Message / icon:0xe155 key=mr1-msg-2" | snackbar, api:POST /circle/message-request/start, ui-change |
| #10 TextButton "Invite" | snackbar, api:POST /messenger/invite/sms, net, platform:plugins.flutter.io/url_launcher#canLaunch, ui-change |
| #11 TextButton "Invite" | snackbar, api:POST /messenger/invite/sms, net, platform:plugins.flutter.io/url_launcher#canLaunch, ui-change |
| #12 FilledButton "icon:0xe34d / Share invite link" | api:POST /messenger/invite/share-link, net, platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #13 OutlinedButton "icon:0xf3ad / Invite by SMS" | push:dialog, ui-change |
| #14 TextButton "icon:0xe380 / Copy link" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #15 TextButton "icon:0xf3e3 / See referral points" | push:page, api:GET /referral/balance GET /referral/history, ui-change |
| #16 IconButton "tip:How your privacy is protected / icon:0xf379" | push:sheet, api:GET /rt/events?after=0, net, ui-change |
| #17 IconButton "tip:Connection request / icon:0xf117" | push:page, snackbar, api:GET /messenger/request, net, ui-change |

## m3_requests

| button | effect |
|---|---|
| #0 OutlinedButton "Decline key=m3-decline-41" | snackbar, api:POST /circle/request/41/act, ui-change |
| #1 FilledButton "icon:0xe156 / Accept key=m3-accept-41" | snackbar, api:POST /circle/request/41/act, ui-change |
| #2 OutlinedButton "Decline key=m3-decline-42" | snackbar, api:POST /circle/request/42/act, ui-change |
| #3 FilledButton "icon:0xe156 / Accept key=m3-accept-42" | snackbar, api:POST /circle/request/42/act, ui-change |
| #4 OutlinedButton "icon:0xe16a / Cancel key=m3-cancel-43" | snackbar, api:POST /circle/request/43/act, ui-change |

## cam_perm_ask

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe156 / Continue" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 TextButton "Not now" | pop:page, ui-change |
| #2 IconButton "tip:Close / icon:0xe16a" | pop:page, ui-change |

## cam_perm_denied

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf36e / Open settings" | platform:flutter.baseflow.com/permissions/methods#openAppSettings, ERROR:async: MissingPluginException(No implementation found for method openAppSettings on channel flutter.baseflow.com/permissions/methods) |
| #1 IconButton "tip:Close / icon:0xe16a" | pop:page, ui-change |

## home_top

| button | effect |
|---|---|
| #0 InkWell "icon:0xeeab / Photo Studio / Sharpen and brighten any photo in seconds…" | push:page, api:POST /discover/track GET /photo-studio/config, net, ui-change |
| #1 InkWell "icon:0xf293 / Anti-theft / Protect your phone if it is lost or stolen." | push:page, api:POST /discover/track, net, ui-change |
| #2 TextButton "icon:0xe683 / Edit" | push:sheet, ui-change |
| #3 InkWell "icon:0xee66 / Reminders" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #4 InkWell "icon:0xee33 / Account & Finance" | push:page, ui-change |
| #5 InkWell "icon:0xef4a / Notes/Tasks" | push:page, ui-change |
| #6 InkWell "icon:0xeea9 / Assisto AI" | push:page, ui-change |
| #7 InkWell "icon:0xf089f / Family" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #8 InkWell "icon:0xe3b1 / Documents" | push:page, platform:plugins.it_nomads.com/flutter_secure_storage#read, ui-change, ERROR:async: MissingPluginException(No implementation found for method read on channel plugins.it_nomads.com/flutter_secure_storage) |
| #9 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #10 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #11 IconButton "icon:0xe0a0" | ui-change |
| #12 IconButton "tip:Photo Studio / icon:0xeeab" | push:page, api:GET /photo-studio/config, net, ui-change |
| #13 IconButton "tip:Notifications / icon:0xf237" | push:page, api:GET /notif/reminders POST /notif/opened GET /notif/feed, net, ui-change |
| #14 IconButton "tip:My Circle / icon:0xf08a1" | push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, ui-change |

## enc_backup

| button | effect |
|---|---|
| #1 InkWell "Backup / Tab 1 of 3" | SKIP:already the selected option |
| #0 FilledButton "icon:0xf023 / Create encrypted backup" | ui-change |
| #2 InkWell "Restore / Tab 2 of 3" | ui-change |
| #3 InkWell "Phone transfer / Tab 3 of 3" | ui-change |

## mood

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe156 / Turn on (this phone only)" | ui-change |

## proactive

| button | effect |
|---|---|
| #0 IconButton "tip:Dismiss / icon:0xe16a" | snackbar, api:CREATE proactive/dismissed, net, ui-change |
| #1 TextButton "icon:0xe30b / Why this?" | push:sheet, ui-change |
| #2 FilledButton "Open" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #3 IconButton "tip:Dismiss / icon:0xe16a" | snackbar, api:CREATE proactive/dismissed, net, ui-change |
| #4 TextButton "icon:0xe30b / Why this?" | push:sheet, ui-change |
| #5 FilledButton "Open" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #6 IconButton "tip:Dismiss / icon:0xe16a" | snackbar, api:CREATE proactive/dismissed, net, ui-change |
| #7 TextButton "icon:0xe30b / Why this?" | push:sheet, ui-change |
| #8 FilledButton "Open" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #9 IconButton "tip:Dismiss / icon:0xe16a" | snackbar, api:CREATE proactive/dismissed, net, ui-change |
| #10 TextButton "icon:0xe30b / Why this?" | push:sheet, ui-change |
| #11 FilledButton "Open" | push:page, api:LIST subscriptions, ui-change |
| #12 IconButton "tip:Retry / icon:0xe514" | api:LIST reminders LIST subscriptions LIST proactive/dismissed, state-change |

## area

| button | effect |
|---|---|
| #1 FilterChip "All" | SKIP:already the selected option |
| #0 TextButton "Change area" | push:sheet, ui-change |
| #2 FilterChip "Announcement" | ui-change |
| #3 FilterChip "Local service" | ui-change |
| #4 FilterChip "Lost & found" (scrolled) | ui-change |
| #5 FilterChip "Event" (scrolled) | ui-change |
| #6 FilterChip "Alert" (scrolled) | ui-change |
| #7 FilledButton "icon:0xef27 / Post a notice" | push:sheet, ui-change |
| #8 IconButton "tip:Change area / icon:0xf2ac" | push:sheet, ui-change |

## doctor

| button | effect |
|---|---|
| #1 InkWell "Upcoming / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe047 / Add appointment" | push:sheet, ui-change |
| #2 InkWell "Past / Tab 2 of 2" | ui-change |

## supplier

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add supplier" | push:sheet, ui-change |

## demand

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Log signal" | push:sheet, ui-change |
| #1 FAB "icon:0xe047 / Log signal" | push:sheet, ui-change |

## pa_star_deals

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / New deal" | push:sheet, ui-change |

## pa_vip

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe494 / New contact" | push:page, ui-change |

## pa_letters

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / New document" | push:page, ui-change |
| #1 FAB "icon:0xe047 / New document" | push:page, ui-change |

## pa_voucher

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / New voucher" | push:sheet, ui-change |

## quick_tools

| button | effect |
|---|---|
| #0 ChoiceChip "Summarise" | SKIP:already the selected option |
| #1 ChoiceChip "Fix grammar" | ui-change |
| #2 ChoiceChip "Translate" | ui-change |
| #3 ChoiceChip "Change tone" | ui-change |
| #4 ChoiceChip "Make shareable" | ui-change |
| #5 FilledButton "icon:0xe0b7 / Run" | snackbar, ui-change |

## daily_brief

| button | effect |
|---|---|
| #1 InkWell "Morning / Tab 1 of 2" | SKIP:already the selected option |
| #0 OutlinedButton "icon:0xe34d / Share" | platform:flutter/platform#Clipboard.setData dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #2 InkWell "Night / Tab 2 of 2" | ui-change |

## blog

| button | effect |
|---|---|
| #0 ChoiceChip "Blog post" | SKIP:already the selected option |
| #4 ChoiceChip "Informative" | SKIP:already the selected option |
| #10 ChoiceChip "Medium" | SKIP:already the selected option |
| #14 ChoiceChip "English" | SKIP:already the selected option |
| #16 InkWell "Compose / Tab 1 of 2" | SKIP:already the selected option |
| #1 ChoiceChip "Video script" | ui-change |
| #2 ChoiceChip "Caption" | ui-change |
| #3 ChoiceChip "Outline" | ui-change |
| #5 ChoiceChip "Casual" | ui-change |
| #6 ChoiceChip "Persuasive" | ui-change |
| #7 ChoiceChip "Storytelling" | ui-change |
| #8 ChoiceChip "Professional" | ui-change |
| #9 ChoiceChip "Short" | ui-change |
| #11 ChoiceChip "Long" | ui-change |
| #12 ChoiceChip "Bangla" | ui-change |
| #13 ChoiceChip "Banglish" | ui-change |
| #15 FilledButton "icon:0xe0b7 / Create a draft" | snackbar, ui-change |
| #17 InkWell "Saved / Tab 2 of 2" | ui-change |

## cv_builder

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf00d / Start building" | ui-change |

## doc_scan

| button | effect |
|---|---|
| #0 FilterChip "All" | SKIP:already the selected option |
| #1 FilterChip "NID" | ui-change |
| #2 FilterChip "Passport" | ui-change |
| #3 FilterChip "Certificate" | ui-change |
| #4 FilterChip "Bill" (scrolled) | ui-change |
| #5 FilterChip "Receipt" (scrolled) | ui-change |
| #6 FilterChip "Other" (scrolled) | ui-change |
| #7 FilledButton "icon:0xee39 / Add document" | push:sheet, ui-change |

## transcribe

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add note" | push:sheet, ui-change |

## travel

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / New trip" | push:sheet, ui-change |

## contract

| button | effect |
|---|---|
| #2 InkWell "Analyze / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "icon:0xf013d / Analyze" | snackbar, ui-change |
| #1 OutlinedButton "icon:0xe0f4 / Save" | snackbar, ui-change |
| #3 InkWell "Saved / Tab 2 of 2" | ui-change |

## cost_est

| button | effect |
|---|---|
| #3 InkWell "Estimate / Tab 1 of 2" | SKIP:already the selected option |
| #0 OutlinedButton "icon:0xe047 / Add component" | ui-change |
| #1 FilledButton "icon:0xe0f4 / Save" | snackbar, ui-change |
| #2 OutlinedButton "icon:0xf66c / Copy" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #4 InkWell "Saved / Tab 2 of 2" | ui-change |

## mock_iv

| button | effect |
|---|---|
| #0 ListTile "icon:0xe6f4 / Job / general / icon:0xe15f" | ui-change |
| #1 ListTile "icon:0xe488 / HR / behavioural / icon:0xe15f" | ui-change |
| #2 ListTile "icon:0xe176 / Technical basics / icon:0xe15f" | ui-change |
| #3 ListTile "icon:0xf33c / Viva / academic / icon:0xe15f" | ui-change |

## lang_partner

| button | effect |
|---|---|
| #0 ListTile "icon:0xf0696 / Greetings / 0/5 cards started" | ui-change |
| #1 ListTile "icon:0xf4bc / Daily life / 0/5 cards started" | ui-change |
| #2 ListTile "icon:0xefc4 / Travel / 0/5 cards started" | ui-change |
| #3 ListTile "icon:0xf37d / Shopping / 0/4 cards started" | ui-change |
| #4 ListTile "icon:0xf2aa / Numbers / 0/5 cards started" | ui-change |

## spending

| button | effect |
|---|---|
| #0 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #1 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #2 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #3 FAB "icon:0xe047 / Add category" | push:sheet, ui-change |

## price_radar

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Log price" | push:sheet, ui-change |

## health_tl

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add event" | push:sheet, ui-change |

## wellness

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Log today" | push:sheet, ui-change |

## challenges

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe15a / Mark as done" | snackbar, api:CREATE challenges/progress, net, ui-change |

## saved

| button | effect |
|---|---|
| #0 FilledButton "icon:0xeee0 / Save item" | push:sheet, ui-change |

## kid

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe493 / Add child" | push:sheet, ui-change |

## fitness

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf07b / Set a goal" | push:sheet, ui-change |

## staff

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe494 / Add staff" | push:sheet, ui-change |

## savings

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Start a challenge" | push:sheet, ui-change |

## security

| button | effect |
|---|---|
| #0 ListTile "icon:0xe504 / Phone screen lock / Tap to see the tip" | ui-change |
| #1 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #2 ListTile "icon:0xe504 / App lock / PIN / Tap to see the tip" | ui-change |
| #3 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #4 ListTile "icon:0xe504 / Strong wallet PIN / Tap to see the tip" | ui-change |
| #5 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #6 ListTile "icon:0xe504 / Two-factor on key accounts / Tap to see the tip" | ui-change |
| #7 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #8 ListTile "icon:0xe504 / Strong passwords / Tap to see the tip" | ui-change |
| #9 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #10 ListTile "icon:0xe504 / Backup enabled / Tap to see the tip" | ui-change |
| #11 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #12 ListTile "icon:0xe504 / Scam awareness / Tap to see the tip" | ui-change |
| #13 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #14 ListTile "icon:0xe504 / App permissions review / Tap to see the tip" | ui-change |
| #15 Switch "" | snackbar, api:CREATE security/checklist, net, ui-change |
| #16 IconButton "tip:Reset checklist? / icon:0xe531" | push:dialog, ui-change |

## farmer

| button | effect |
|---|---|
| #1 InkWell "icon:0xe063 / Ledger / Tab 1 of 3" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe047 / Add crop" | push:sheet, ui-change |
| #2 InkWell "icon:0xf06bb / Crop calendar / Tab 2 of 3" | ui-change |
| #3 InkWell "icon:0xe4a1 / Livestock / Tab 3 of 3" | ui-change |

## trust

| button | effect |
|---|---|
| #0 ListTile "icon:0xe4d9 / Privacy policy & terms / icon:0xe15f" | push:page, api:GET /legal, ui-change |
| #1 ListTile "icon:0xe33d / About Assisto / icon:0xe15f" | push:page, api:GET /name/about, ui-change |

## blood

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe494 / Add donor" | push:sheet, ui-change |

## meter

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add meter" | push:sheet, ui-change |

## qurbani

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / New plan" | push:sheet, ui-change |

## probashi

| button | effect |
|---|---|
| #1 InkWell "Remittance log / Tab 1 of 3" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe047 / Log a send" | push:sheet, ui-change |
| #2 InkWell "Clock / Tab 2 of 3" | ui-change |
| #3 InkWell "Documents / Tab 3 of 3" | ui-change |

## student

| button | effect |
|---|---|
| #0 FilledButton "icon:0xef10 / Add course" | push:sheet, ui-change |

## wedding

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe23e / Set event" | push:sheet, ui-change |

## task_mgr

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Create your first project" | push:sheet, ui-change |

## mess_acct

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe494 / Add member" | push:sheet, ui-change |

## expense_split

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe494 / Add person" | push:sheet, ui-change |

## samity

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / New samity" | push:sheet, ui-change |

## landlord

| button | effect |
|---|---|
| #8 InkWell "This month / Tab 1 of 2" | SKIP:already the selected option |
| #0 IconButton "icon:0xe15e" | ui-change |
| #1 IconButton "icon:0xe15f" | ui-change |
| #2 ListTile "Flat 1A / Tenant 1 / icon:0xe159" | ui-change |
| #3 ListTile "Flat 2A / Tenant 2 / icon:0xe159" | ui-change |
| #4 ListTile "Flat 3A / Tenant 3 / icon:0xe159" | ui-change |
| #5 ListTile "Flat 4A / Tenant 4 / icon:0xe660" | ui-change |
| #6 ListTile "Flat 5A / Tenant 5 / icon:0xe660" | ui-change |
| #7 ListTile "Flat 6A / Tenant 6 / icon:0xe238" | ui-change |
| #9 InkWell "Arrears / Tab 2 of 2" | ui-change |
| #10 FAB "icon:0xf06d6 / Add unit" | push:sheet, ui-change |

## pa_hub

| button | effect |
|---|---|
| #0 InkWell "icon:0xf051f / Schedule control / icon:0xe15f" | push:page, api:LIST pa_schedule, ui-change |
| #1 InkWell "icon:0xf117 / Visitors & Appointments / icon:0xe15f" | push:page, api:LIST pa/visitors, ui-change |
| #2 InkWell "icon:0xf094 / Liaison & Follow-up / icon:0xe15f" | push:page, api:LIST pa/followups, ui-change |
| #3 InkWell "icon:0xef4a / Personal task oversight / icon:0xe15f" | push:page, ui-change |
| #4 InkWell "icon:0xee53 / Delegate access / icon:0xe15f" | push:page, ui-change |
| #5 InkWell "icon:0xef7b / Calls & emails / icon:0xe15f" | push:page, api:LIST pa/callemail, ui-change |
| #6 InkWell "icon:0xe3c4 / Letters, notices & memos / icon:0xe15f" | push:page, api:LIST pa/letters, ui-change |
| #7 InkWell "icon:0xf091 / Filing Cabinet / icon:0xe15f" | push:page, api:LIST pa/filing, ui-change |
| #8 InkWell "icon:0xf3e8 / Meeting Minutes / icon:0xe15f" | push:page, api:LIST pa/minutes, ui-change |
| #9 InkWell "icon:0xf085 / Travel & itinerary / icon:0xe15f" | push:page, api:LIST pa/travel, ui-change |
| #10 InkWell "icon:0xf2ef / Expense voucher / icon:0xe15f" | push:page, api:LIST pa/vouchers, ui-change |
| #11 InkWell "icon:0xf12a / Research & presentation / icon:0xe15f" | push:page, api:LIST pa/research, ui-change |
| #12 InkWell "icon:0xefa0 / Board meeting pack / icon:0xe15f" | push:page, api:LIST pa/board, ui-change |
| #13 InkWell "icon:0xf3ff / Departmental update / icon:0xe15f" | push:page, api:LIST pa/deptupdates, ui-change |
| #14 InkWell "icon:0xf3e3 / VIP & stakeholders / icon:0xe15f" | push:page, api:LIST pa/vip, ui-change |
| #15 InkWell "icon:0xef0a / Business travel & events / icon:0xe15f" | push:page, api:LIST pa/bizevents, ui-change |
| #16 InkWell "icon:0xee36 / Project tracking / icon:0xe15f" | push:page, api:LIST pa/projects LIST pa/milestones, ui-change |
| #17 InkWell "icon:0xf06a4 / Deals & offers / icon:0xe15f" | push:page, api:LIST star/deals, ui-change |
| #18 InkWell "icon:0xef27 / PR & press / icon:0xe15f" | push:page, api:LIST star/press, ui-change |
| #19 InkWell "icon:0xf0b0 / Social inbox / icon:0xe15f" | push:page, api:LIST star/socialinbox, ui-change |
| #20 InkWell "icon:0xf1f5 / Shooting & concert logistics / icon:0xe15f" | push:page, api:LIST star/callsheets, ui-change |
| #21 InkWell "icon:0xf3bb / Lifestyle / icon:0xe15f" | push:page, api:LIST star/lifestyle, ui-change |

## pa_schedule

| button | effect |
|---|---|
| #0 IconButton "tip:Previous / icon:0xe15e" | ui-change |
| #1 GestureDetector "Fri, 23 Oct" | state-change |
| #2 IconButton "tip:Next / icon:0xe15f" | ui-change |
| #3 FilledButton "icon:0xe047 / Add your first slot" | push:sheet, ui-change |

## pa_visitor

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe494 / Add request" | push:sheet, ui-change |

## pa_liaison

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add follow-up" | push:sheet, ui-change |

## pa_tasks

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add task" | push:sheet, ui-change |

## pa_delegate

| button | effect |
|---|---|
| #1 InkWell "Permissions / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "icon:0xf00a0 / Start with least privilege" | ui-change |
| #2 InkWell "Access log / Tab 2 of 2" | ui-change |

## msg_privacy

| button | effect |
|---|---|
| #0 RadioListTile "My circle only / People in your circle message you directly. Anyone el…" | SKIP:already the selected option |
| #1 RadioListTile "Everyone (strangers go to requests) / Anyone can message you, communit…" | push:dialog, ui-change |
| #2 SwitchListTile "icon:0xf289 / Hide my number from non-contacts / People outside your c…" | ui-change |

## ai_knowledge

| button | effect |
|---|---|
| #0 ListTile "icon:0xf04f6 / Home wifi password: *** / Added by you" | ui-change |
| #1 ListTile "icon:0xe0b7 / Car insurance ends in November / AI detected" | ui-change |
| #2 IconButton "tip:Clear everything / icon:0xefab" | push:dialog, ui-change |

## cost_flags

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe514 / Retry" | api:GET /admin/flags, net, state-change |

## discover_mgr

| button | effect |
|---|---|
| #0 InkWell "icon:0xf37d / Fresh Market / Sponsored" | push:page, ui-change |
| #1 Switch "" | snackbar, api:PATCH /admin/discover/cards/20, net, ui-change |
| #2 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #3 InkWell "icon:0xeeab / Photo Studio / Assisto feature" | push:page, ui-change |
| #4 Switch "" | snackbar, api:PATCH /admin/discover/cards/1, net, ui-change |
| #5 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #6 InkWell "icon:0xf293 / Anti-theft / Assisto feature" | push:page, ui-change |
| #7 Switch "" | snackbar, api:PATCH /admin/discover/cards/2, net, ui-change |
| #8 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #9 InkWell "icon:0xf3ef / Asalify / Our product" | push:page, ui-change |
| #10 Switch "" | snackbar, api:PATCH /admin/discover/cards/9, net, ui-change |
| #11 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #12 InkWell "icon:0xef27 / AdMob slot / AdMob slot" | push:page, ui-change |
| #13 Switch "" | snackbar, api:PATCH /admin/discover/cards/30, net, ui-change |
| #14 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #15 IconButton "tip:Preview / icon:0xf4a1" | push:sheet, api:GET /admin/discover/preview?segment=free, ui-change |
| #16 IconButton "tip:Refresh / icon:0xe514" | api:GET /admin/discover/cards, state-change |
| #17 FAB "icon:0xe047 / Add card" | push:page, ui-change |

## discover_edit

| button | effect |
|---|---|
| #0 DropdownButton "Assisto feature / Our product / Sponsored" | push:popup, ui-change |
| #1 DropdownButton "shopping bag / icon:0xf37d / star" | push:popup, ui-change |
| #2 OutlinedButton "icon:0xf120 / Upload image" | platform:plugins.flutter.io/image_picker#pickImage, ui-change |
| #3 DropdownButton "Everyone / Free / Premium" | push:popup, ui-change |
| #4 ListTile "icon:0xf02f / Starts / Not set" | push:dialog, ui-change |
| #5 ListTile "icon:0xf02f / Ends / Not set" | push:dialog, ui-change |
| #6 SwitchListTile "Show this card" | ui-change |
| #7 FilledButton "icon:0xe156 / Save" | api:PATCH /admin/discover/cards/20, net, ui-change |
| #8 IconButton "tip:Report / icon:0xf132" | push:page, api:GET /admin/discover/cards/20/report?days=30, ui-change |

## discover_report

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xf41f / Export CSV" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #1 OutlinedButton "icon:0xf2a4 / Export PDF" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |

## server_addr

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe424 / Test connection" | snackbar, ui-change |
| #1 FilledButton "icon:0xf334 / Save" | snackbar, ui-change |

## app_update

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe514 / Retry" | net, platform:dev.fluttercommunity.plus/package_info#getAll, state-change |

## about

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf41a / Check for updates" | net, ui-change |

## support_center

| button | effect |
|---|---|
| #0 ChoiceChip "General help" | SKIP:already the selected option |
| #10 InkWell "Get help / Tab 1 of 2" | SKIP:already the selected option |
| #1 ChoiceChip "Report a bug" | ui-change |
| #2 ChoiceChip "Account" | ui-change |
| #3 ChoiceChip "Payment" | ui-change |
| #4 FilledButton "icon:0xf355 / Send" | snackbar, ui-change |
| #5 ListTile "icon:0xe30b / Why aren't my reminders arriving on time? / icon:0xe246" | ui-change |
| #6 ListTile "icon:0xe30b / How do I back up or export my data? / icon:0xe246" | ui-change |
| #7 ListTile "icon:0xe30b / Can I delete my account? / icon:0xe246" | ui-change |
| #8 ListTile "icon:0xf018 / Email us / support@assisto.app" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #9 ListTile "icon:0xf0c0 / Terms & privacy / icon:0xe15f" | push:page, api:GET /legal, ui-change |
| #11 InkWell "My tickets / Tab 2 of 2" | api:LIST support, ui-change |

## social

| button | effect |
|---|---|
| #0 ChoiceChip "Facebook / icon:0xe255" | SKIP:already the selected option |
| #4 ChoiceChip "Friendly" | SKIP:already the selected option |
| #10 ChoiceChip "Medium" | SKIP:already the selected option |
| #14 ChoiceChip "English" | SKIP:already the selected option |
| #16 InkWell "Compose / Tab 1 of 2" | SKIP:already the selected option |
| #1 ChoiceChip "Instagram / icon:0xf29b" | ui-change |
| #2 ChoiceChip "LinkedIn / icon:0xe6f4" | ui-change |
| #3 ChoiceChip "WhatsApp status / icon:0xe155" | ui-change |
| #5 ChoiceChip "Professional" | ui-change |
| #6 ChoiceChip "Funny" | ui-change |
| #7 ChoiceChip "Inspirational" | ui-change |
| #8 ChoiceChip "Promotional" | ui-change |
| #9 ChoiceChip "Short" | ui-change |
| #11 ChoiceChip "Long" | ui-change |
| #12 ChoiceChip "Bangla" | ui-change |
| #13 ChoiceChip "Banglish" | ui-change |
| #15 FilledButton "icon:0xe0b7 / Draft it" | snackbar, ui-change |
| #17 InkWell "Saved / Tab 2 of 2" | ui-change |

## admin_users

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #1 ChoiceChip "Active / icon:0xe15a" | api:GET /admin/users?status=active, net, ui-change |
| #2 ChoiceChip "Suspended / icon:0xe47f" | api:GET /admin/users?status=suspended, net, ui-change |
| #3 ChoiceChip "Banned / icon:0xe0e1" | api:GET /admin/users?status=banned, net, ui-change |
| #4 FilledButton "Try again" | api:GET /admin/users, net, state-change |

## admin_mod

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #1 ChoiceChip "Severe / icon:0xe4ec" | api:GET /admin/moderation/queue?filter=severe, net, ui-change |
| #2 ChoiceChip "Legal retention / icon:0xee32" | api:GET /admin/moderation/queue?filter=legal, net, ui-change |
| #3 ChoiceChip "Appeals / icon:0xf0c0" (scrolled) | api:GET /admin/moderation/queue?filter=appeals, net, ui-change |
| #4 FilledButton "Try again" | api:GET /admin/moderation/queue, net, state-change |

## money_budget

| button | effect |
|---|---|
| #1 InkWell "This month / Tab 1 of 3" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe047 / Add your first budget" | push:dialog, ui-change |
| #2 InkWell "History / Tab 2 of 3" | api:GET /money/budget/month?month=2026-10, net, ui-change |
| #3 InkWell "Plan / Tab 3 of 3" | api:GET /money/budget/plan?months=3&buffer=10, net, ui-change |

## money_tax

| button | effect |
|---|---|
| #4 InkWell "Income tax / Tab 1 of 3" | SKIP:already the selected option |
| #0 DropdownButton "2024-2025 / 2025-2026 / Tax year (assessment year)" | push:popup, ui-change |
| #1 DropdownButton "General / Woman / senior (65+) / Person with disability" | push:popup, ui-change |
| #2 DropdownButton "Dhaka / Chattogram city / Other city corporation / Outside city corpor…" | push:popup, ui-change |
| #3 FilledButton "Estimate tax" | ui-change |
| #5 InkWell "Zakat / Tab 2 of 3" | ui-change |
| #6 InkWell "File return / Tab 3 of 3" | ui-change |

## money_wrapped

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe34d / Share this card" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## money_voice

| button | effect |
|---|---|
| #0 GestureDetector "icon:0xe3e1" | push:dialog, ui-change |

## voice_assistant

| button | effect |
|---|---|
| #0 ActionChip "Call Ammu / icon:0xe3e4" | platform:flutter.baseflow.com/permissions/methods#checkPermissionStatus com.assisto/voice#speak, ui-change |
| #1 ActionChip "YouTube-e Asif-er Amar Priya gaan ta play koro / icon:0xe3e4" | api:GET /voice/youtube?q=amar+priya+asif, net, platform:com.assisto/voice#musicApps com.assisto/voice#youtubeSearch plugins.flutter.io/url_launcher#launch, ui-change |
| #2 ActionChip "Set an alarm for 6:30 am / icon:0xe3e4" | platform:com.assisto/voice#setAlarm com.assisto/voice#speak, ui-change |
| #3 ActionChip "500 taka groceries expense / icon:0xe3e4" | platform:com.assisto/voice#speak, ui-change |
| #4 ActionChip "Torch on / icon:0xe3e4" | platform:com.assisto/voice#torch com.assisto/voice#speak, ui-change |
| #5 ActionChip "Text Rakib I am coming / icon:0xe3e4" | platform:flutter.baseflow.com/permissions/methods#checkPermissionStatus com.assisto/voice#speak, ui-change |
| #6 IconButton "tip:Type instead / icon:0xf144" | ui-change |
| #7 GestureDetector "icon:0xe3e1" | push:dialog, platform:com.assisto/voice#stopSpeaking, ui-change |
| #8 IconButton "tip:Stop speaking / icon:0xf4a7" | platform:com.assisto/voice#stopSpeaking |
| #9 IconButton "tip:Close / icon:0xe16a" | pop:page, platform:com.assisto/voice#stopSpeaking, ui-change |
| #10 IconButton "tip:Voice assistant / icon:0xe683" | push:page, api:GET /voice/config, net, platform:com.assisto/voice#ping, ui-change |

## voice_listening

| button | effect |
|---|---|
| #0 IconButton "tip:Type instead / icon:0xf144" | ui-change |
| #1 GestureDetector "" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "tip:Stop speaking / icon:0xf4a7" | platform:com.assisto/voice#stopSpeaking |
| #3 IconButton "tip:Close / icon:0xe16a" | pop:page, platform:com.assisto/voice#stopSpeaking, ui-change |
| #4 IconButton "tip:Voice assistant / icon:0xe683" | push:page, api:GET /voice/config, net, platform:com.assisto/voice#ping, ui-change |

## voice_results

| button | effect |
|---|---|
| #0 TextButton "icon:0xe68c / Undo" | ui-change |
| #1 TextButton "icon:0xe68c / Undo" | ui-change |
| #2 TextButton "icon:0xe294 / Turn off" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 IconButton "tip:Type instead / icon:0xf144" | ui-change |
| #4 GestureDetector "icon:0xe3e1" | push:dialog, platform:com.assisto/voice#stopSpeaking, ui-change |
| #5 IconButton "tip:Stop speaking / icon:0xf4a7" | platform:com.assisto/voice#stopSpeaking |
| #6 IconButton "tip:Close / icon:0xe16a" | pop:page, platform:com.assisto/voice#stopSpeaking, ui-change |
| #7 IconButton "tip:Voice assistant / icon:0xe683" | push:page, api:GET /voice/config, net, platform:com.assisto/voice#ping, ui-change |

## voice_confirm

| button | effect |
|---|---|
| #0 InkWell "icon:0xe503 / Ammu / 01711-000000" | SKIP:already the selected option |
| #1 InkWell "icon:0xe504 / Ammu (office) / 01811-000000" | ui-change |
| #2 OutlinedButton "Cancel" | pop:page, ui-change |
| #3 FilledButton "Call" | pop:page, ui-change |

## voice_sos_confirm

| button | effect |
|---|---|
| #0 OutlinedButton "Cancel" | pop:page, ui-change |
| #1 FilledButton "Start SOS" | pop:page, ui-change |

## voice_settings

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe45c / Open settings" | snackbar, platform:com.assisto/voice#openAssistantSettings, ui-change |
| #1 Switch "" | ui-change |
| #2 TextButton "icon:0xeff2 / Install or change the Bangla voice" | snackbar, platform:com.assisto/voice#openTtsSettings, ui-change |

## voice_onboarding

| button | effect |
|---|---|
| #0 FilledButton "icon:0xee9d / Open settings" | snackbar, platform:com.assisto/voice#openAssistantSettings, ui-change |

## action_center

| button | effect |
|---|---|
| #2 InkWell "Waiting / Tab 1 of 2" | SKIP:already the selected option |
| #0 TextButton "Change autonomy level" | snackbar, ui-change |
| #1 FilledButton "icon:0xe514 / Retry" | api:GET /actions/pending, net, state-change, ERROR:async: ClientException with SocketException: network disabled in dead-button sweep, uri=https://api.lifeassisto.com/api/v1/actions/pending |
| #3 InkWell "Done / Tab 2 of 2" | ui-change |

## disaster_alerts

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe15c / What to do" | push:sheet, ui-change |
| #1 OutlinedButton "icon:0xf378 / Share" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #2 FilledButton "icon:0xe15c / What to do" | push:sheet, ui-change |
| #3 OutlinedButton "icon:0xf378 / Share" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #4 FilledButton "icon:0xe15c / What to do" | push:sheet, ui-change |
| #5 OutlinedButton "icon:0xf378 / Share" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #6 ActionChip "Cyclone / icon:0xf0797" | push:sheet, ui-change |
| #7 ActionChip "Flood / icon:0xf0695" | push:sheet, ui-change |
| #8 ActionChip "Heatwave / icon:0xe656" | push:sheet, ui-change |
| #9 ActionChip "Earthquake / icon:0xe6a0" | push:sheet, ui-change |
| #10 FilledButton "icon:0xe126 / 999" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #11 FilledButton "icon:0xe126 / 1090" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #12 IconButton "tip:Refresh / icon:0xe514" | api:GET /disaster/feed LIST family, net, state-change |

## offline_status

| button | effect |
|---|---|
| #0 IconButton "tip:Clear all caches / icon:0xefab" | snackbar, ui-change |

## safe_arrival

| button | effect |
|---|---|
| #0 FilledButton "Set a check-in" | push:sheet, ui-change |
| #1 TextButton "icon:0xe047 / Add routine" | push:dialog, ui-change |

## password_reset

| button | effect |
|---|---|
| #0 ListTile "icon:0xf018 / Email me a link / Available now — we'll send a reset lin…" | state-change |
| #1 FilledButton "icon:0xf355 / Send reset link" | ui-change |
| #2 TextButton "icon:0xf4aa / I already have a code or link" | push:page, ui-change |

## otp_sms_off

| button | effect |
|---|---|
| #0 OutlinedButton "Close" | pop:page, ui-change |

## otp_login

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf3ad / Send code key=otp-send" | ui-change |

## otp_reset

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf3ad / Send code key=otp-send" | ui-change |

## password_reset_sms

| button | effect |
|---|---|
| #0 ListTile "icon:0xf018 / Email me a link / Available now — we'll send a reset lin…" | state-change |
| #1 ListTile "icon:0xf3ad / Text me a code / Get a code by SMS on your registered nu…" | push:page, ui-change |
| #2 FilledButton "icon:0xf355 / Send reset link" | ui-change |
| #3 TextButton "icon:0xf4aa / I already have a code or link" | push:page, ui-change |

## name_about

| button | effect |
|---|---|
| #0 CheckboxListTile "Search the name in the BD DPDT database." | ui-change |
| #1 CheckboxListTile "Consult a trademark attorney before filing." | ui-change |
| #2 InkWell "Bangladesh DPDT — official trademark portal, http://www.dpdt.gov.bd/ /…" | snackbar, platform:plugins.flutter.io/url_launcher#launch flutter/platform#Clipboard.setData, ui-change |
| #3 IconButton "tip:Copy / icon:0xe190" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #4 InkWell "WIPO Global Brand Database, https://branddb.wipo.int/ / icon:0xe45c / …" | snackbar, platform:plugins.flutter.io/url_launcher#launch flutter/platform#Clipboard.setData, ui-change |
| #5 IconButton "tip:Copy / icon:0xe190" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #6 ListTile "icon:0xf2dd / Is the name 'Assisto' legally cleared? / icon:0xe246" | ui-change |
| #7 ListTile "icon:0xf2dd / Why do classes 9 and 42 matter? / icon:0xe246" | ui-change |
| #8 ListTile "icon:0xf2dd / How do I search the Bangladesh trademark database? / ico…" | ui-change |
| #9 ListTile "icon:0xf2dd / Do I really need a trademark attorney? / icon:0xe246" | ui-change |
| #10 ListTile "icon:0xf2dd / What about outside Bangladesh? / icon:0xe246" | ui-change |
| #11 ListTile "icon:0xf2dd / What if the name turns out to be taken? / icon:0xe246" | ui-change |

## owner_analytics

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #1 ChoiceChip "7 days" | ui-change |
| #2 ChoiceChip "30 days" | ui-change |
| #3 ChoiceChip "90 days" | ui-change |
| #4 IconButton "tip:Export (CSV) / icon:0xf138" | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |

## payment_ladder

| button | effect |
|---|---|
| #7 InkWell "Owed to me / Tab 1 of 2" | SKIP:already the selected option |
| #0 InkWell "R / Rahim Store / ৳4,000 left" | push:sheet, ui-change |
| #1 FilledButton "Do this step" | push:sheet, ui-change |
| #2 TextButton "icon:0xe15a / Mark paid" | push:dialog, ui-change |
| #3 TextButton "icon:0xe5cc / Snooze" | snackbar, api:UPDATE ladder-receivable, net, ui-change |
| #4 InkWell "K / Karim Bhai / ৳1,500 left" | push:sheet, ui-change |
| #5 TextButton "icon:0xe15a / Mark paid" | push:dialog, ui-change |
| #6 TextButton "icon:0xe5cc / Snooze" | snackbar, api:UPDATE ladder-receivable, net, ui-change |
| #8 InkWell "I owe / Tab 2 of 2" | ui-change |
| #9 FAB "icon:0xe047 / Add a due" | push:sheet, ui-change |

## elderly_home

| button | effect |
|---|---|
| #0 InkWell "icon:0xf07c7 / Emergency help / One tap alerts family and 999" | push:page, ui-change |
| #1 InkWell "icon:0xe126 / Call family / 2 saved" | push:sheet, ui-change |
| #2 InkWell "icon:0xe3d9 / My medicines / 3 due today" | push:page, ui-change |
| #3 InkWell "icon:0xe154 / Messages" | push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, ui-change |
| #4 InkWell "icon:0xe041 / Money" | push:page, ui-change |
| #5 InkWell "icon:0xe30b / Help / Learn how to use the app" | push:page, ui-change |
| #6 InkWell "icon:0xe3e1" | push:sheet, ui-change |
| #7 TextButton "icon:0xe16a / Exit simple" | push:dialog, ui-change |

## chat

| button | effect |
|---|---|
| #0 TextButton "icon:0xe68c / Undo" | net |
| #1 TextButton "icon:0xe68c / Undo" | net |
| #2 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #3 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #4 IconButton "icon:0xe0a0" | ui-change |

## chat_voice

| button | effect |
|---|---|
| #0 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #1 IconButton "tip:Tap to stop / icon:0xe607" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xe0a0" | ui-change |

## drawer

| button | effect |
|---|---|
| #0 ListTile "icon:0xe0b7 / Assisto AI / New chat and all your chats key=drawer_assisto_ai" | pop:page+push:page, ui-change |
| #1 ListTile "icon:0xf08a1 / My Circle" | pop:page+push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, ui-change |
| #2 ListTile "icon:0xf234 / Reminders & Memory / icon:0xe246" | ui-change |
| #3 ListTile "icon:0xee33 / Account & Finance / icon:0xe246" | SKIP:tree not stable between pumps |
| #4 ListTile "icon:0xf089f / Family & Safety / icon:0xe246" | SKIP:tree not stable between pumps |
| #5 ListTile "icon:0xef7e / Contacts" | SKIP:tree not stable between pumps |
| #6 ListTile "icon:0xeea9 / Daily Life / icon:0xe246" | SKIP:tree not stable between pumps |
| #7 ListTile "icon:0xe6f4 / Work / icon:0xe246" | SKIP:tree not stable between pumps |
| #8 ListTile "icon:0xf3ef / Business / icon:0xe246" | SKIP:tree not stable between pumps |
| #9 ListTile "icon:0xf36e / Settings" | SKIP:tree not stable between pumps |
| #10 ListTile "icon:0xf06a1 / Plans & points" | SKIP:tree not stable between pumps |

## assisto_chats

| button | effect |
|---|---|
| #0 FilledButton "icon:0xee41 / New chat key=chats_new_chat" | push:page, ui-change |
| #1 ListTile "icon:0xe155 / Call mom tomorrow morning / Home chat · 3d ago key=chat_row_11" | push:page, ui-change |
| #2 PopupMenuButton "tip:Chat history / icon:0xe404 key=chat_menu_11" | push:popup, ui-change |
| #3 ListTile "icon:0xe155 / This month's spending / Home chat · 3d ago key=chat_row_12" | push:page, ui-change |
| #4 PopupMenuButton "tip:Chat history / icon:0xe404 key=chat_menu_12" | push:popup, ui-change |
| #5 ListTile "icon:0xe0b7 / Write a shop offer post / Assisto AI · 5d ago key=chat_row_13" | push:page, ui-change |
| #6 PopupMenuButton "tip:Chat history / icon:0xe404 key=chat_menu_13" | push:popup, ui-change |
| #7 ListTile "icon:0xe155 / When is the electricity bill due / Home chat · 6d ago key=chat_row_14" | push:page, ui-change |
| #8 PopupMenuButton "tip:Chat history / icon:0xe404 key=chat_menu_14" | push:popup, ui-change |
| #9 ListTile "icon:0xe0b7 / Job application letter / Assisto AI · 8d ago key=chat_row_15" | push:page, ui-change |
| #10 PopupMenuButton "tip:Chat history / icon:0xe404 key=chat_menu_15" | push:popup, ui-change |

## assisto_chats_empty

| button | effect |
|---|---|
| #0 FilledButton "icon:0xee41 / New chat key=chats_new_chat" | push:page, ui-change |

## home_chat_restored

| button | effect |
|---|---|
| #0 ActionChip "Reminders / icon:0xee66" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #1 ActionChip "Account & Finance / icon:0xee33" | push:page, ui-change |
| #2 ActionChip "Notes/Tasks / icon:0xef4a" | push:page, ui-change |
| #3 ActionChip "Assisto AI / icon:0xeea9" (scrolled) | push:page, ui-change |
| #4 ActionChip "Family / icon:0xf089f" | SKIP:could not scroll it into view |
| #5 TextButton "icon:0xe68c / Undo" | net |
| #6 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #7 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #8 IconButton "icon:0xe0a0" | ui-change |

## quick_grid

| button | effect |
|---|---|
| #0 TextButton "icon:0xe683 / Edit" | push:sheet, ui-change |
| #1 InkWell "icon:0xee66 / Reminders" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #2 InkWell "icon:0xee33 / Account & Finance" | push:page, ui-change |
| #3 InkWell "icon:0xef4a / Notes/Tasks" | push:page, ui-change |
| #4 InkWell "icon:0xeea9 / Assisto AI" | push:page, ui-change |
| #5 InkWell "icon:0xf089f / Family" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #6 InkWell "icon:0xe3b1 / Documents" | push:page, platform:plugins.it_nomads.com/flutter_secure_storage#read, ui-change, ERROR:async: MissingPluginException(No implementation found for method read on channel plugins.it_nomads.com/flutter_secure_storage) |

## quick_grid_owner

| button | effect |
|---|---|
| #0 TextButton "icon:0xe683 / Edit" | push:sheet, ui-change |
| #1 InkWell "icon:0xf05f4 / Emergency" | push:page, ui-change |
| #2 InkWell "icon:0xee33 / Account & Finance" | push:page, ui-change |
| #3 InkWell "icon:0xee66 / Reminders" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #4 InkWell "icon:0xf0c8 / Scam protection" | push:page, ui-change |
| #5 InkWell "icon:0xf2ac / Nearby" | push:page, platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, ui-change |
| #6 InkWell "icon:0xef4a / Notes/Tasks" | push:page, ui-change |

## quick_picker

| button | effect |
|---|---|
| #0 CheckboxListTile "icon:0xee66 / Reminders" | ui-change |
| #1 CheckboxListTile "icon:0xee33 / Account & Finance" | ui-change |
| #2 CheckboxListTile "icon:0xef4a / Notes/Tasks" | ui-change |
| #3 CheckboxListTile "icon:0xeea9 / Assisto AI" | ui-change |
| #4 CheckboxListTile "icon:0xf089f / Family" | ui-change |
| #5 CheckboxListTile "icon:0xe3b1 / Documents" | ui-change |
| #6 TextButton "Reset" | state-change |
| #7 FilledButton "Save" | pop:page, ui-change |

## messenger

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #5 ListTile "tip:Discover / icon:0xe047 / Status / icon:0xf037" | SKIP:not hittable (covered/zero-size) |
| #6 IconButton "tip:Discover / icon:0xf037" | SKIP:not hittable (covered/zero-size) |
| #8 IconButton "tip:Discover / icon:0xf037" | SKIP:not hittable (covered/zero-size) |
| #9 FAB "icon:0xe047 / Create channel" | SKIP:not hittable (covered/zero-size) |
| #1 ChoiceChip "Unread" | ui-change |
| #2 ChoiceChip "Favourites" | ui-change |
| #3 ChoiceChip "Groups" | ui-change |
| #4 FilledButton "icon:0xe494 / Add to My Circle key=m3-empty-add" | push:page, ui-change |
| #7 FilledButton "icon:0xe047 / Create channel" | SKIP:could not scroll it into view |
| #10 IconButton "tip:Call back / icon:0xe126" | SKIP:could not scroll it into view |
| #11 IconButton "tip:Call back / icon:0xe126" | SKIP:could not scroll it into view |
| #12 IconButton "tip:Status or photo / icon:0xf29b" | push:page, platform:flutter.baseflow.com/permissions/methods#checkPermissionStatus, ui-change, ERROR:async: MissingPluginException(No implementation found for method checkPermissionStatus on channel flutter.baseflow.com/permissions/methods) |
| #13 PopupMenuButton "tip:More / icon:0xe404 key=m3-hub-menu" | push:popup, ui-change |
| #14 InkWell "tip:Chats / icon:0xe2c3 / Chats" | state-change |
| #15 InkWell "tip:Updates / icon:0xeea9 / Updates" | ui-change |
| #16 InkWell "tip:Community / icon:0xf08a8 / Community" | ui-change |
| #17 InkWell "tip:Calls / icon:0xef1a / Calls" | ui-change |
| #18 FAB "tip:New chat / icon:0xef44 key=m3-fab" | push:page, api:GET /referral/balance, ui-change |

## messenger_settings

| button | effect |
|---|---|
| #0 ListTile "A / Arif / 01712345678" | push:page, api:GET /me, net, ui-change |
| #1 ListTile "icon:0xf0624 / Account / Security, data, delete account" | push:page, ui-change |
| #2 ListTile "icon:0xe3b1 / Privacy / Last seen, online, read receipts, who can see" | push:page, ui-change |
| #3 ListTile "icon:0xef44 / Chats / Your conversations" | push:page, ui-change |
| #4 ListTile "icon:0xf237 / Notifications / Message and call alerts" | push:page, api:GET /circle/settings/notifications, platform:com.assisto/c3_messaging#bubblesSupported, ui-change |
| #5 ListTile "icon:0xef1a / Calls / Incoming calls, silence unknown" | push:page, api:GET /circle/settings/calls, ui-change |
| #6 ListTile "icon:0xefa4 / Storage & data / Usage & media auto-download" | push:page, api:GET /circle/settings/storage, ui-change |
| #7 ListTile "icon:0xf14f / Language / English" | push:sheet, ui-change |
| #8 ListTile "icon:0xe30b / Help / Report a problem or send feedback" | push:page, ui-change |
| #9 ListTile "icon:0xef2d / Invite a friend / Share your invite code" | push:dialog, ui-change |

## contact_info

| button | effect |
|---|---|
| #0 ListTile "icon:0xe5fd / Starred messages / 0" | push:page, api:GET messenger/starred, net, ui-change |
| #1 SwitchListTile "icon:0xf236 / Mute" | push:sheet, ui-change |
| #2 ListTile "icon:0xf44a / Disappearing messages / Off" | push:sheet, ui-change |
| #3 ListTile "icon:0xf1fb / Custom ringtone / Same as my ringtone key=sound-contact" | platform:com.assisto/calls#pickSound |
| #4 ListTile "icon:0xe0e1 / Block" | api:POST /circle/1/controls, ui-change |
| #5 ListTile "icon:0xf07b / Report" | push:sheet, ui-change |

## money

| button | effect |
|---|---|
| #4 InkWell "Summary / Tab 1 of 5" | SKIP:already the selected option |
| #0 ListTile "icon:0xf132 / Trends / Month-over-month and per-category" | push:page, ui-change |
| #1 ListTile "icon:0xe4c5 / Net worth / Assets, receivables and liabilities" | push:page, ui-change |
| #2 IconButton "tip:Import from SMS / icon:0xf3ad" | push:page, ui-change |
| #3 IconButton "icon:0xe62f" | state-change |
| #5 InkWell "Accounts / Tab 2 of 5" | ui-change |
| #6 InkWell "Transaction / Tab 3 of 5" | ui-change |
| #7 InkWell "Budget / Tab 4 of 5" | ui-change |
| #8 InkWell "Loans and Savings / Tab 5 of 5" | ui-change |

## vault

| button | effect |
|---|---|
| #0 ListTile "icon:0xf1c2 / Passport / Passport" | push:sheet, ui-change |
| #1 ListTile "icon:0xeeb8 / NID / NID" | push:sheet, ui-change |
| #2 ListTile "icon:0xefc6 / Driving licence / Driving licence" | push:sheet, ui-change |
| #3 IconButton "tip:Quick lookup / icon:0xe567" | push:dialog, ui-change |
| #4 FAB "icon:0xe047 / Add" | push:dialog, ui-change |

## family

| button | effect |
|---|---|
| #9 InkWell "Today's Medicines / Tab 1 of 10" | SKIP:already the selected option |
| #0 TextButton "Undo" | snackbar, net, ui-change |
| #1 TextButton "Skip" | snackbar, net, ui-change |
| #2 FilledButton "Take" | snackbar, net, ui-change |
| #3 TextButton "Skip" | snackbar, net, ui-change |
| #4 FilledButton "Take" | snackbar, net, ui-change |
| #5 TextButton "Undo" | snackbar, net, ui-change |
| #6 FilledButton "Log as-needed dose" | snackbar, net, ui-change |
| #7 IconButton "tip:Scam check / icon:0xf379" | push:dialog, ui-change |
| #8 IconButton "icon:0xe62f" | api:LIST medicines LIST family LIST school, state-change |
| #10 InkWell "Medicines / Tab 2 of 10" | ui-change |
| #11 InkWell "Overview / Tab 3 of 10" | ui-change |
| #12 InkWell "Prescriptions / Tab 4 of 10" | ui-change |
| #13 InkWell "Family / Tab 5 of 10" (scrolled) | ui-change |
| #14 InkWell "Family accounting / Tab 6 of 10" (scrolled) | api:GET /family/accounting/summary, net, ui-change |
| #15 InkWell "School / Tab 7 of 10" (scrolled) | ui-change |
| #16 InkWell "Sharing / Tab 8 of 10" (scrolled) | api:GET /family/sharing/consent, net, ui-change |
| #17 InkWell "Family card / Tab 9 of 10" (scrolled) | ui-change |
| #18 InkWell "Probashi / Tab 10 of 10" (scrolled) | ui-change |

## emergency

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf07c7 / Emergency SOS" | push:dialog, ui-change |
| #1 SwitchListTile "icon:0xe6c5 / Loud mode / The phone buzzes strongly while SOS is armin…" | ui-change |
| #2 OutlinedButton "icon:0xe418 / Share my location" | snackbar, platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, ui-change |
| #3 OutlinedButton "icon:0xf0f2 / Safety tools" | push:page, ui-change |
| #4 OutlinedButton "icon:0xf00d / Edit" | ui-change |
| #5 FilledButton "icon:0xe34d / Share" | push:sheet, ui-change |
| #6 FilledButton "icon:0xe126 / 999" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #7 FilledButton "icon:0xe126 / 109" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #8 FilledButton "icon:0xe126 / 333" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #9 FilledButton "icon:0xe126 / 102" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #10 FilledButton "icon:0xe126 / 199" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #11 FilledButton "icon:0xe126 / 100" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #12 FilledButton "icon:0xe126 / 1090" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #13 FilledButton "icon:0xe567 / Find nearest help" | platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, ui-change |
| #14 ListTile "icon:0xe25b / Unresponsive / not breathing (CPR) / icon:0xe246" | ui-change |
| #15 ListTile "icon:0xe0e3 / Severe bleeding / icon:0xe246" | ui-change |
| #16 ListTile "icon:0xe064 / Choking / icon:0xe246" | ui-change |
| #17 ListTile "icon:0xe392 / Burns / icon:0xe246" | ui-change |
| #18 ListTile "icon:0xe065 / Fainting / dizziness / icon:0xe246" | ui-change |
| #19 ListTile "icon:0xe49f / Snakebite / icon:0xe246" (scrolled) | ui-change |
| #20 IconButton "tip:Share / icon:0xe34d" | push:sheet, ui-change |
| #21 IconButton "tip:Edit / icon:0xf00d" | ui-change |

## reminders

| button | effect |
|---|---|
| #0 InkWell "Pay electricity bill / icon:0xe556 / 14 Oct, 10:00 AM" | push:dialog, ui-change |
| #1 Checkbox "" | ERROR:async: Bad state: databaseFactory not initialized |
| #2 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #3 InkWell "Doctor appointment / icon:0xe556 / 16 Oct, 5:30 PM" | push:dialog, ui-change |
| #4 Checkbox "" | ERROR:async: Bad state: databaseFactory not initialized |
| #5 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #6 IconButton "tip:Calendar view / icon:0xf051f" | ui-change |
| #7 IconButton "tip:Sync / icon:0xe62f" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #8 FAB "icon:0xe049 / Add" | push:dialog, ui-change |

## notes_tasks

| button | effect |
|---|---|
| #3 InkWell "Notes / Tab 1 of 2" | SKIP:already the selected option |
| #0 InkWell "tip:Show menu / icon:0xe4f4 / Market list / icon:0xe404" | push:sheet, ui-change |
| #1 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #2 FAB "icon:0xe047" | push:sheet, ui-change |
| #4 InkWell "To-Do / Tab 2 of 2" | ui-change |

## memory

| button | effect |
|---|---|
| #0 ChoiceChip "All (2) / icon:0xee80" | SKIP:already the selected option |
| #1 ChoiceChip "Other (2) / icon:0xe364" | ui-change |
| #2 OutlinedButton "icon:0xe16a / No, discard" | ui-change |
| #3 FilledButton "icon:0xe156 / Remember it" | ERROR:async: Bad state: databaseFactory not initialized |
| #4 ListTile "icon:0xe364 / Home wifi password: *** / icon:0xe364" | push:sheet, ui-change |
| #5 PopupMenuButton "tip:Options / icon:0xe404" | push:popup, ui-change |
| #6 ListTile "icon:0xe364 / Car insurance ends in November / icon:0xe364" | push:sheet, ui-change |
| #7 PopupMenuButton "tip:Options / icon:0xe404" | push:popup, ui-change |
| #8 IconButton "tip:What AI knows about me / icon:0xf4a1" | push:page, ui-change |
| #9 IconButton "tip:Sync / icon:0xe62f" | ui-change |
| #10 PopupMenuButton "tip:Your data / icon:0xe404" | push:popup, ui-change |
| #11 FAB "icon:0xe047 / Add" | push:sheet, ui-change |

## subscriptions

| button | effect |
|---|---|
| #0 InkWell "icon:0xf3fb / Netflix / ৳500  ·  Monthly" | push:sheet, ui-change |
| #1 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #2 InkWell "icon:0xf3fb / Internet / ৳1,200  ·  Monthly" | push:sheet, ui-change |
| #3 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #4 InkWell "icon:0xf3fb / Internet / ৳1,200  ·  Monthly" | push:sheet, ui-change |
| #5 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #6 InkWell "icon:0xf3fb / Gym / ৳9,000  ·  Yearly" | push:sheet, ui-change |
| #7 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #8 InkWell "icon:0xf3fb / Netflix / ৳500  ·  Monthly" | push:sheet, ui-change |
| #9 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #10 InkWell "icon:0xf3fb / Netflix / ৳500  ·  Monthly" | push:sheet, ui-change |
| #11 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #12 InkWell "icon:0xf3fb / Internet / ৳1,200  ·  Monthly" | push:sheet, ui-change |
| #13 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #14 InkWell "icon:0xf3fb / Gym / ৳9,000  ·  Yearly" | push:sheet, ui-change |
| #15 IconButton "tip:Mark paid / icon:0xe15a" | snackbar, api:UPDATE subscriptions, net, ui-change |
| #16 FAB "icon:0xe047 / Add subscription" | push:sheet, ui-change |

## connected_apps

| button | effect |
|---|---|
| #0 SwitchListTile "From photos" | snackbar, net, ui-change |
| #1 SwitchListTile "Shared or forwarded content" | snackbar, net, ui-change |
| #2 SwitchListTile "Bangla voice" | snackbar, net, ui-change |
| #3 SwitchListTile "Notifications (bKash/bank)" | snackbar, net, ui-change |

## settings

| button | effect |
|---|---|
| #2 InkWell "English / icon:0xe503" | SKIP:already the selected option |
| #3 InkWell "icon:0xe503 / System default" | SKIP:already the selected option |
| #0 ListTile "A / Arif / 01712345678" | push:page, api:GET /me, net, ui-change |
| #1 InkWell "বাংলা / icon:0xe504 / Bangla" | net, platform:plugins.it_nomads.com/flutter_secure_storage#write, ui-change |
| #4 InkWell "icon:0xe504 / Light" | ui-change |
| #5 InkWell "icon:0xe504 / Dark" | ui-change |
| #6 SwitchListTile "icon:0xe222 / Simple mode (for elders) / Large text, big buttons, only…" | push:dialog, ui-change |
| #7 ListTile "icon:0xee2e / Accessibility mode / Larger text, higher contrast, less …" | push:page, ui-change |
| #8 ListTile "icon:0xf234 / Notifications & calls / Messages, calls, reminders and f…" | push:page, api:GET /push/status, net, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #9 ListTile "icon:0xe2e3 / Voice assistant / Default assistant, “Hey Assisto”, spok…" | push:page, api:GET /voice/config, net, platform:com.assisto/voice#ping, ui-change |
| #10 ListTile "icon:0xf47d / Digital security check-up / Review your security habits …" | push:page, api:LIST security/checklist, ui-change |
| #11 ListTile "icon:0xf379 / Trust & transparency / What Assisto does — and never doe…" | push:page, ui-change |
| #12 ListTile "icon:0xf2ef / What the agent did (audit log)" | push:page, api:GET /actions/pending, net, ui-change |
| #13 ListTile "icon:0xef61 / Offline & data / These modules work offline" | push:page, ui-change |
| #14 ListTile "icon:0xf132 / Analytics" | push:page, api:GET /analytics/dashboard, ui-change |
| #15 ListTile "icon:0xeeb8 / About the name" | push:page, api:GET /name/about, ui-change |
| #16 ListTile "icon:0xeff2 / Export my data / All your information as JSON" | snackbar, net, ui-change |
| #17 ListTile "icon:0xf023 / Encrypted backup & phone transfer / Passphrase-encrypted…" | push:page, ui-change |
| #18 ListTile "icon:0xf41d / Export to Excel" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #19 ListTile "icon:0xf2a4 / Export to PDF" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #20 ListTile "icon:0xeedd / AI credits / Balance, top-up packs & this month's usage" | SKIP:could not scroll it into view |
| #21 TextButton "Retry" | SKIP:could not scroll it into view |
| #22 ListTile "icon:0xe0c1 / Subscriptions / Track recurring bills so nothing surpris…" | SKIP:could not scroll it into view |

## dl1_grace

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe534 / Restore account key=dl-grace-restore" | api:POST /account/delete/cancel, net, ui-change |
| #1 OutlinedButton "icon:0xefa8 / Delete now and start fresh key=dl-grace-fresh" | ui-change |
| #2 TextButton "Sign out and keep the deletion scheduled" | net, platform:plugins.it_nomads.com/flutter_secure_storage#delete |

## dl1_grace_fresh

| button | effect |
|---|---|
| #0 TextButton "Back" | ui-change |

## dl1_delete_pending

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xeff2 / Download my data first" | snackbar, net, ui-change |
| #1 OutlinedButton "icon:0xf04f / Send feedback key=del-acct-feedback" | push:sheet, platform:dev.fluttercommunity.plus/package_info#getAll, ui-change |
| #2 OutlinedButton "icon:0xe30b / Contact support key=del-acct-support" | push:page, ui-change |
| #3 FilledButton "Continue to delete" | ui-change |
| #4 TextButton "Keep my account" | pop:page, ui-change |

## plans

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe0ee / Balance, top-up & usage" | push:page, api:GET /me/usage-summary GET /credits/history GET /payments/config?flavour=apk, net, ui-change |
| #1 FilledButton "icon:0xe493 / Invite a friend" | SKIP:could not scroll it into view |
| #2 FilledButton "icon:0xf05ae / Redeem for days" | SKIP:could not scroll it into view |
| #3 InkWell "icon:0xe314 / Points history / icon:0xe246" | SKIP:could not scroll it into view |

## credits_nopay

| button | effect |
|---|---|
| #0 IconButton "tip:Refresh / icon:0xe514" | api:GET /me/usage-summary GET /credits/history GET /payments/config?flavour=apk, net, state-change |

## credits_paylive

| button | effect |
|---|---|
| #0 FilledButton "৳20 key=pack-buy-p20" | push:sheet, api:GET /payments/config?flavour=apk, ui-change |
| #1 FilledButton "৳50 key=pack-buy-p50" | push:sheet, api:GET /payments/config?flavour=apk, ui-change |
| #2 FilledButton "৳100 key=pack-buy-p100" | push:sheet, api:GET /payments/config?flavour=apk, ui-change |
| #3 IconButton "tip:Refresh / icon:0xe514" | api:GET /me/usage-summary GET /credits/history GET /payments/config?flavour=apk, net, state-change |

## push_settings

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe45c / Open setting" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 OutlinedButton "Battery settings guide" | push:page, platform:com.assisto/oem_guide#info, ui-change |
| #2 TextButton "Open Android notification settings" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## incoming_call

| button | effect |
|---|---|
| #0 InkWell "icon:0xe127" | pop:page, platform:com.assisto/calls#stopRingtone plugins.it_nomads.com/flutter_secure_storage#read dexterous.com/flutter/local_notifications#cancel, ui-change |
| #1 InkWell "icon:0xe6a8" | replace:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/calls/7/event, net, platform:com.assisto/calls#stopRingtone dexterous.com/flutter/local_notifications#cancel com.assisto/calls#keepScreenOn, ui-change |

## finance

| button | effect |
|---|---|
| #0 ListTile "icon:0xee32 / EMI / loan calculator / Reducing & flat rate, full sched…" | ui-change |
| #1 ListTile "icon:0xe182 / Rate vs installment compare / Compare two profit rates" | ui-change |
| #2 ListTile "icon:0xf0568 / Can I afford this? / Match EMI to your cashflow" | ui-change |
| #3 ListTile "icon:0xf336 / DPS / savings projection / Monthly deposit maturity" | ui-change |
| #4 ListTile "icon:0xf07b / Savings goal / Monthly amount to reach a goal" | ui-change |
| #5 ListTile "icon:0xe67f / Simple ROI / Return on investment %" | ui-change |
| #6 ListTile "icon:0xe4c5 / 50-30-20 budget / Needs / wants / savings" | ui-change |
| #7 ListTile "icon:0xee33 / Net worth / Planning" | ui-change |
| #8 ListTile "icon:0xf4a9 / Zakat / 2.5% above nisab" | ui-change |
| #9 ListTile "icon:0xf05c1 / Break-even / Units before profit starts" | ui-change |
| #10 ListTile "icon:0xf04dc / Currency / unit convert / At a rate you enter" | ui-change |

## watch_feed

| button | effect |
|---|---|
| #0 InkWell "icon:0xe4ec / Passport expires in 24 days / icon:0xef1a" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #1 FilledButton "icon:0xef1a / Call" | push:page, ui-change |
| #2 InkWell "icon:0xe4ec / Transport budget exceeded / icon:0xef1a" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #3 FilledButton "icon:0xef1a / Call" | push:page, ui-change |
| #4 InkWell "icon:0xe4ec / Take medicine / 10 days overdue" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #5 FilledButton "icon:0xe156 / Mark done" | snackbar, api:UPDATE reminders, net, ui-change |
| #6 TextButton "icon:0xf3af / Snooze" | snackbar, ui-change |
| #7 InkWell "icon:0xf234 / Napa / Mother · 20:00" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #8 FilledButton "icon:0xf1bf / Taken" | snackbar, net, ui-change |
| #9 InkWell "icon:0xf234 / Losectil / 08:00" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #10 FilledButton "icon:0xf1bf / Taken" | snackbar, net, ui-change |
| #11 InkWell "icon:0xf234 / Sleeping aid / prn" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #12 FilledButton "icon:0xf1bf / Taken" | snackbar, net, ui-change |
| #13 InkWell "icon:0xe4ec / New update — circular published / icon:0xe45c" | push:page, api:LIST reminders LIST subscriptions LIST watchers, ui-change |
| #14 TextButton "icon:0xe16a / Dismiss" | snackbar, ui-change |
| #15 InkWell "icon:0xe33d / USD/BDT 122.50 → 122.80 (↑) / icon:0xe45c" | push:page, api:LIST reminders LIST subscriptions LIST watchers, ui-change |
| #16 TextButton "icon:0xe16a / Dismiss" | snackbar, ui-change |
| #17 InkWell "icon:0xe33d / Internet / In 2 days" | push:page, api:LIST subscriptions, ui-change |
| #18 FilledButton "icon:0xf266 / How to pay" | push:page, api:LIST subscriptions, ui-change |
| #19 TextButton "icon:0xe16a / Dismiss" | snackbar, ui-change |
| #20 IconButton "tip:Remove / icon:0xe1bb" | snackbar, api:DELETEITEM watchers, net, ui-change |
| #21 IconButton "tip:Remove / icon:0xe1bb" | snackbar, api:DELETEITEM watchers, net, ui-change |
| #22 IconButton "tip:Personalize / icon:0xe683" | push:sheet, ui-change |
| #23 IconButton "tip:Refresh / icon:0xe514" | api:LIST reminders LIST subscriptions LIST watchers, state-change |
| #24 FAB "icon:0xee3b / Add rate alert" | snackbar, api:CREATE watchers, net, ui-change |

## jobs

| button | effect |
|---|---|
| #17 InkWell "Discover / Tab 1 of 3" | SKIP:already the selected option |
| #0 InkWell "— / Junior Software Engineer / Brain Station 23" | push:sheet, ui-change |
| #1 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #2 InkWell "— / Accounts Officer / Square Group" | push:sheet, ui-change |
| #3 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #4 InkWell "— / Field Sales Executive / Pran-RFL" | push:sheet, ui-change |
| #5 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #6 InkWell "— / Programme Officer / BRAC" | push:sheet, ui-change |
| #7 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #8 InkWell "— / Remote Flutter Developer / Kaz Software" | push:sheet, ui-change |
| #9 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #10 InkWell "— / Production Supervisor / Ha-Meem Group" | push:sheet, ui-change |
| #11 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #12 InkWell "82 / Flutter Developer / TechBD" | push:sheet, ui-change |
| #13 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #14 InkWell "48 / Backend Engineer / Shop365" | push:sheet, ui-change |
| #15 IconButton "tip:Save job / icon:0xe0f4" | ui-change |
| #16 IconButton "tip:Filters / icon:0xe683" | push:sheet, ui-change |
| #18 InkWell "Saved / Tab 2 of 3" | ui-change |
| #19 InkWell "Tracker / Tab 3 of 3" | ui-change |
| #20 FAB "icon:0xe047 / Job" | push:dialog, ui-change |

## nominee

| button | effect |
|---|---|
| #0 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #1 TextButton "icon:0xe683 / Manage access" | push:sheet, ui-change |
| #2 FAB "icon:0xe493 / Nominee" | push:sheet, ui-change |

## scam

| button | effect |
|---|---|
| #1 InkWell "Check / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe567 / Check message" | snackbar, ui-change |
| #2 InkWell "Learn / Tab 2 of 2" | api:GET /scam/library, ui-change |

## safety

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe41e / Start journey" | push:page, api:GET /journey/active GET /journey/places GET /circle/members, ui-change |
| #1 FilledButton "icon:0xf07c7 / SOS — Emergency call" | push:page, ui-change |
| #2 OutlinedButton "icon:0xe126 / Quick call" | push:dialog, ui-change |
| #3 TextButton "Edit" | push:dialog, ui-change |
| #4 ListTile "icon:0xf2f3 / Hands-free Voice SOS / Send SOS by voice, without touchi…" | push:page, platform:flutter_foreground_task/methods#isRunningService flutter.baseflow.com/permissions/methods#checkPermissionStatus, ui-change |
| #5 FilledButton "Set" | push:dialog, ui-change |
| #6 TextButton "icon:0xe45c / Set a check-in" | push:page, api:GET /journey/routines, ui-change |
| #7 IconButton "tip:Safety settings / icon:0xf36e" | push:page, api:GET /journey/wellness, ui-change |

## crm_contacts

| button | effect |
|---|---|
| #0 FilterChip "All (1)" | SKIP:already the selected option |
| #1 FilterChip "Favourites / icon:0xe5f9" | ui-change |
| #2 FilterChip "Family / icon:0xe257" | ui-change |
| #3 FilterChip "Work / icon:0xe6f4" | ui-change |
| #4 FilterChip "Friends / icon:0xf08a8" (scrolled) | ui-change |
| #5 FilterChip "Acquaintance / icon:0xe497" | SKIP:could not scroll it into view |
| #6 ListTile "M / Mr Karim / ABC Ltd · 01712345678" | push:sheet, ui-change |
| #7 IconButton "tip:Favourite / icon:0xe5fa" | snackbar, api:UPDATE contacts, net, ui-change |
| #8 IconButton "tip:Sort by / icon:0xe5d2" | push:sheet, ui-change |
| #9 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #10 FAB "icon:0xe493 / Contact" | push:sheet, ui-change |

## crm_today

| button | effect |
|---|---|
| #0 ListTile "95 / Karim Garments / Karim Garments Ltd · RMG" | push:page, api:GET /crm/leads/1/ GET /crm/leads/1/timeline/ GET /crm/leads/1/followup/, ui-change |
| #1 IconButton "tip:Call / icon:0xe126" | snackbar, api:POST /crm/leads/1/log_action/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #2 IconButton "tip:WhatsApp / icon:0xe153" | push:sheet, api:GET /crm/leads/1/whatsapp_status/, net, ui-change |
| #3 ListTile "icon:0xe556 / Shop 365 / Next follow-up: Oct 13, 2026" | push:page, api:GET /crm/leads/3/ GET /crm/leads/3/timeline/ GET /crm/leads/3/followup/, ui-change |

## crm_leads

| button | effect |
|---|---|
| #0 FilterChip "High priority" | api:LIST crm/leads?org=1&priority=high, ui-change |
| #1 FilterChip "RMG" | api:LIST crm/leads?org=1&industry=rmg, ui-change |
| #2 FilterChip "Pharma" | api:LIST crm/leads?org=1&industry=pharma, ui-change |
| #3 FilterChip "Retail" | api:LIST crm/leads?org=1&industry=retail, ui-change |
| #4 ListTile "95 / Karim Garments / icon:0xef4c" | push:page, api:GET /crm/leads/1/ GET /crm/leads/1/timeline/ GET /crm/leads/1/followup/, ui-change |
| #5 IconButton "tip:Call / icon:0xe126" | snackbar, api:POST /crm/leads/1/log_action/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #6 IconButton "tip:WhatsApp / icon:0xe153" | push:sheet, api:GET /crm/leads/1/whatsapp_status/, net, ui-change |
| #7 ListTile "72 / Pharma Care / icon:0xf1bf" | push:page, api:GET /crm/leads/2/ GET /crm/leads/2/timeline/ GET /crm/leads/2/followup/, ui-change |
| #8 IconButton "tip:Call / icon:0xe126" | snackbar, api:POST /crm/leads/2/log_action/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #9 IconButton "tip:WhatsApp / icon:0xe153" | push:sheet, api:GET /crm/leads/2/whatsapp_status/, net, ui-change |
| #10 ListTile "34 / Shop 365 / icon:0xf3ef" | push:page, api:GET /crm/leads/3/ GET /crm/leads/3/timeline/ GET /crm/leads/3/followup/, ui-change |
| #11 IconButton "tip:Call / icon:0xe126" | snackbar, api:POST /crm/leads/3/log_action/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #12 IconButton "tip:WhatsApp / icon:0xe153" | push:sheet, api:GET /crm/leads/3/whatsapp_status/, net, ui-change |
| #13 FAB "icon:0xe493 / Add lead" | push:page, ui-change |

## crm_pipeline

| button | effect |
|---|---|
| #0 GestureDetector "Axon ERP — Karim Garments / ৳1,200,000 / 25% · Nov 10, 2026" | push:page, api:GET /crm/deals/1/erp_handoff/, net, ui-change |
| #1 GestureDetector "Axon ERP — Pharma Care / ৳650,000 / 45% · Nov 20, 2026" (scrolled) | push:page, api:GET /crm/deals/2/erp_handoff/, net, ui-change |

## business

| button | effect |
|---|---|
| #0 IconButton "tip:Add another business / icon:0xee3d" | push:page, ui-change |
| #1 InkWell "icon:0xf1c2 / Digital Khata / Dues, payables and reminders in one plac…" | push:page, api:GET /business/khata/parties?business_id=1&book=customer GET /business/khata/net-position?business_id=1, ui-change |
| #2 InkWell "icon:0xf2bb / Selling / Products, cart and quick sell" | push:sheet, ui-change |
| #3 InkWell "icon:0xee33 / Cashbox / Reconcile daily cash in and out" | push:page, api:GET /business/cashbox/2026-10-23?business_id=1, ui-change |
| #4 InkWell "icon:0xf132 / Reports / Sales, profit and top products at a glance" | push:page, api:GET /business/reports?period=daily&business=1, ui-change |
| #5 InkWell "icon:0xf134 / Suppliers & wholesale market / Keep your supplier list, …" | push:page, api:LIST supplier/vendors, ui-change |
| #6 InkWell "icon:0xf132 / Demand map / Log product demand by area and time, and se…" | push:page, api:LIST demand/signals, ui-change |
| #7 InkWell "icon:0xf06a4 / Bargaining rules / Set per-product price floors and dis…" | push:page, api:GET /business/bargain/rules, ui-change |
| #8 InkWell "icon:0xf3a8 / AI assistant / Auto-replies and bargaining with customer…" | push:page, api:GET /business/ai/channels GET /business/ai/threads, ui-change |
| #9 InkWell "icon:0xf403 / AI sales agent / 24/7 replies, orders and courier on Fac…" | push:page, api:GET /bizagent/setup?flavour=apk GET /bizagent/reports, ui-change |
| #10 InkWell "icon:0xf06a1 / Plans / Compare Free vs Premium Business" | push:page, ui-change |
| #11 InkWell "icon:0xf466 / Business setup / Add your name, type and payment details" | push:page, ui-change |
| #12 IconButton "tip:Business setup / icon:0xf36e" | push:page, ui-change |

## inbox

| button | effect |
|---|---|
| #0 FilterChip "All" | SKIP:already the selected option |
| #1 FilterChip "Needs reply (0)" | ui-change |
| #2 FilterChip "Urgent (0)" | ui-change |
| #3 FilterChip "Action (0)" | ui-change |
| #4 FilterChip "FYI (0)" | SKIP:could not scroll it into view |
| #5 FilterChip "Promo (0)" | SKIP:could not scroll it into view |
| #6 IconButton "tip:Select / icon:0xe15b" | ui-change |

## guide

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #1 ChoiceChip "Saved / icon:0xe0f1" | ui-change |
| #2 ListTile "icon:0xefae / National ID / services.nidw.gov.bd" | ui-change |
| #3 IconButton "tip:Save / icon:0xe0f4" | ui-change |
| #4 ListTile "icon:0xefae / e-Passport / epassport.gov.bd" | ui-change |
| #5 IconButton "tip:Save / icon:0xe0f4" | ui-change |

## agent_studio

| button | effect |
|---|---|
| #2 InkWell "My automations / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe0b7 / Browse templates" | ui-change |
| #1 IconButton "tip:Post & caption / icon:0xef27" | push:page, ui-change |
| #3 InkWell "Templates / Tab 2 of 2" | ui-change |
| #4 FAB "icon:0xe047 / New" | push:sheet, ui-change |

## battery_guidance

| button | effect |
|---|---|
| #7 InkWell "icon:0xe156 / Other (Walton, Symphony, Nokia…)" | SKIP:already the selected option |
| #0 InkWell "Samsung" | ui-change |
| #1 InkWell "Xiaomi / Redmi / POCO" | ui-change |
| #2 InkWell "OPPO" | ui-change |
| #3 InkWell "realme" | ui-change |
| #4 InkWell "OnePlus" | ui-change |
| #5 InkWell "vivo / iQOO" | ui-change |
| #6 InkWell "Infinix / Tecno / itel" | ui-change |

## onboarding

| button | effect |
|---|---|
| #2 InkWell "icon:0xf45e / English / icon:0xe159" | SKIP:already the selected option |
| #0 TextButton "Skip" | state-change |
| #1 InkWell "icon:0xf45e / বাংলা / Bangla" | net, platform:plugins.it_nomads.com/flutter_secure_storage#write, ui-change |
| #3 FilledButton "Next" | ui-change |

## support

| button | effect |
|---|---|
| #0 FilledButton "Send" | snackbar, ui-change |

## health_tips

| button | effect |
|---|---|
| #1 ChoiceChip "All topics" | SKIP:already the selected option |
| #0 OutlinedButton "icon:0xf0f2 / Check" | snackbar, ui-change |
| #2 ChoiceChip "Dengue & mosquitoes" | api:GET /health/tips?topic=dengue_mosquito, ui-change |
| #3 ChoiceChip "Nutrition" | api:GET /health/tips?topic=nutrition, ui-change |
| #4 FilterChip "Saved / icon:0xe0f4" | ui-change |
| #5 TextButton "icon:0xe0f4 / Save" | ui-change |
| #6 TextButton "icon:0xf378 / Share" | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |

## medicine_db

| button | effect |
|---|---|
| #0 InkWell "Search / Tab 1 of 3" | SKIP:already the selected option |
| #1 InkWell "Saved / Tab 2 of 3" | ui-change |
| #2 InkWell "Recent / Tab 3 of 3" | ui-change |

## birthdays

| button | effect |
|---|---|
| #0 IconButton "tip:Wish / icon:0xe3c4" | push:sheet, api:POST /birthdays/drafts, ui-change |
| #1 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #2 FAB "icon:0xe047 / Add" | push:sheet, ui-change |

## meetings

| button | effect |
|---|---|
| #4 ChoiceChip "List" | SKIP:already the selected option |
| #0 PopupMenuButton "tip: / icon:0xe404" | push:popup, ui-change |
| #1 OutlinedButton "icon:0xefc8 / Add travel time" | push:dialog, ui-change |
| #2 IconButton "tip:Directions in Maps / icon:0xf1ae" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #3 IconButton "tip:Past / icon:0xe314" | ui-change |
| #5 ChoiceChip "Day" | ui-change |
| #6 ChoiceChip "Week" | ui-change |
| #7 ChoiceChip "Month" | ui-change |
| #8 FAB "icon:0xe047 / New meeting" | push:sheet, ui-change |

## dictionary

| button | effect |
|---|---|
| #0 InkWell "Search / Tab 1 of 3" | SKIP:already the selected option |
| #1 InkWell "Saved / Tab 2 of 3" | ui-change |
| #2 InkWell "History / Tab 3 of 3" | ui-change |
| #3 GestureDetector "" | ui-change |

## ride_food

| button | effect |
|---|---|
| #0 ActionChip "Save as Home / icon:0xf107" | snackbar, ui-change |
| #1 ActionChip "Save as Work / icon:0xe6f4" | snackbar, ui-change |
| #2 ActionChip "Save place / icon:0xeee0" | snackbar, ui-change |
| #3 ListTile "icon:0xefc5 / Uber / Open in the provider's app" | platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #4 ListTile "icon:0xf46c / Pathao / Open in the provider's app" | platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #5 ActionChip "Save craving / icon:0xe25c" | snackbar, ui-change |
| #6 ListTile "icon:0xefac / foodpanda / Open in the provider's app" | platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #7 ListTile "icon:0xf049 / Pathao Food / Open in the provider's app" | platform:plugins.flutter.io/url_launcher#launch, ui-change |

## ramadan

| button | effect |
|---|---|
| #0 TextButton "Set start day" | push:dialog, ui-change |
| #1 InkWell "1" | ui-change |
| #2 InkWell "2" | ui-change |
| #3 InkWell "3" | ui-change |
| #4 InkWell "4" | ui-change |
| #5 InkWell "5" | ui-change |
| #6 InkWell "6" | ui-change |
| #7 InkWell "7" | ui-change |
| #8 InkWell "8" | ui-change |
| #9 InkWell "9" | ui-change |
| #10 InkWell "10" | ui-change |
| #11 InkWell "11" | ui-change |
| #12 InkWell "12" | ui-change |
| #13 InkWell "13" | ui-change |
| #14 InkWell "14" | ui-change |
| #15 InkWell "15" | ui-change |
| #16 InkWell "16" | ui-change |
| #17 InkWell "17" | ui-change |
| #18 InkWell "18" | ui-change |
| #19 InkWell "19" | ui-change |
| #20 InkWell "20" | ui-change |
| #21 InkWell "21" | ui-change |
| #22 InkWell "22" | ui-change |
| #23 InkWell "23" | ui-change |
| #24 InkWell "24" | ui-change |
| #25 InkWell "25" | ui-change |
| #26 InkWell "26" | ui-change |
| #27 InkWell "27" | ui-change |
| #28 InkWell "28" | ui-change |
| #29 InkWell "29" | ui-change |
| #30 InkWell "30" | ui-change |
| #31 FilledButton "icon:0xef10 / Calculate zakat" | ui-change |
| #32 IconButton "tip:Add salami / icon:0xe050" | push:dialog, ui-change |
| #33 FilledButton "icon:0xe0b7 / Create a draft" | api:POST /ramadan/eid-card, ui-change |
| #34 IconButton "tip:Refresh times from location / icon:0xe418" | platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, state-change |

## exam

| button | effect |
|---|---|
| #0 DropdownButton "SSC / HSC / JSC" | push:popup, ui-change |
| #1 DropdownButton "Dhaka / Rajshahi / Chattogram" | push:popup, ui-change |
| #2 OutlinedButton "icon:0xe122 / Pick an expected date" | push:dialog, ui-change |
| #3 FilledButton "icon:0xf234 / Start watching" | snackbar, ui-change |
| #4 FilledButton "icon:0xf47c / Check on the official board site" | platform:plugins.flutter.io/url_launcher#canLaunch, ERROR:async: MissingPluginException(No implementation found for method canLaunch on channel plugins.flutter.io/url_launcher) |
| #5 TextButton "icon:0xe493 / Add student" | ui-change |
| #6 ListTile "See the board grading scale / icon:0xe246" | ui-change |

## circle

| button | effect |
|---|---|
| #0 ListTile "M / Mom / Mother" | push:page, api:GET /circle/keys/peer/1 GET /circle/t1/gate?kind=member&id=1 GET /circle/1/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #1 PopupMenuButton "tip:Show menu / icon:0xe404" | push:popup, ui-change |
| #2 IconButton "tip:Status / icon:0xeea9" | push:page, api:GET /circle/status, ui-change |
| #3 IconButton "tip:Groups / icon:0xf0db" | push:page, api:GET /circle/groups, ui-change |
| #4 IconButton "tip:Search all chats / icon:0xe567" | push:page, ui-change |
| #5 FAB "icon:0xf275 / Add" | push:page, ui-change |

## circle_chat

| button | effect |
|---|---|
| #0 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #1 IconButton "tip:Attach / icon:0xe050" | push:sheet, ui-change |
| #2 IconButton "icon:0xe571" | ui-change |
| #3 InkWell "M / Mom key=t1-header" | push:page, api:GET /circle/1/info, ui-change |
| #4 IconButton "tip:Video / icon:0xf48c" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #5 IconButton "tip:Voice call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #6 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## circle_call_history

| button | effect |
|---|---|
| #0 IconButton "tip:Call back / icon:0xe126" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/5/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 IconButton "tip:Call back / icon:0xe126" | push:page, api:GET /rt/events?after=0 GET /rtc/turn, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#stopRingtone, ui-change |

## circle_privacy

| button | effect |
|---|---|
| #2 RadioListTile "Everyone in my circle" | SKIP:already the selected option |
| #0 SwitchListTile "icon:0xe1f7 / Read receipts / If off, you won't see others' read recei…" | ui-change |
| #1 SwitchListTile "icon:0xf144 / Typing indicator / If off, you won't see others typing e…" | ui-change |
| #3 RadioListTile "Only chosen people" | push:dialog, ui-change |
| #4 RadioListTile "Only chosen relationships" | push:dialog, ui-change |
| #5 RadioListTile "Nobody" | push:dialog, ui-change |
| #6 SwitchListTile "icon:0xefdb / Enable schedule / Calls won't ring during these hours (s…" | ui-change |

## circle_search

| button | effect |
|---|---|
| #0 GestureDetector "" | ui-change |

## referral

| button | effect |
|---|---|
| #3 InkWell "Overview / Tab 1 of 3" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe493 / Invite a friend" | push:sheet, ui-change |
| #1 FilledButton "icon:0xf05ae / Redeem" | push:sheet, ui-change |
| #2 FilledButton "icon:0xe34d / Share achievement card" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #4 InkWell "Friends / Tab 2 of 3" | ui-change |
| #5 InkWell "History / Tab 3 of 3" | ui-change |

## journey_start

| button | effect |
|---|---|
| #0 ActionChip "Home / icon:0xe4c9" | ui-change |
| #1 OutlinedButton "icon:0xe556 / Arrive by 4:11 PM" | push:dialog, ui-change |
| #2 CheckboxListTile "Mom" | ui-change |
| #3 ListTile "Ride details (optional) / icon:0xe246" | ui-change |
| #4 ListTile "More settings / icon:0xe246" | ui-change |
| #5 FilledButton "icon:0xe41e / Start journey" | snackbar, ui-change |

## journey_live

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf07c7 / SOS — Emergency call" | push:page, ui-change |
| #1 FilledButton "icon:0xe159 / I've arrived safely" | pop:page, snackbar, api:POST /journey/1/arrived, ui-change |
| #2 OutlinedButton "icon:0xe4a5 / Fake call" | push:dialog, ui-change |
| #3 OutlinedButton "icon:0xf3e9 / Stop journey" | push:dialog, ui-change |
| #4 IconButton "tip:Share link / icon:0xe380" | snackbar, api:GET /journey/1/web-link, platform:dev.fluttercommunity.plus/share#share, ui-change |

## journey_sos

| button | effect |
|---|---|
| #0 SwitchListTile "Sound siren" | ui-change |
| #1 FilledButton "Cancel" | push:dialog, ui-change |

## journey_settings

| button | effect |
|---|---|
| #0 SwitchListTile "Default siren / A loud siren plays on SOS (toggle in settings)." | ui-change |
| #1 TextButton "Set up PIN" | push:dialog, ui-change |
| #2 SwitchListTile "Enable wellness check" | api:POST /journey/wellness, ui-change |

## journey_fake_call

| button | effect |
|---|---|
| #0 TextButton "Cancel" | pop:page, ui-change |

## crm_firstrun

| button | effect |
|---|---|
| #0 ChoiceChip "RMG" | SKIP:already the selected option |
| #8 ChoiceChip "2–5" | SKIP:already the selected option |
| #1 ChoiceChip "Pharma" | ui-change |
| #2 ChoiceChip "Retail" | ui-change |
| #3 ChoiceChip "IT & Software" | ui-change |
| #4 ChoiceChip "Manufacturing" | ui-change |
| #5 ChoiceChip "Services" | ui-change |
| #6 ChoiceChip "Other" | ui-change |
| #7 ChoiceChip "Just me" | ui-change |
| #9 ChoiceChip "6–20" | ui-change |
| #10 ChoiceChip "20+" | ui-change |
| #11 FilledButton "icon:0xf0653 / Create CRM" | ui-change |

## crm_firstrun_join

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf0d8 / Join a team" | ui-change |

## legal

| button | effect |
|---|---|
| #0 ListTile "icon:0xefae / Privacy policy / DRAFT — TO REVIEW BY OWNER" | push:page, api:GET /legal/privacy, ui-change |
| #1 ListTile "icon:0xefae / Terms of use / DRAFT — TO REVIEW BY OWNER" | push:page, api:GET /legal/terms, ui-change |

## photo_studio_free_empty

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf29d / Choose a photo key=psPickGallery" | ui-change |
| #1 OutlinedButton "icon:0xf29b / Take a photo" | ui-change |
| #2 FilledButton "icon:0xeea9 / Create image key=psRunPrompt" | snackbar, ui-change |

## photo_studio_free_enhanced

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | state-change |
| #2 FilterChip "Change background key=psOpt_bg_change" | ui-change |
| #3 FilterChip "Remove background key=psOpt_bg_remove" | ui-change |
| #4 FilterChip "Blur background key=psOpt_bg_blur" | ui-change |
| #5 FilterChip "Replace sky key=psOpt_sky_replace" | ui-change |
| #6 FilterChip "Remove things or people behind key=psOpt_remove_objects" | ui-change |
| #7 FilterChip "Lighting & colour key=psOpt_lighting" | ui-change |
| #8 FilterChip "Passport photo (40×50 mm, white) key=psOpt_passport_bd" | ui-change |
| #9 FilterChip "Visa photo (50×50 mm, white) key=psOpt_visa_bd" | ui-change |
| #10 FilterChip "Product photo (white studio) key=psOpt_product_photo" | ui-change |
| #11 FilterChip "Document cleanup key=psOpt_document_cleanup" | ui-change |
| #12 FilterChip "Crop & straighten key=psOpt_crop_straighten" | ui-change |
| #13 FilterChip "Beauty retouch key=psOpt_beauty_retouch" | ui-change |
| #14 SwitchListTile "There are people in this photo key=psHasPeople" | ui-change |
| #15 SwitchListTile "Someone else is in this photo key=psOthers" | ui-change |
| #16 SwitchListTile "A child is in this photo key=psChild" | ui-change |
| #17 FilledButton "icon:0xeea9 / Apply edit key=psRunPrompt" | snackbar, ui-change |
| #18 InkWell "icon:0xf6df / Save" | push:sheet, ui-change |
| #19 InkWell "icon:0xf016a / Share" | push:sheet, ui-change |
| #20 InkWell "icon:0xf029f / Wallpaper" | push:sheet, ui-change |
| #21 InkWell "icon:0xf66c / Copy" | push:sheet, ui-change |
| #22 InkWell "icon:0xf0034 / Open in…" | push:sheet, ui-change |
| #23 IconButton "tip:Undo / icon:0xf0261" | ui-change |
| #24 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_premium

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | state-change |
| #2 FilterChip "Change background key=psOpt_bg_change" | ui-change |
| #3 FilterChip "Remove background key=psOpt_bg_remove" | ui-change |
| #4 FilterChip "Blur background key=psOpt_bg_blur" | ui-change |
| #5 FilterChip "Replace sky key=psOpt_sky_replace" | ui-change |
| #6 FilterChip "Remove things or people behind key=psOpt_remove_objects" | ui-change |
| #7 FilterChip "Lighting & colour key=psOpt_lighting" | ui-change |
| #8 FilterChip "Passport photo (40×50 mm, white) key=psOpt_passport_bd" | ui-change |
| #9 FilterChip "Visa photo (50×50 mm, white) key=psOpt_visa_bd" | ui-change |
| #10 FilterChip "Product photo (white studio) key=psOpt_product_photo" | ui-change |
| #11 FilterChip "Document cleanup key=psOpt_document_cleanup" | ui-change |
| #12 FilterChip "Crop & straighten key=psOpt_crop_straighten" | ui-change |
| #13 FilterChip "Beauty retouch key=psOpt_beauty_retouch" | ui-change |
| #14 SwitchListTile "There are people in this photo key=psHasPeople" | ui-change |
| #15 SwitchListTile "Someone else is in this photo key=psOthers" | ui-change |
| #16 SwitchListTile "A child is in this photo key=psChild" | ui-change |
| #17 FilledButton "icon:0xeea9 / Apply edit key=psRunPrompt" | snackbar, ui-change |
| #18 InkWell "icon:0xf6df / Save" | snackbar, ui-change |
| #19 InkWell "icon:0xf016a / Share" | snackbar, ui-change |
| #20 InkWell "icon:0xf029f / Wallpaper" | snackbar, ui-change |
| #21 InkWell "icon:0xf66c / Copy" | snackbar, ui-change |
| #22 InkWell "icon:0xf0034 / Open in…" | snackbar, ui-change |
| #23 IconButton "tip:Undo / icon:0xf0261" | ui-change |
| #24 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_nokey_user

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | state-change |
| #2 InkWell "icon:0xf6df / Save" | push:sheet, ui-change |
| #3 InkWell "icon:0xf016a / Share" | push:sheet, ui-change |
| #4 InkWell "icon:0xf029f / Wallpaper" | push:sheet, ui-change |
| #5 InkWell "icon:0xf66c / Copy" | push:sheet, ui-change |
| #6 InkWell "icon:0xf0034 / Open in…" | push:sheet, ui-change |
| #7 IconButton "tip:Undo / icon:0xf0261" | ui-change |
| #8 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_nokey_owner

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf29d / Choose a photo key=psPickGallery" | ui-change |
| #1 OutlinedButton "icon:0xf29b / Take a photo" | ui-change |

## photo_studio_ai_download

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 SwitchListTile "icon:0xeeab / AI restore & upscale / One-time download (4.6 MB) from A… key=psAiSwitch" | ui-change |
| #2 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | ui-change |
| #3 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_ai_downloading

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | ui-change |
| #2 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_ai_used

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 SwitchListTile "icon:0xeeab / AI restore & upscale / Runs on your phone, no internet n… key=psAiSwitch" | ui-change |
| #2 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | state-change |
| #3 InkWell "icon:0xf6df / Save" | push:sheet, ui-change |
| #4 InkWell "icon:0xf016a / Share" | push:sheet, ui-change |
| #5 InkWell "icon:0xf029f / Wallpaper" | push:sheet, ui-change |
| #6 InkWell "icon:0xf66c / Copy" | push:sheet, ui-change |
| #7 InkWell "icon:0xf0034 / Open in…" | push:sheet, ui-change |
| #8 IconButton "tip:Undo / icon:0xf0261" | ui-change |
| #9 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_ai_fellback

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 SwitchListTile "icon:0xeeab / AI restore & upscale / Runs on your phone, no internet n… key=psAiSwitch" | snackbar, ui-change |
| #2 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | snackbar, ui-change |
| #3 InkWell "icon:0xf6df / Save" | push:sheet, snackbar, ui-change |
| #4 InkWell "icon:0xf016a / Share" | push:sheet, snackbar, ui-change |
| #5 InkWell "icon:0xf029f / Wallpaper" | push:sheet, snackbar, ui-change |
| #6 InkWell "icon:0xf66c / Copy" | push:sheet, snackbar, ui-change |
| #7 InkWell "icon:0xf0034 / Open in…" | push:sheet, snackbar, ui-change |
| #8 IconButton "tip:Undo / icon:0xf0261" | snackbar, ui-change |
| #9 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_refusal

| button | effect |
|---|---|
| #0 TextButton "icon:0xe625 / Change photo" | ui-change |
| #1 FilledButton "icon:0xe0b7 / Enhance key=psEnhance" | ui-change |
| #2 FilterChip "Change background key=psOpt_bg_change" | ui-change |
| #3 FilterChip "Remove background key=psOpt_bg_remove" | ui-change |
| #4 FilterChip "Blur background key=psOpt_bg_blur" | ui-change |
| #5 FilterChip "Replace sky key=psOpt_sky_replace" | ui-change |
| #6 FilterChip "Remove things or people behind key=psOpt_remove_objects" | ui-change |
| #7 FilterChip "Lighting & colour key=psOpt_lighting" | ui-change |
| #8 FilterChip "Passport photo (40×50 mm, white) key=psOpt_passport_bd" | ui-change |
| #9 FilterChip "Visa photo (50×50 mm, white) key=psOpt_visa_bd" | ui-change |
| #10 FilterChip "Product photo (white studio) key=psOpt_product_photo" | ui-change |
| #11 FilterChip "Document cleanup key=psOpt_document_cleanup" | ui-change |
| #12 FilterChip "Crop & straighten key=psOpt_crop_straighten" | ui-change |
| #13 FilterChip "Beauty retouch key=psOpt_beauty_retouch" | ui-change |
| #14 SwitchListTile "There are people in this photo key=psHasPeople" | ui-change |
| #15 SwitchListTile "Someone else is in this photo key=psOthers" | ui-change |
| #16 SwitchListTile "A child is in this photo key=psChild" | ui-change |
| #17 FilledButton "icon:0xeea9 / Apply edit key=psRunPrompt" | snackbar, ui-change |
| #18 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## photo_studio_gate

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe4ce / Watch ad key=psGateWatch" | pop:page, ui-change |
| #1 OutlinedButton "icon:0xf450 / Use 2 credits key=psGateCredits" | pop:page, ui-change |
| #2 TextButton "icon:0xf06a1 / Go Premium — no ads" | pop:page, ui-change |

## photo_studio_gate_nofill

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe4ce / Try the ad again key=psGateWatch" | pop:page, ui-change |
| #1 OutlinedButton "icon:0xf450 / Use 9 credits key=psGateCredits" | pop:page, ui-change |
| #2 TextButton "icon:0xf06a1 / Go Premium — no ads" | pop:page, ui-change |

## photo_studio_gate_credits_only

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xf450 / Use 9 credits key=psGateCredits" | pop:page, ui-change |
| #1 TextButton "icon:0xf06a1 / Go Premium — no ads" | pop:page, ui-change |

## web_photo_studio_free

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xf29d / Edit with my original photo key=psWebPickOriginal" | ui-change |
| #1 InkWell "icon:0xf6df / Save" | push:sheet, ui-change |
| #2 InkWell "icon:0xf016a / Share" | push:sheet, ui-change |
| #3 InkWell "icon:0xf029f / Wallpaper" | push:sheet, ui-change |
| #4 InkWell "icon:0xf66c / Copy" | push:sheet, ui-change |
| #5 InkWell "icon:0xf0034 / Open in…" | push:sheet, ui-change |
| #6 IconButton "tip:Undo / icon:0xf0261" | ui-change |
| #7 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## web_photo_studio_premium

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xf29d / Edit with my original photo key=psWebPickOriginal" | ui-change |
| #1 InkWell "icon:0xf6df / Save" | snackbar, ui-change |
| #2 InkWell "icon:0xf016a / Share" | snackbar, ui-change |
| #3 InkWell "icon:0xf029f / Wallpaper" | snackbar, ui-change |
| #4 InkWell "icon:0xf66c / Copy" | snackbar, ui-change |
| #5 InkWell "icon:0xf0034 / Open in…" | snackbar, ui-change |
| #6 IconButton "tip:Undo / icon:0xf0261" | ui-change |
| #7 IconButton "tip:Versions / icon:0xf7ef key=psHistory" | push:sheet, ui-change |

## web_photo_link_expired

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe0b7 / Open Photo Studio" | replace:page, ui-change |

## c2_call_calling

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #3 GestureDetector "icon:0xe3e4" | ui-change |
| #4 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_ringing_no_relay

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #3 GestureDetector "icon:0xe3e4" | ui-change |
| #4 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_connecting

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #3 GestureDetector "icon:0xe3e4" | ui-change |
| #4 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_connected_voice

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_reconnecting

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_video_connected

| button | effect |
|---|---|
| #0 GestureDetector "Speaker / icon:0xe6c5 / Speaker" | ui-change |
| #1 GestureDetector "icon:0xe6c5" | ui-change |
| #2 GestureDetector "Camera / icon:0xf48c / Camera" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Flip / icon:0xef26 / Flip" | state-change |
| #5 GestureDetector "icon:0xef26" | state-change |
| #6 GestureDetector "Voice only / icon:0xf290 / Voice only" | ui-change |
| #7 GestureDetector "icon:0xf290" | ui-change |
| #8 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #9 GestureDetector "icon:0xe3e4" | ui-change |
| #10 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_video_remote_cam_off

| button | effect |
|---|---|
| #0 GestureDetector "Speaker / icon:0xe6c5 / Speaker" | ui-change |
| #1 GestureDetector "icon:0xe6c5" | ui-change |
| #2 GestureDetector "Camera / icon:0xf48c / Camera" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Flip / icon:0xef26 / Flip" | state-change |
| #5 GestureDetector "icon:0xef26" | state-change |
| #6 GestureDetector "Voice only / icon:0xf290 / Voice only" | ui-change |
| #7 GestureDetector "icon:0xf290" | ui-change |
| #8 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #9 GestureDetector "icon:0xe3e4" | ui-change |
| #10 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_busy

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_no_answer

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_declined

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_offline

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_failed

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## c2_call_permission

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf36e / Open settings" | platform:flutter.baseflow.com/permissions/methods#openAppSettings, ERROR:async: MissingPluginException(No implementation found for method openAppSettings on channel flutter.baseflow.com/permissions/methods) |
| #1 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #2 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## x1_call_connect_failed

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/5/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## x1_call_connect_failed_callee

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe126 / Call again key=call-again" | api:GET /rt/events?after=0 GET /rtc/turn POST /circle/5/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #1 OutlinedButton "Close key=call-close" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## x1_call_photo_ringing

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #3 GestureDetector "icon:0xe3e4" | ui-change |
| #4 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## x1_call_photo_connected

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## x1_call_incoming_photo

| button | effect |
|---|---|
| #0 InkWell "icon:0xe127" | pop:page, platform:com.assisto/calls#stopRingtone plugins.it_nomads.com/flutter_secure_storage#read dexterous.com/flutter/local_notifications#cancel, ui-change |
| #1 InkWell "icon:0xe126" | replace:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/calls/43/event, net, platform:com.assisto/calls#stopRingtone dexterous.com/flutter/local_notifications#cancel com.assisto/calls#pipSupported, ui-change |

## c2_call_incoming_video

| button | effect |
|---|---|
| #0 InkWell "icon:0xe127" | pop:page, platform:com.assisto/calls#stopRingtone plugins.it_nomads.com/flutter_secure_storage#read dexterous.com/flutter/local_notifications#cancel, ui-change |
| #1 InkWell "icon:0xe6a8" | replace:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/calls/42/event, net, platform:com.assisto/calls#stopRingtone dexterous.com/flutter/local_notifications#cancel com.assisto/calls#keepScreenOn, ui-change |

## b1_call_voice_controls

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_video_prompt

| button | effect |
|---|---|
| #0 OutlinedButton "Not now key=call-video-decline" | ui-change |
| #1 FilledButton "icon:0xe6a8 / Accept key=call-video-accept" | ui-change |
| #2 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #3 GestureDetector "icon:0xf28c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_video_waiting

| button | effect |
|---|---|
| #0 TextButton "Cancel key=call-video-cancel" | ui-change |
| #1 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #2 GestureDetector "icon:0xf28c" | ui-change |
| #3 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #4 GestureDetector "icon:0xe3e4" | ui-change |
| #5 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_video_switching

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #3 GestureDetector "icon:0xe3e4" | ui-change |
| #4 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_video_upgraded

| button | effect |
|---|---|
| #0 GestureDetector "Speaker / icon:0xe6c5 / Speaker" | state-change |
| #1 GestureDetector "icon:0xe6c5" | state-change |
| #2 GestureDetector "Camera / icon:0xf48c / Camera" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Flip / icon:0xef26 / Flip" | state-change |
| #5 GestureDetector "icon:0xef26" | state-change |
| #6 GestureDetector "Voice only / icon:0xf290 / Voice only" | ui-change |
| #7 GestureDetector "icon:0xf290" | ui-change |
| #8 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #9 GestureDetector "icon:0xe3e4" | ui-change |
| #10 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_video_remote_muted_cam_off

| button | effect |
|---|---|
| #0 GestureDetector "Speaker / icon:0xe6c5 / Speaker" | ui-change |
| #1 GestureDetector "icon:0xe6c5" | ui-change |
| #2 GestureDetector "Camera / icon:0xf48c / Camera" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Flip / icon:0xef26 / Flip" | state-change |
| #5 GestureDetector "icon:0xef26" | state-change |
| #6 GestureDetector "Voice only / icon:0xf290 / Voice only" | ui-change |
| #7 GestureDetector "icon:0xf290" | ui-change |
| #8 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #9 GestureDetector "icon:0xe3e4" | ui-change |
| #10 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_video_self_cam_off

| button | effect |
|---|---|
| #0 GestureDetector "Speaker / icon:0xe6c5 / Speaker" | ui-change |
| #1 GestureDetector "icon:0xe6c5" | ui-change |
| #2 GestureDetector "Camera / icon:0xf48b / Camera" | ui-change |
| #3 GestureDetector "icon:0xf48b" | ui-change |
| #4 GestureDetector "Voice only / icon:0xf290 / Voice only" | ui-change |
| #5 GestureDetector "icon:0xf290" | ui-change |
| #6 GestureDetector "Mute / icon:0xe3e5 / Mute" | ui-change |
| #7 GestureDetector "icon:0xe3e5" | ui-change |
| #8 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_notice_declined

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_notice_premium

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_notice_camera

| button | effect |
|---|---|
| #0 GestureDetector "Speaker / icon:0xe6c5 / Speaker" | ui-change |
| #1 GestureDetector "icon:0xe6c5" | ui-change |
| #2 GestureDetector "Camera / icon:0xf48b / Camera" | ui-change |
| #3 GestureDetector "icon:0xf48b" | ui-change |
| #4 GestureDetector "Voice only / icon:0xf290 / Voice only" | ui-change |
| #5 GestureDetector "icon:0xf290" | ui-change |
| #6 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #7 GestureDetector "icon:0xe3e4" | ui-change |
| #8 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_quality_poor

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_route_bluetooth

| button | effect |
|---|---|
| #0 GestureDetector "Bluetooth / icon:0xe0e5 / Bluetooth" | ui-change |
| #1 GestureDetector "icon:0xe0e5" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_reconnecting

| button | effect |
|---|---|
| #0 GestureDetector "Earpiece / icon:0xf28c / Earpiece" | ui-change |
| #1 GestureDetector "icon:0xf28c" | ui-change |
| #2 GestureDetector "Video / icon:0xf48c / Video" | ui-change |
| #3 GestureDetector "icon:0xf48c" | ui-change |
| #4 GestureDetector "Mute / icon:0xe3e4 / Mute" | ui-change |
| #5 GestureDetector "icon:0xe3e4" | ui-change |
| #6 InkWell "icon:0xe127 key=call-hangup" | pop:page, platform:com.assisto/lockscreen#release, ui-change |

## b1_call_mini_bar

| button | effect |
|---|---|
| #0 InkWell "icon:0xe126 / Nadia · 04:07 / Tap to return to the call key=call-mini-bar" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 InkWell "icon:0xe127 key=call-mini-hangup" | ui-change |

## home_hero_ad_free

| button | effect |
|---|---|
| #0 TextButton "icon:0xe683 / Edit" | push:sheet, ui-change |
| #1 InkWell "icon:0xee66 / Reminders" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #2 InkWell "icon:0xee33 / Account & Finance" | push:page, ui-change |
| #3 InkWell "icon:0xef4a / Notes/Tasks" | push:page, ui-change |
| #4 InkWell "icon:0xeea9 / Assisto AI" | push:page, ui-change |
| #5 InkWell "icon:0xf089f / Family" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #6 InkWell "icon:0xe3b1 / Documents" | push:page, platform:plugins.it_nomads.com/flutter_secure_storage#read, ui-change, ERROR:async: MissingPluginException(No implementation found for method read on channel plugins.it_nomads.com/flutter_secure_storage) |
| #7 FilledButton "Install" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #8 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #9 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #10 IconButton "icon:0xe0a0" | ui-change |
| #11 IconButton "tip:Photo Studio / icon:0xeeab" | push:page, api:GET /photo-studio/config, net, ui-change |
| #12 IconButton "tip:Notifications / icon:0xf237" | push:page, api:GET /notif/reminders POST /notif/opened GET /notif/feed, net, ui-change |
| #13 IconButton "tip:My Circle / icon:0xf08a1" | push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, ui-change |

## home_hero_premium

| button | effect |
|---|---|
| #0 TextButton "icon:0xe683 / Edit" | push:sheet, ui-change |
| #1 InkWell "icon:0xee66 / Reminders" | push:page, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #2 InkWell "icon:0xee33 / Account & Finance" | push:page, ui-change |
| #3 InkWell "icon:0xef4a / Notes/Tasks" | push:page, ui-change |
| #4 InkWell "icon:0xeea9 / Assisto AI" | push:page, ui-change |
| #5 InkWell "icon:0xf089f / Family" | push:page, api:LIST medicines LIST family LIST school, ui-change |
| #6 InkWell "icon:0xe3b1 / Documents" | push:page, platform:plugins.it_nomads.com/flutter_secure_storage#read, ui-change, ERROR:async: MissingPluginException(No implementation found for method read on channel plugins.it_nomads.com/flutter_secure_storage) |
| #7 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #8 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #9 IconButton "icon:0xe0a0" | ui-change |
| #10 IconButton "tip:Photo Studio / icon:0xeeab" | push:page, api:GET /photo-studio/config, net, ui-change |
| #11 IconButton "tip:Notifications / icon:0xf237" | push:page, api:GET /notif/reminders POST /notif/opened GET /notif/feed, net, ui-change |
| #12 IconButton "tip:My Circle / icon:0xf08a1" | push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, ui-change |

## chat_photo_free_unavailable

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe4ce / Watch 2 ads" | ui-change |
| #1 OutlinedButton "Use 3 credits" | ui-change |

## chat_photo_free_ondevice

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe4ce / Watch 2 ads" | ui-change |
| #1 OutlinedButton "Use 3 credits" | ui-change |

## chat_photo_free_credits_only

| button | effect |
|---|---|
| #0 OutlinedButton "Use 3 credits" | ui-change |

## fm_settings

| button | effect |
|---|---|
| #2 InkWell "English / icon:0xe503" | SKIP:already the selected option |
| #3 InkWell "icon:0xe503 / System default" | SKIP:already the selected option |
| #0 ListTile "A / Arif / 01712345678" | push:page, api:GET /me, net, ui-change |
| #1 InkWell "বাংলা / icon:0xe504 / Bangla" | net, platform:plugins.it_nomads.com/flutter_secure_storage#write, ui-change |
| #4 InkWell "icon:0xe504 / Light" | ui-change |
| #5 InkWell "icon:0xe504 / Dark" | ui-change |
| #6 SwitchListTile "icon:0xe222 / Simple mode (for elders) / Large text, big buttons, only…" | push:dialog, ui-change |
| #7 ListTile "icon:0xee2e / Accessibility mode / Larger text, higher contrast, less …" | push:page, ui-change |
| #8 ListTile "icon:0xf234 / Notifications & calls / Messages, calls, reminders and f…" | push:page, api:GET /push/status, net, platform:dexterous.com/flutter/local_notifications#areNotificationsEnabled, ui-change |
| #9 ListTile "icon:0xe2e3 / Voice assistant / Default assistant, “Hey Assisto”, spok…" | push:page, api:GET /voice/config, net, platform:com.assisto/voice#ping, ui-change |
| #10 ListTile "icon:0xf47d / Digital security check-up / Review your security habits …" | push:page, api:LIST security/checklist, ui-change |
| #11 ListTile "icon:0xf379 / Trust & transparency / What Assisto does — and never doe…" | push:page, ui-change |
| #12 ListTile "icon:0xf2ef / What the agent did (audit log)" | push:page, api:GET /actions/pending, net, ui-change |
| #13 ListTile "icon:0xef61 / Offline & data / These modules work offline" | push:page, ui-change |
| #14 ListTile "icon:0xf132 / Analytics" | push:page, api:GET /analytics/dashboard, ui-change |
| #15 ListTile "icon:0xeeb8 / About the name" | push:page, api:GET /name/about, ui-change |
| #16 ListTile "icon:0xeff2 / Export my data / All your information as JSON" | snackbar, net, ui-change |
| #17 ListTile "icon:0xf023 / Encrypted backup & phone transfer / Passphrase-encrypted…" | push:page, ui-change |
| #18 ListTile "icon:0xf41d / Export to Excel" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #19 ListTile "icon:0xf2a4 / Export to PDF" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #20 ListTile "icon:0xeedd / AI credits / Balance, top-up packs & this month's usage" | SKIP:could not scroll it into view |
| #21 TextButton "Retry" | SKIP:could not scroll it into view |
| #22 ListTile "icon:0xe0c1 / Subscriptions / Track recurring bills so nothing surpris…" | SKIP:could not scroll it into view |

## fm_msgr_settings

| button | effect |
|---|---|
| #0 ListTile "A / Arif / 01712345678" | push:page, api:GET /me, net, ui-change |
| #1 ListTile "icon:0xf0624 / Account / Security, data, delete account" | push:page, ui-change |
| #2 ListTile "icon:0xe3b1 / Privacy / Last seen, online, read receipts, who can see" | push:page, ui-change |
| #3 ListTile "icon:0xef44 / Chats / Your conversations" | push:page, ui-change |
| #4 ListTile "icon:0xf237 / Notifications / Message and call alerts" | push:page, api:GET /circle/settings/notifications, platform:com.assisto/c3_messaging#bubblesSupported, ui-change |
| #5 ListTile "icon:0xef1a / Calls / Incoming calls, silence unknown" | push:page, api:GET /circle/settings/calls, ui-change |
| #6 ListTile "icon:0xefa4 / Storage & data / Usage & media auto-download" | push:page, api:GET /circle/settings/storage, ui-change |
| #7 ListTile "icon:0xf14f / Language / English" | push:sheet, ui-change |
| #8 ListTile "icon:0xe30b / Help / Report a problem or send feedback" | push:page, ui-change |
| #9 ListTile "icon:0xef2d / Invite a friend / Share your invite code" | push:dialog, ui-change |

## fm_msgr_profile

| button | effect |
|---|---|
| #3 ChoiceChip "My circle" | SKIP:already the selected option |
| #6 ChoiceChip "My circle" | SKIP:already the selected option |
| #0 InkWell "icon:0xf29b" | push:sheet, ui-change |
| #1 TextButton "Change photo" | push:sheet, ui-change |
| #2 InkWell "icon:0xe3b1 / Who sees each field is set per field. / Open privacy set…" | push:page, ui-change |
| #4 ChoiceChip "Family only" | ui-change |
| #5 ChoiceChip "Nobody" | ui-change |
| #7 ChoiceChip "Family only" | ui-change |
| #8 ChoiceChip "Nobody" | ui-change |
| #9 FilledButton "Save" | snackbar, net, ui-change |

## fb_sheet

| button | effect |
|---|---|
| #0 ChoiceChip "Problem / icon:0xef04 key=fb-cat-bug" | SKIP:already the selected option |
| #1 ChoiceChip "Idea / icon:0xe37c key=fb-cat-idea" | ui-change |
| #2 ChoiceChip "Other / icon:0xe155 key=fb-cat-other" | ui-change |
| #3 TextButton "icon:0xf647 / Remove key=fb-shot-remove" | ui-change |
| #4 FilledButton "icon:0xf0147 / Send key=fb-send" | ui-change |

## fb_sheet_error

| button | effect |
|---|---|
| #2 ChoiceChip "Other / icon:0xe155 key=fb-cat-other" | SKIP:already the selected option |
| #0 ChoiceChip "Problem / icon:0xef04 key=fb-cat-bug" | ui-change |
| #1 ChoiceChip "Idea / icon:0xe37c key=fb-cat-idea" | ui-change |
| #3 TextButton "icon:0xf647 / Remove key=fb-shot-remove" | ui-change |
| #4 TextButton "icon:0xf00e9 / Try again key=fb-retry" | ui-change |
| #5 FilledButton "icon:0xf0147 / Send key=fb-send" | ui-change |

## fb_screen

| button | effect |
|---|---|
| #1 ChoiceChip "Idea / icon:0xe37c key=fb-cat-idea" | SKIP:already the selected option |
| #0 ChoiceChip "Problem / icon:0xef04 key=fb-cat-bug" | ui-change |
| #2 ChoiceChip "Other / icon:0xe155 key=fb-cat-other" | ui-change |
| #3 FilledButton "icon:0xf0147 / Send key=fb-send" | ui-change |

## pay_sheet_play

| button | effect |
|---|---|
| #0 InkWell "icon:0xf37b / Google Play / Pay with your Google Play account key=pay-option-play" | ui-change |
| #1 InkWell "icon:0xee33 / bKash / Nagad / Card — EPS / Secure EPS payment page key=pay-option-gateway" | platform:plugins.flutter.io/url_launcher#launch, ui-change |

## pay_sheet_apk

| button | effect |
|---|---|
| #0 InkWell "icon:0xee33 / bKash / Nagad / Card — EPS / Secure EPS payment page key=pay-option-gateway" | platform:plugins.flutter.io/url_launcher#launch, ui-change |

## pay_sheet_play_gw_off

| button | effect |
|---|---|
| #0 InkWell "icon:0xf37b / Google Play / Pay with your Google Play account key=pay-option-play" | ui-change |

## pay_sheet_pack

| button | effect |
|---|---|
| #0 InkWell "icon:0xf37b / Google Play / Pay with your Google Play account key=pay-option-play" | ui-change |
| #1 InkWell "icon:0xee33 / bKash / Nagad / Card — EPS / Secure EPS payment page key=pay-option-gateway" | platform:plugins.flutter.io/url_launcher#launch, ui-change |

## oem_guide_samsung_done

| button | effect |
|---|---|
| #0 InkWell "icon:0xe156 / Samsung" | SKIP:already the selected option |
| #1 InkWell "Xiaomi / Redmi / POCO" | ui-change |
| #2 InkWell "OPPO" | ui-change |
| #3 InkWell "realme" | ui-change |
| #4 InkWell "OnePlus" | ui-change |
| #5 InkWell "vivo / iQOO" | ui-change |
| #6 InkWell "Infinix / Tecno / itel" | ui-change |
| #7 InkWell "Other (Walton, Symphony, Nokia…)" | ui-change |
| #8 FilledButton "icon:0xe45c / Open" | state-change |

## oem_guide_walton_allset

| button | effect |
|---|---|
| #7 InkWell "icon:0xe156 / Other (Walton, Symphony, Nokia…)" | SKIP:already the selected option |
| #0 InkWell "Samsung" | ui-change |
| #1 InkWell "Xiaomi / Redmi / POCO" | ui-change |
| #2 InkWell "OPPO" | ui-change |
| #3 InkWell "realme" | ui-change |
| #4 InkWell "OnePlus" | ui-change |
| #5 InkWell "vivo / iQOO" | ui-change |
| #6 InkWell "Infinix / Tecno / itel" | ui-change |

## p1_agent_home

| button | effect |
|---|---|
| #0 SwitchListTile "AI replies on / The AI answers customer messages; risky replies wait f…" | snackbar, api:POST /bizagent/settings GET /bizagent/setup?flavour=apk GET /bizagent/reports, ui-change |
| #1 ListTile "icon:0xf045 / Waiting for approval / 2 replies waiting for your approv…" | push:page, api:GET /bizagent/approvals, ui-change |
| #2 ListTile "icon:0xf126 / Customer chats / Conversations from every channel; reply…" | push:page, api:GET /bizagent/threads, ui-change |
| #3 ListTile "icon:0xf466 / Agent setup / Channels, delivery charges, policies, cour…" | push:page, api:GET /bizagent/setup?flavour=apk, ui-change |
| #4 IconButton "tip:Agent setup / icon:0xf466" | push:page, api:GET /bizagent/setup?flavour=apk, ui-change |

## p1_agent_first_run

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf0653 / Start the 7-day free trial (100 replies)" | snackbar, api:POST /bizagent/plan/trial GET /bizagent/setup?flavour=apk GET /bizagent/reports, ui-change |
| #1 SwitchListTile "AI replies on / AI is off. Messages are saved and you reply yourself." | snackbar, api:POST /bizagent/settings GET /bizagent/setup?flavour=apk GET /bizagent/reports, ui-change |
| #2 ListTile "icon:0xf045 / Waiting for approval / Nothing waiting right now" | push:page, api:GET /bizagent/approvals, ui-change |
| #3 ListTile "icon:0xf126 / Customer chats / Conversations from every channel; reply…" | push:page, api:GET /bizagent/threads, ui-change |
| #4 ListTile "icon:0xf466 / Agent setup / Channels, delivery charges, policies, cour…" | push:page, api:GET /bizagent/setup?flavour=apk, ui-change |
| #5 IconButton "tip:Agent setup / icon:0xf466" | push:page, api:GET /bizagent/setup?flavour=apk, ui-change |

## p1_agent_setup

| button | effect |
|---|---|
| #0 Switch "" | api:POST /bizagent/channels/1/toggle GET /bizagent/setup?flavour=apk, state-change |
| #1 IconButton "tip:Disconnect / icon:0xe381" | push:dialog, ui-change |
| #2 Switch "" | api:POST /bizagent/channels/2/toggle GET /bizagent/setup?flavour=apk, state-change |
| #3 IconButton "tip:Disconnect / icon:0xe381" | push:dialog, ui-change |
| #4 OutlinedButton "icon:0xf0b0 / Connect Facebook Page" | push:sheet, ui-change |
| #5 OutlinedButton "icon:0xef1e / Connect Instagram" | push:sheet, ui-change |
| #6 OutlinedButton "icon:0xef44 / Connect WhatsApp Business" | push:sheet, ui-change |
| #7 SwitchListTile "Cash on delivery" | ui-change |
| #8 SwitchListTile "Payment link / Only through a licensed partner. Assisto never holds mo…" | ui-change |
| #9 SwitchListTile "Open 24 hours / The AI always answers. With shop hours set, customers …" | ui-change |
| #10 OutlinedButton "icon:0xe556 / Opens 10:00" | push:dialog, ui-change |
| #11 OutlinedButton "icon:0xe556 / Closes 22:00" | push:dialog, ui-change |
| #12 SwitchListTile "I approve every reply / When on, no AI reply goes out without your app…" | ui-change |
| #13 SwitchListTile "Low-stock alert" | ui-change |
| #14 SwitchListTile "End-of-day sales summary" | ui-change |
| #15 ListTile "Pathao / Not connected / icon:0xe246" (scrolled) | ui-change |
| #16 ListTile "Steadfast / Connected / icon:0xe246" (scrolled) | ui-change |
| #17 ListTile "RedX / Not connected / icon:0xe246" (scrolled) | ui-change |
| #18 FilledButton "icon:0xf334 / Save setup" | snackbar, api:POST /bizagent/settings, ui-change |

## p1_agent_approvals

| button | effect |
|---|---|
| #0 TextButton "Reject" | snackbar, api:POST /bizagent/approvals/11/reject GET /bizagent/approvals, ui-change |
| #1 FilledButton "icon:0xf355 / Approve and send" | snackbar, api:POST /bizagent/approvals/11/approve GET /bizagent/approvals, ui-change |
| #2 TextButton "Reject" | snackbar, api:POST /bizagent/approvals/12/reject GET /bizagent/approvals, ui-change |
| #3 FilledButton "icon:0xf355 / Approve and send" | snackbar, api:POST /bizagent/approvals/12/approve GET /bizagent/approvals, ui-change |

## p1_agent_inbox

| button | effect |
|---|---|
| #0 ListTile "icon:0xf0b0 / Nasrin / yes" | push:page, api:GET /bizagent/threads/5, ui-change |
| #1 ListTile "icon:0xef44 / Rahim / You are handling · I want a refund" | push:page, api:GET /bizagent/threads/6, ui-change |

## p1_agent_chat

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xf3a8 / AI is replying / Switch on to reply yourself; the AI pau…" | snackbar, api:POST /bizagent/threads/5/handover GET /bizagent/threads/5, ui-change |

## ai_chat

| button | effect |
|---|---|
| #0 InkWell "icon:0xf05f0 / Write a polite leave application for tomorrow" | api:POST /chat/sessions, net, ui-change |
| #1 InkWell "icon:0xf3ff / Summarise my reminders and spending this week" | api:POST /chat/sessions, net, ui-change |
| #2 InkWell "icon:0xef27 / Draft a Facebook post for my shop's Eid offer" | api:POST /chat/sessions, net, ui-change |
| #3 InkWell "icon:0xf2ef / Explain my electricity bill in simple words" | api:POST /chat/sessions, net, ui-change |
| #4 IconButton "tip:Attach a photo / icon:0xee48" | push:sheet, ui-change |
| #5 IconButton "tip:Hold to talk, release to stop / icon:0xe3e4" | push:dialog, ui-change |
| #6 IconButton "tip:Send / icon:0xe0a0" | ui-change |
| #7 IconButton "tip:Chat history / icon:0xe314" | push:sheet, ui-change |
| #8 IconButton "tip:New chat / icon:0xee41" | ui-change |

## nearby

| button | effect |
|---|---|
| #2 ChoiceChip "All" | SKIP:already the selected option |
| #0 TextButton "Enable" | platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, state-change |
| #1 FilterChip "Favourites / icon:0xe5f9" | ui-change |
| #3 ChoiceChip "Hospital / icon:0xf17e" | ui-change |
| #4 ChoiceChip "Pharmacy / icon:0xf186" | ui-change |
| #5 ChoiceChip "ATM / Bank / icon:0xee9f" (scrolled) | ui-change |
| #6 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #7 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #8 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #9 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #10 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #11 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #12 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #13 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #14 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #15 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #16 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #17 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #18 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #19 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #20 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #21 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #22 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #23 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #24 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #25 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #26 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #27 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #28 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #29 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #30 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #31 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #32 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #33 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #34 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #35 OutlinedButton "icon:0xe126 / Call" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #36 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #37 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #38 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #39 IconButton "tip:Save / icon:0xe5fa" | ui-change |
| #40 FilledButton "icon:0xe1d1 / Directions" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #41 IconButton "tip:Save / icon:0xe5fa" | SKIP:could not scroll it into view |
| #42 OutlinedButton "icon:0xe126 / Call" | SKIP:could not scroll it into view |
| #43 FilledButton "icon:0xe1d1 / Directions" | SKIP:could not scroll it into view |
| #44 IconButton "tip:Save / icon:0xe5fa" | SKIP:could not scroll it into view |
| #45 FilledButton "icon:0xe1d1 / Directions" | SKIP:could not scroll it into view |
| #46 PopupMenuButton "tip:Sort by / icon:0xe5d2" | push:popup, ui-change |

## used_phone_check

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe567 / Check" | ui-change |
| #1 TextButton "icon:0xf30d / Lost or stolen your own phone? Report it" | push:page, ui-change |

## at_protection_off

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf379 / Turn on" | push:dialog, ui-change |
| #1 ListTile "icon:0xf47d / Turn on your phone maker's lock too / Samsung, Xiaomi an…" | push:page, ui-change |

## at_protection_on

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xf196 / Turn off" | push:dialog, ui-change |
| #1 SwitchListTile "Lock the screen on a snatch / If a grab-and-run is detected, lock the …" | push:dialog, ui-change |
| #2 SwitchListTile "Take an intruder photo / Off until you turn it on. After several wrong…" | push:dialog, ui-change |
| #3 CheckboxListTile "Dad" | push:dialog, ui-change |
| #4 CheckboxListTile "Brother" | push:dialog, ui-change |
| #5 ListTile "icon:0xf444 / Protection timeline / Every check-in and alert, with hon…" | push:page, api:GET /security/engine/timeline, ui-change |
| #6 ListTile "icon:0xf47d / Turn on your phone maker's lock too / Samsung, Xiaomi an…" | push:page, ui-change |

## vehicles

| button | effect |
|---|---|
| #2 InkWell "My Vehicles / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "icon:0xe047 / Add vehicle" | push:sheet, ui-change |
| #1 IconButton "tip:Live tracking / icon:0xe2dc" | push:page, api:GET /vehicle/trackers, ui-change |
| #3 InkWell "Buying guide / Tab 2 of 2" | ui-change |

## smartwatch

| button | effect |
|---|---|
| #0 FilledButton "icon:0xeff2 / Install Health Connect" | platform:flutter_health#installHealthConnect |

## unseen

| button | effect |
|---|---|
| #0 TextButton "Enable" | platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, state-change |
| #1 InkWell "icon:0xe0f4 / Wishlist" | ui-change |
| #2 InkWell "icon:0xee80 / All" | state-change |
| #3 InkWell "icon:0xf0603 / Nature" | ui-change |
| #4 InkWell "icon:0xee32 / Historical" | ui-change |
| #5 InkWell "icon:0xeec6 / Beach" (scrolled) | ui-change |
| #6 InkWell "icon:0xf42b / Hill" | SKIP:could not scroll it into view |
| #7 InkWell "icon:0xf0636 / Religious" | SKIP:could not scroll it into view |
| #8 IconButton "tip:Add to wishlist / icon:0xe0f4" | ui-change |
| #9 TextButton "icon:0xf1ae / Directions" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #10 TextButton "icon:0xf378 / Share" | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |
| #11 IconButton "tip:Add to wishlist / icon:0xe0f4" | ui-change |
| #12 TextButton "icon:0xf1ae / Directions" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #13 TextButton "icon:0xf378 / Share" | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |
| #14 IconButton "tip:Add to wishlist / icon:0xe0f4" | ui-change |
| #15 TextButton "icon:0xf1ae / Directions" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #16 TextButton "icon:0xf378 / Share" | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |
| #17 ListTile "icon:0xf0603 / Srimangal → Jaflong → Ratargul Swamp Forest / 3 days  •…" | ui-change |
| #18 ListTile "icon:0xf42b / Sajek Valley → Nafakhum Waterfall / 4 days  •  Approx. c…" | ui-change |
| #19 ListTile "icon:0xee32 / Mahasthangarh → Paharpur (Somapura Mahavihara) / 3 days …" | ui-change |
| #20 ListTile "icon:0xeec6 / Kuakata → Nijhum Dwip / 3 days  •  Approx. cost: BDT 700…" | ui-change |
| #21 IconButton "tip:Add to wishlist / icon:0xe0f4" | ui-change |
| #22 TextButton "icon:0xf1ae / Directions" (scrolled) | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #23 TextButton "icon:0xf378 / Share" (scrolled) | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |
| #24 IconButton "tip:Add to wishlist / icon:0xe0f4" (scrolled) | ui-change |
| #25 TextButton "icon:0xf1ae / Directions" (scrolled) | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #26 TextButton "icon:0xf378 / Share" (scrolled) | snackbar, platform:dev.fluttercommunity.plus/share#share flutter/platform#Clipboard.setData, ui-change |
| #27 PopupMenuButton "tip:Division / icon:0xf068" | push:popup, ui-change |

## biz_hub

| button | effect |
|---|---|
| #0 IconButton "tip:Add another business / icon:0xee3d" | push:page, ui-change |
| #1 InkWell "icon:0xf1c2 / Digital Khata / Dues, payables and reminders in one plac…" | push:page, api:GET /business/khata/parties?business_id=1&book=customer GET /business/khata/net-position?business_id=1, ui-change |
| #2 InkWell "icon:0xf2bb / Selling / Products, cart and quick sell" | push:sheet, ui-change |
| #3 InkWell "icon:0xee33 / Cashbox / Reconcile daily cash in and out" | push:page, api:GET /business/cashbox/2026-10-23?business_id=1, ui-change |
| #4 InkWell "icon:0xf132 / Reports / Sales, profit and top products at a glance" | push:page, api:GET /business/reports?period=daily&business=1, ui-change |
| #5 InkWell "icon:0xf134 / Suppliers & wholesale market / Keep your supplier list, …" | push:page, api:LIST supplier/vendors, ui-change |
| #6 InkWell "icon:0xf132 / Demand map / Log product demand by area and time, and se…" | push:page, api:LIST demand/signals, ui-change |
| #7 InkWell "icon:0xf06a4 / Bargaining rules / Set per-product price floors and dis…" | push:page, api:GET /business/bargain/rules, ui-change |
| #8 InkWell "icon:0xf3a8 / AI assistant / Auto-replies and bargaining with customer…" | push:page, api:GET /business/ai/channels GET /business/ai/threads, ui-change |
| #9 InkWell "icon:0xf403 / AI sales agent / 24/7 replies, orders and courier on Fac…" | push:page, api:GET /bizagent/setup?flavour=apk GET /bizagent/reports, ui-change |
| #10 InkWell "icon:0xf06a1 / Plans / Compare Free vs Premium Business" | push:page, ui-change |
| #11 InkWell "icon:0xf466 / Business setup / Add your name, type and payment details" | push:page, ui-change |
| #12 IconButton "tip:Business setup / icon:0xf36e" | push:page, ui-change |

## biz_products

| button | effect |
|---|---|
| #0 ChoiceChip "Category" | SKIP:already the selected option |
| #1 ChoiceChip "Clothing" | api:GET /business/products?business=1&category=Clothing, ui-change |
| #2 InkWell "icon:0xf134 / Panjabi / Selling price: ৳1,200" | push:sheet, ui-change |
| #3 InkWell "icon:0xf134 / Saree / Selling price: ৳2,500" | push:sheet, ui-change |
| #4 FAB "icon:0xe047 / Add product" | push:sheet, ui-change |

## biz_khata

| button | effect |
|---|---|
| #4 InkWell "Customers (Dues) / Tab 1 of 2" | SKIP:already the selected option |
| #0 TextButton "icon:0xef27 / Remind everyone" | ui-change |
| #1 ListTile "K / Karim Store / icon:0xe5f9" | push:page, api:GET /business/khata/parties/1/statement, ui-change |
| #2 ListTile "R / Rahim Traders / Settled" | push:page, api:GET /business/khata/parties/2/statement, ui-change |
| #3 FAB "icon:0xe494" | push:sheet, ui-change |
| #5 InkWell "Suppliers (Payables) / Tab 2 of 2" | api:GET /business/khata/parties?business_id=1&book=supplier GET /business/khata/net-position?business_id=1, ui-change |

## biz_cashbox

| button | effect |
|---|---|
| #0 IconButton "icon:0xe15e" | api:GET /business/cashbox/2026-10-22?business_id=1, ui-change |
| #1 TextButton "Edit" | push:dialog, ui-change |
| #2 FilledButton "icon:0xe047 / Cash in" | push:sheet, ui-change |
| #3 FilledButton "icon:0xe516 / Cash out" | push:sheet, ui-change |
| #4 OutlinedButton "icon:0xf045 / End-of-day reconcile" | push:dialog, ui-change |

## biz_customers

| button | effect |
|---|---|
| #0 InkWell "icon:0xe5f9 / Nadia / VIP" | push:sheet, api:GET /business/customers/01712345678/history, ui-change |
| #1 IconButton "icon:0xf00d" | push:sheet, ui-change |
| #2 FAB "icon:0xe493 / Add customer" | push:sheet, ui-change |

## biz_quick_sell

| button | effect |
|---|---|
| #0 InkWell "icon:0xf134 / Panjabi / ৳1,200" | push:sheet, ui-change |
| #1 InkWell "icon:0xf134 / Saree / ৳2,500" | api:POST /business/cart/add, state-change |

## biz_reports

| button | effect |
|---|---|
| #0 IconButton "tip:Share / icon:0xe34d key=q1-report-share" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |

## biz_orders

| button | effect |
|---|---|
| #0 ListTile "#101 · Nadia / ৳2,400 / Order received" | push:page, api:GET /business/orders/101 GET /business/orders/101/parcel, ui-change |
| #1 ListTile "#102 · Sumon / ৳1,250 / Shipped via courier" | push:page, api:GET /business/orders/102 GET /business/orders/102/parcel, ui-change |

## biz_payments

| button | effect |
|---|---|
| #0 TextButton "Edit" | push:sheet, ui-change |

## money_report

| button | effect |
|---|---|
| #0 IconButton "tip:PDF / icon:0xf2a4" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #1 IconButton "tip:Excel / icon:0xf41d" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |

## money_networth

| button | effect |
|---|---|
| #0 IconButton "icon:0xe62f" | state-change |

## money_trends

| button | effect |
|---|---|
| #0 IconButton "tip:Monthly report / icon:0xefae" | push:page, ui-change |
| #1 IconButton "icon:0xe62f" | state-change |

## money_loan_detail

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe1f7 / Mark settled" | ERROR:async: Bad state: databaseFactory not initialized |
| #1 FAB "icon:0xe047 / Add repayment" | push:dialog, ui-change |

## biz_products_empty

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add product" | push:sheet, ui-change |
| #1 FAB "icon:0xe047 / Add product" | push:sheet, ui-change |

## biz_khata_error

| button | effect |
|---|---|
| #1 InkWell "Customers (Dues) / Tab 1 of 2" | SKIP:already the selected option |
| #0 FilledButton "Retry" | api:GET /business/khata/parties?business_id=1&book=customer, state-change |
| #2 InkWell "Suppliers (Payables) / Tab 2 of 2" | api:GET /business/khata/parties?business_id=1&book=supplier, state-change |

## biz_reports_loading

| button | effect |
|---|---|
| #0 IconButton "tip:Share / icon:0xe34d key=q1-report-share" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |

## crm_home

| button | effect |
|---|---|
| #4 InkWell "icon:0xf44d / Today / Tab 1 of 11" | SKIP:already the selected option |
| #0 ListTile "95 / Karim Garments / Karim Garments Ltd · RMG" | push:page, api:GET /crm/leads/1/ GET /crm/leads/1/timeline/ GET /crm/leads/1/followup/, ui-change |
| #1 IconButton "tip:Call / icon:0xe126" | snackbar, api:POST /crm/leads/1/log_action/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #2 IconButton "tip:WhatsApp / icon:0xe153" | push:sheet, api:GET /crm/leads/1/whatsapp_status/, net, ui-change |
| #3 ListTile "icon:0xe556 / Shop 365 / Next follow-up: Oct 13, 2026" | push:page, api:GET /crm/leads/3/ GET /crm/leads/3/timeline/ GET /crm/leads/3/followup/, ui-change |
| #5 InkWell "icon:0xf26a / Leads / Tab 2 of 11" | api:LIST crm/leads?org=1, ui-change |
| #6 InkWell "icon:0xefe3 / Companies / Tab 3 of 11" | api:LIST crm/companies?org=1 LIST crm/contacts?org=1, ui-change |
| #7 InkWell "icon:0xf0690 / Pipeline / Tab 4 of 11" | api:LIST crm/pipelines?org=1 LIST crm/deals?org=1&pipeline=1, ui-change |
| #8 InkWell "icon:0xf132 / Dashboard / Tab 5 of 11" (scrolled) | api:GET /crm/dashboard?org=1, ui-change |
| #9 InkWell "icon:0xeebc / Reports / Tab 6 of 11" (scrolled) | api:GET /crm/dashboard?org=1, ui-change |
| #10 InkWell "icon:0xf0db / Team / Tab 7 of 11" (scrolled) | api:LIST crm/members?org=1 LIST crm/routing-rules?org=1 GET /crm/orgs/1/invite/, net, ui-change |
| #11 InkWell "icon:0xee3c / Lead capture / Tab 8 of 11" (scrolled) | ui-change |
| #12 InkWell "icon:0xf403 / After-sale / Tab 9 of 11" (scrolled) | api:LIST crm/installments?org=1 GET /crm/collections/summary?org=1, net, ui-change |
| #13 InkWell "icon:0xf158 / Team management / Tab 10 of 11" (scrolled) | api:LIST crm/members?org=1 LIST crm/targets?org=1, ui-change |
| #14 InkWell "icon:0xeedd / Automation rules / Tab 11 of 11" (scrolled) | api:LIST crm/automation-rules?org=1, ui-change |

## crm_lead_detail

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe126 / Call" | snackbar, api:POST /crm/leads/1/log_action/ GET /crm/leads/1/ GET /crm/leads/1/timeline/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #1 OutlinedButton "icon:0xe153 / WhatsApp" | push:sheet, api:GET /crm/leads/1/whatsapp_status/, net, ui-change |
| #2 OutlinedButton "icon:0xe3c4 / Email" | snackbar, api:POST /crm/leads/1/log_action/ GET /crm/leads/1/ GET /crm/leads/1/timeline/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #3 InkWell "icon:0xf02f / Next follow-up: Oct 14, 2026 / icon:0xf00d" | push:sheet, ui-change |
| #4 FilledButton "icon:0xefae / Proposals" | push:page, api:LIST crm/proposals?org=1&lead=1 LIST crm/products?org=1, ui-change |
| #5 OutlinedButton "icon:0xeea8 / Quote versions" | push:page, api:LIST crm/proposals?lead=1, ui-change |
| #6 OutlinedButton "icon:0xf01a / Won — hand off to ERP" | push:dialog, ui-change |
| #7 OutlinedButton "icon:0xef28 / Lost" | push:dialog, ui-change |
| #8 IconButton "icon:0xf00d" | push:page, ui-change |
| #9 FAB "icon:0xe05b / Log activity" | push:sheet, ui-change |

## biz_order_detail

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe09b / Advance to confirmed" | api:POST /business/orders/101/advance GET /business/orders/101 GET /business/orders/101/parcel, state-change |

## money_import

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe0b7 / Read SMS" | ui-change |

## shop_cameras

| button | effect |
|---|---|
| #5 InkWell "Cameras / Tab 2 of 4" | SKIP:already the selected option |
| #0 ListTile "icon:0xf48c / Cash counter / Shop Box  ·  On" | push:sheet, api:GET /shop/cameras/1, ui-change |
| #1 ListTile "icon:0xf48c / Back door / Edge camera  ·  On" | push:sheet, api:GET /shop/cameras/2, ui-change |
| #2 ListTile "icon:0xf48c / Store room / Edge camera  ·  Paused" | push:sheet, api:GET /shop/cameras/3, ui-change |
| #3 FAB "icon:0xee39 / Add camera" | push:dialog, ui-change |
| #4 InkWell "Sites / Tab 1 of 4" | ui-change |
| #6 InkWell "Alerts / Tab 3 of 4" | api:GET /shop/events?site=1, ui-change |
| #7 InkWell "Report / Tab 4 of 4" | api:GET /shop/summary?site=1&days=7, ui-change |

## shop_alerts

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #8 InkWell "Alerts / Tab 3 of 4" | SKIP:already the selected option |
| #1 ChoiceChip "Open" | api:GET /shop/events?site=1&status=open, ui-change |
| #2 ChoiceChip "Checked" | api:GET /shop/events?site=1&status=checked, ui-change |
| #3 ChoiceChip "False alarm" | api:GET /shop/events?site=1&status=false_alarm, ui-change |
| #4 FilledButton "icon:0xe156 / Checked" | snackbar, api:POST /shop/events/9/mark, net, ui-change |
| #5 OutlinedButton "icon:0xe446 / False alarm" | snackbar, api:POST /shop/events/9/mark, net, ui-change |
| #6 InkWell "Sites / Tab 1 of 4" | ui-change |
| #7 InkWell "Cameras / Tab 2 of 4" | api:GET /shop/sites/1/cameras, ui-change |
| #9 InkWell "Report / Tab 4 of 4" | api:GET /shop/summary?site=1&days=7, ui-change |

## shop_report

| button | effect |
|---|---|
| #2 ChoiceChip "7 days" | SKIP:already the selected option |
| #8 InkWell "Report / Tab 4 of 4" | SKIP:already the selected option |
| #0 ListTile "icon:0xf2bb / End-of-day cash check / Compare the drawer with today's …" | push:page, api:GET /shop/sites/1/eod, ui-change |
| #1 ChoiceChip "1 day" | api:GET /shop/summary?site=1&days=1, ui-change |
| #3 ChoiceChip "30 days" | api:GET /shop/summary?site=1&days=30, ui-change |
| #4 ChoiceChip "90 days" | api:GET /shop/summary?site=1&days=90, ui-change |
| #5 InkWell "Sites / Tab 1 of 4" | ui-change |
| #6 InkWell "Cameras / Tab 2 of 4" | api:GET /shop/sites/1/cameras, ui-change |
| #7 InkWell "Alerts / Tab 3 of 4" | api:GET /shop/events?site=1, ui-change |

## crm_leads_empty

| button | effect |
|---|---|
| #0 FilterChip "High priority" | api:LIST crm/leads?org=1&priority=high, ui-change |
| #1 FilterChip "RMG" | api:LIST crm/leads?org=1&industry=rmg, ui-change |
| #2 FilterChip "Pharma" | api:LIST crm/leads?org=1&industry=pharma, ui-change |
| #3 FilterChip "Retail" | api:LIST crm/leads?org=1&industry=retail, ui-change |
| #4 FAB "icon:0xe493 / Add lead" | push:page, ui-change |

## biz_orders_error

| button | effect |
|---|---|
| #0 FilledButton "Retry" | api:GET /business/orders, state-change |

## money_wrapped_data

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe34d / Share this card" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## crm_lead_full

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe126 / Call" | snackbar, api:POST /crm/leads/1/log_action/ GET /crm/leads/1/ GET /crm/leads/1/timeline/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #1 OutlinedButton "icon:0xe153 / WhatsApp" | push:sheet, api:GET /crm/leads/1/whatsapp_status/, net, ui-change |
| #2 OutlinedButton "icon:0xe3c4 / Email" | snackbar, api:POST /crm/leads/1/log_action/ GET /crm/leads/1/ GET /crm/leads/1/timeline/, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #3 InkWell "icon:0xf02f / Next follow-up: Oct 14, 2026 / icon:0xf00d" | push:sheet, ui-change |
| #4 FilledButton "icon:0xefae / Proposals" | push:page, api:LIST crm/proposals?org=1&lead=1 LIST crm/products?org=1, ui-change |
| #5 OutlinedButton "icon:0xeea8 / Quote versions" | push:page, api:LIST crm/proposals?lead=1, ui-change |
| #6 OutlinedButton "icon:0xf01a / Won — hand off to ERP" | push:dialog, ui-change |
| #7 OutlinedButton "icon:0xef28 / Lost" | push:dialog, ui-change |
| #8 IconButton "icon:0xf00d" | push:page, ui-change |
| #9 FAB "icon:0xe05b / Log activity" | push:sheet, ui-change |

## crm_proposal

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xef10 / Build quote" | push:page, ui-change |
| #1 OutlinedButton "Approve" | api:POST /crm/proposals/1/transition/ LIST crm/proposals?org=1&lead=1 LIST crm/products?org=1, state-change |
| #2 FAB "icon:0xeea9 / Draft with AI" | push:dialog, ui-change |

## sheet_product_new

| button | effect |
|---|---|
| #0 GestureDetector "icon:0xee39 / Photo" | platform:plugins.flutter.io/image_picker#pickImage, ERROR:async: MissingPluginException(No implementation found for method pickImage on channel plugins.flutter.io/image_picker) |
| #1 TextButton "icon:0xe047 / Add variant" | ui-change |
| #2 FilledButton "Save" | ui-change |

## sheet_product_edit

| button | effect |
|---|---|
| #0 GestureDetector "icon:0xee39 / Photo" | platform:plugins.flutter.io/image_picker#pickImage, ERROR:async: MissingPluginException(No implementation found for method pickImage on channel plugins.flutter.io/image_picker) |
| #1 TextButton "icon:0xe047 / Add variant" | ui-change |
| #2 IconButton "icon:0xe1bb" | ui-change |
| #3 FilledButton "Save" | ui-change |

## sheet_product_staff

| button | effect |
|---|---|
| #0 GestureDetector "icon:0xee39 / Photo" | platform:plugins.flutter.io/image_picker#pickImage, ERROR:async: MissingPluginException(No implementation found for method pickImage on channel plugins.flutter.io/image_picker) |
| #1 TextButton "icon:0xe047 / Add variant" | ui-change |
| #2 FilledButton "Save" | ui-change |

## sheet_customer_new

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xe5fd / VIP" | ui-change |
| #1 FilledButton "Save" | ui-change |

## sheet_customer_edit

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xe5fd / VIP" | ui-change |
| #1 FilledButton "Save" | pop:page, api:POST /business/customers, ui-change |

## sheet_khata_due

| button | effect |
|---|---|
| #0 ListTile "icon:0xf02f / Date / Oct 23, 2026" | push:dialog, ui-change |
| #1 SwitchListTile "Notify customer when a due is added" | ui-change |
| #2 FilledButton "Save" | snackbar, ui-change |
| #3 GestureDetector "" | ui-change |

## sheet_khata_payment

| button | effect |
|---|---|
| #0 ListTile "icon:0xf02f / Date / Oct 23, 2026" | push:dialog, ui-change |
| #1 FilledButton "Save" | snackbar, ui-change |
| #2 GestureDetector "" | ui-change |

## dialog_sale_void

| button | effect |
|---|---|
| #0 TextButton "Cancel" | pop:page, ui-change |
| #1 GestureDetector "" | ui-change |

## shop_box

| button | effect |
|---|---|
| #1 InkWell "icon:0xf3ef / Mirpur branch / 3 cameras · keeps snapshots 7 days" | SKIP:already the selected option |
| #8 InkWell "Sites / Tab 1 of 4" | SKIP:already the selected option |
| #0 ListTile "icon:0xe4a3 / Use this phone as a Shop Box / Turn a spare Android phon…" | push:page, platform:plugins.it_nomads.com/flutter_secure_storage#read, ui-change |
| #2 TextButton "icon:0xf4aa / Settings & device code" | push:sheet, ui-change |
| #3 TextButton "icon:0xe556 / Hours & POS" | push:sheet, ui-change |
| #4 InkWell "icon:0xf3ef / Warehouse / 1 cameras · keeps snapshots 3 days" | ui-change |
| #5 TextButton "icon:0xf4aa / Settings & device code" | push:sheet, ui-change |
| #6 TextButton "icon:0xe556 / Hours & POS" | push:sheet, ui-change |
| #7 FAB "icon:0xe047 / Add shop" | push:sheet, ui-change |
| #9 InkWell "Cameras / Tab 2 of 4" | api:GET /shop/sites/1/cameras, ui-change |
| #10 InkWell "Alerts / Tab 3 of 4" | api:GET /shop/events?site=1, ui-change |
| #11 InkWell "Report / Tab 4 of 4" | api:GET /shop/summary?site=1&days=7, ui-change |

## shop_eod

| button | effect |
|---|---|
| #0 FilledButton "icon:0xf045 / Check cash" | snackbar, ui-change |

## shop_live_offline

| button | effect |
|---|---|
| #0 OutlinedButton "Close" | pop:page, ui-change |

## shop_mode_pair

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe380 / Check and pair" | ui-change |

## shop_mode_paired

| button | effect |
|---|---|
| #0 SwitchListTile "Shop Box mode / Off — the camera is closed." | net, platform:com.assisto/shopbox#keepScreenOn plugins.flutter.io/camera#availableCameras, ui-change |
| #1 ListTile "icon:0xe1a9 / Cash zone / Not set — during open hours nothing is repor…" | push:dialog, ui-change |
| #2 TextButton "icon:0xe3b3 / Unpair this phone" | platform:com.assisto/shopbox#keepScreenOn plugins.it_nomads.com/flutter_secure_storage#delete, ui-change |

## shop_cam_settings

| button | effect |
|---|---|
| #0 SwitchListTile "Camera on / When off, its signals are ignored and it isn't billed." | snackbar, api:PATCH /shop/cameras/1, net, ui-change |
| #1 SwitchListTile "Staff-only area / A line-crossing here during open hours asks you to c…" | ui-change |
| #2 OutlinedButton "icon:0xf4bc / Opens 9:00 AM" | push:dialog, ui-change |
| #3 OutlinedButton "icon:0xf214 / Closes 10:00 PM" | push:dialog, ui-change |
| #4 TextButton "Use shop hours" | ui-change |
| #5 FilledButton "Save" | snackbar, api:PATCH /shop/cameras/1, net, ui-change |
| #6 OutlinedButton "icon:0xf16f / Live view" | push:page, api:POST /shop/live/start, ui-change |
| #7 IconButton "tip:Copy / icon:0xe190" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #8 IconButton "tip:Copy / icon:0xe190" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #9 IconButton "tip:Copy / icon:0xe190" | snackbar, platform:flutter/platform#Clipboard.setData, ui-change |
| #10 TextButton "icon:0xe0c1 / New token" | push:dialog, ui-change |
| #11 TextButton "icon:0xe1bb / Remove camera" | push:dialog, ui-change |

## veh_tracking

| button | effect |
|---|---|
| #0 InkWell "icon:0xe2dc / Family car / Moving · 38 km/h" | push:page, api:GET /vehicle/trackers/1 GET /vehicle/trackers/1/route?hours=24 GET /vehicle/trackers/1/commands, ui-change |
| #1 InkWell "icon:0xe2dc / Office microbus / Parked" | push:page, api:GET /vehicle/trackers/2 GET /vehicle/trackers/2/route?hours=24 GET /vehicle/trackers/2/commands, ui-change |
| #2 IconButton "tip:Car Mode / icon:0xeff7" | push:page, ui-change |
| #3 IconButton "tip:Fleet dashboard / icon:0xf18e" | push:page, api:GET /vehicle/fleet, ui-change |
| #4 FAB "icon:0xe053 / Pair tracker" | push:sheet, api:LIST vehicle/records, ui-change |

## veh_tracker

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xf1ae / Open in Maps" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #1 IconButton "tip:Play route / icon:0xe4cb" | ui-change |
| #2 PopupMenuButton "tip:Playback speed / 8×" | push:popup, ui-change |
| #3 FilledButton "icon:0xe0e1 / Cut engine" | push:dialog, ui-change |
| #4 OutlinedButton "icon:0xe531 / Restore engine" | push:dialog, ui-change |
| #5 FilledButton "icon:0xe3c7 / Check trips" | api:POST /vehicle/trackers/1/ai-summary, ui-change |
| #6 ListTile "icon:0xe13d / Car health (OBD) / Engine temperature, battery and troub…" | push:page, api:GET /vehicle/trackers/1/obd, ui-change |
| #7 IconButton "tip:Tracker settings / icon:0xe683" | push:page, api:GET /circle/members GET /vehicle/trackers/1/grants, ui-change |

## veh_pair_sheet

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe380 / Start pairing" | ui-change |

## veh_car_mode

| button | effect |
|---|---|
| #0 InkWell "icon:0xf204 / Navigate" | push:dialog, ui-change |
| #1 InkWell "icon:0xe3e4 / Voice assistant" | push:page+push:dialog, platform:com.assisto/voice#isLocked com.assisto/voice#stopSpeaking, ui-change |
| #2 InkWell "icon:0xf0561 / Start trip log" | snackbar, platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, ui-change |
| #3 InkWell "icon:0xe13d / Car health (OBD)" | push:page, ui-change |
| #4 InkWell "icon:0xf48c / Dashcam" | push:page, platform:flutter.baseflow.com/permissions/methods#checkPermissionStatus, ui-change, ERROR:async: MissingPluginException(No implementation found for method checkPermissionStatus on channel flutter.baseflow.com/permissions/methods) |

## veh_fleet

| button | effect |
|---|---|
| #0 ListTile "icon:0xe1d7 / Delivery van 1 / Moving · 38 km/h  ·  72.3 km" | push:page, api:GET /vehicle/trackers/1 GET /vehicle/trackers/1/route?hours=24 GET /vehicle/trackers/1/commands, ui-change |
| #1 ListTile "icon:0xe1d7 / Delivery van 2 / Moving · 38 km/h  ·  64.0 km" | push:page, api:GET /vehicle/trackers/2 GET /vehicle/trackers/2/route?hours=24 GET /vehicle/trackers/2/commands, ui-change |
| #2 ListTile "icon:0xe1d7 / Pickup / Parked  ·  50.1 km" | push:page, api:GET /vehicle/trackers/4 GET /vehicle/trackers/4/route?hours=24 GET /vehicle/trackers/4/commands, ui-change |
| #3 ListTile "icon:0xe1d7 / Owner's car / Offline · last seen 5 h ago  ·  0.0 km" | push:page, api:GET /vehicle/trackers/5 GET /vehicle/trackers/5/route?hours=24 GET /vehicle/trackers/5/commands, ui-change |

## veh_fleet_locked

| button | effect |
|---|---|
| #0 FilledButton "See plans" | push:page, api:GET /payments/state GET /payments/config?flavour=apk GET /referral/balance, ui-change |

## veh_tracking_empty

| button | effect |
|---|---|
| #0 IconButton "tip:Car Mode / icon:0xeff7" | push:page, ui-change |
| #1 IconButton "tip:Fleet dashboard / icon:0xf18e" | push:page, api:GET /vehicle/fleet, ui-change |
| #2 FAB "icon:0xe053 / Pair tracker" | push:sheet, api:LIST vehicle/records, ui-change |

## veh_tracking_error

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe514 / Retry" | api:GET /vehicle/trackers, state-change |
| #1 IconButton "tip:Car Mode / icon:0xeff7" | push:page, ui-change |
| #2 IconButton "tip:Fleet dashboard / icon:0xf18e" | push:page, api:GET /vehicle/fleet, ui-change |

## subscriptions_empty

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Add subscription" | push:sheet, ui-change |

## subscriptions_error

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe514 / Retry" | api:LIST subscriptions, state-change |

## vault_empty

| button | effect |
|---|---|
| #0 IconButton "tip:Quick lookup / icon:0xe567" | push:dialog, ui-change |
| #1 FAB "icon:0xe047 / Add" | push:dialog, ui-change |

## vault_error

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe514 / Retry" | state-change |
| #1 IconButton "tip:Quick lookup / icon:0xe567" | push:dialog, ui-change |
| #2 FAB "icon:0xe047 / Add" | push:dialog, ui-change |

## c3_chat_list

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #1 ChoiceChip "Unread" | ui-change |
| #2 ChoiceChip "Favourites" | ui-change |
| #3 ChoiceChip "Groups" | ui-change |
| #4 InkWell "R / Rahim / 15:11 key=c3-row-member:1" | push:page, api:GET /circle/t1/gate?kind=member&id=1 GET /circle/keys/peer/1 GET /circle/1/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #5 InkWell "N / Nadia / 14:54 key=c3-row-member:2" | push:page, api:GET /circle/t1/gate?kind=member&id=2 GET /circle/keys/peer/2 GET /circle/2/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #6 InkWell "icon:0xf08a8 / Family / 13:14 key=c3-row-group:7" | push:page, api:GET /circle/groups/7/members GET /circle/groups/7/messages?limit=50 POST /circle/groups/7/seen, platform:dexterous.com/flutter/local_notifications#cancel plugins.flutter.io/path_provider#getApplicationSupportDirectory dev.fluttercommunity.plus/package_info#getAll, ui-change |
| #7 InkWell "K / Karim / Yesterday key=c3-row-member:3" | push:page, api:GET /circle/t1/gate?kind=member&id=3 GET /circle/keys/peer/3 GET /circle/3/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #8 InkWell "M / Mom / Tue key=c3-row-member:4" | push:page, api:GET /circle/t1/gate?kind=member&id=4 GET /circle/keys/peer/4 GET /circle/4/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |

## c3_chat

| button | effect |
|---|---|
| #0 GestureDetector "👍" | push:sheet, ui-change |
| #1 GestureDetector "Is the meeting this afternoon? key=c3-quote-2" | ui-change |
| #2 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #3 IconButton "tip:Attach / icon:0xe050" | push:sheet, ui-change |
| #4 IconButton "icon:0xe571" | ui-change |
| #5 InkWell "Rahim / online key=t1-header" | push:page, api:GET /circle/1/info, ui-change |
| #6 IconButton "tip:Video / icon:0xf48c" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #7 IconButton "tip:Voice call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/1/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #8 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## c3_notif_settings

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xe155 / Message notifications / Get notified of new messages" | api:POST /circle/settings/notifications, ui-change |
| #1 SwitchListTile "icon:0xf0db / Group notifications / Get notified of group messages" | api:POST /circle/settings/notifications, ui-change |
| #2 SwitchListTile "icon:0xef1a / Call notifications / Get notified of incoming calls" | api:POST /circle/settings/notifications, ui-change |
| #3 SwitchListTile "icon:0xf2ff / Message preview / Show message text in notifications" | api:POST /circle/settings/notifications, ui-change |
| #4 SwitchListTile "icon:0xf4a0 / Hide message content / Notifications show only "New mess… key=c3-hide-content" | ui-change |
| #5 ListTile "icon:0xf234 / Message notification sound / Phone default key=sound-message" | platform:com.assisto/calls#pickSound |

## c3_x2_contact_info

| button | effect |
|---|---|
| #0 ListTile "icon:0xe5fd / Starred messages / 0" | push:page, api:GET messenger/starred, net, ui-change |
| #1 SwitchListTile "icon:0xf236 / Mute" | push:sheet, ui-change |
| #2 ListTile "icon:0xf44a / Disappearing messages / Off" | push:sheet, ui-change |
| #3 ListTile "icon:0xf1fb / Custom ringtone / Same as my ringtone key=sound-contact" | platform:com.assisto/calls#pickSound |
| #4 ListTile "icon:0xe0e1 / Block" | api:POST /circle/1/controls, ui-change |
| #5 ListTile "icon:0xf07b / Report" | push:sheet, ui-change |

## c3_e2_chat_unread

| button | effect |
|---|---|
| #0 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #1 IconButton "tip:Attach / icon:0xe050" | push:sheet, ui-change |
| #2 IconButton "icon:0xe571" | ui-change |
| #3 InkWell "A / Abul Kashem key=t1-header" | push:page, api:GET /circle/4/info, ui-change |
| #4 IconButton "tip:Video / icon:0xf48c" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/4/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #5 IconButton "tip:Voice call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/4/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #6 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## t1_headers

| button | effect |
|---|---|
| #0 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #4 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #5 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #6 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #7 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #8 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #9 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #10 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #11 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #12 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #13 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #14 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #15 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #16 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #17 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #18 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #19 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #20 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #21 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #22 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #23 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #24 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #25 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #26 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #27 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #28 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #29 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## t1_date_separators

| button | effect |
|---|---|
| #0 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## t1_date_floating

| button | effect |
|---|---|
| #0 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## t1_version_banners

| button | effect |
|---|---|
| #0 TextButton "Update Assisto" | push:page, net, platform:dev.fluttercommunity.plus/package_info#getAll, ui-change |
| #1 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## t1_update_screen

| button | effect |
|---|---|
| #0 FilledButton "icon:0xeff2 / Update Assisto key=t1-update-now" | push:page, net, platform:dev.fluttercommunity.plus/package_info#getAll, ui-change |
| #1 TextButton "Not now" | pop:page, ui-change |

## mr1_requests_list

| button | effect |
|---|---|
| #0 TextButton "See all" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 InkWell "Sumon Ahmed / 15:10 / Not in your contacts key=mr1-req-61" | push:page, api:GET /circle/t1/gate?kind=member&id=61 GET /circle/keys/peer/61 GET /circle/61/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #2 InkWell "F / Farhana Akter / 12:14 key=mr1-req-64" | push:page, api:GET /circle/t1/gate?kind=member&id=64 GET /circle/keys/peer/64 GET /circle/64/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #3 OutlinedButton "Decline key=m3-decline-65" | snackbar, api:POST /circle/request/65/act, ui-change |
| #4 FilledButton "icon:0xe156 / Accept key=m3-accept-65" | snackbar, api:POST /circle/request/65/act, ui-change |

## mr1_request_chat

| button | effect |
|---|---|
| #0 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #1 TextButton "icon:0xe0e1 / Block key=mr1-block" | push:dialog, ui-change |
| #2 TextButton "icon:0xf07b / Report key=mr1-report" | push:dialog, ui-change |
| #3 TextButton "icon:0xe1bb / Delete key=mr1-delete" | push:dialog, ui-change |
| #4 FilledButton "icon:0xe156 / Accept key=mr1-accept" | snackbar, api:POST /circle/request/61/act POST /circle/61/seen, ui-change |

## mr1_sender_waiting

| button | effect |
|---|---|
| #0 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #1 IconButton "icon:0xe571" | ui-change |
| #2 InkWell "R / Rafiq Islam key=t1-header" | push:page, api:GET /circle/62/info, ui-change |
| #3 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## mr1_sender_limit

| button | effect |
|---|---|
| #0 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #1 InkWell "R / Rafiq Islam key=t1-header" | push:page, api:GET /circle/63/info, ui-change |
| #2 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## mr1_last_seen_12h

| button | effect |
|---|---|
| #0 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #4 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #5 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #6 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #7 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #8 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #9 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #10 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #11 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #12 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #13 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #14 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #15 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #16 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #17 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## mr1_last_seen_24h

| button | effect |
|---|---|
| #0 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #4 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #5 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #6 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #7 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #8 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #9 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #10 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #11 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #12 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #13 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #14 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #15 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #16 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #17 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## a1_header_last_seen

| button | effect |
|---|---|
| #0 IconButton "icon:0xe092" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #4 IconButton "icon:0xe092" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #5 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #6 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #7 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #8 IconButton "icon:0xe092" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #9 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #10 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #11 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #12 IconButton "icon:0xe092" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #13 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #14 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #15 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #16 IconButton "icon:0xe092" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #17 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #18 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #19 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #20 IconButton "icon:0xe092" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #21 IconButton "icon:0xf48c" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #22 IconButton "icon:0xef1a" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #23 IconButton "icon:0xe404" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## a1_chat_list_same_name

| button | effect |
|---|---|
| #0 ChoiceChip "All" | SKIP:already the selected option |
| #1 ChoiceChip "Unread" | ui-change |
| #2 ChoiceChip "Favourites" | ui-change |
| #3 ChoiceChip "Groups" | ui-change |
| #4 InkWell "A / Abul Kashem / …200 key=c3-row-member:71" | push:page, api:GET /circle/t1/gate?kind=member&id=71 GET /circle/keys/peer/71 GET /circle/71/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #5 InkWell "N / Nadia / 10:15 key=c3-row-member:73" | push:page, api:GET /circle/t1/gate?kind=member&id=73 GET /circle/keys/peer/73 GET /circle/73/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #6 InkWell "A / Abul Kashem / …888 key=c3-row-member:72" | push:page, api:GET /circle/keys/peer/72 GET /circle/t1/gate?kind=member&id=72 GET /circle/72/messages?limit=50, platform:dexterous.com/flutter/local_notifications#cancel com.assisto/c3_messaging#bubblesSupported plugins.flutter.io/path_provider#getApplicationSupportDirectory, ui-change |
| #7 InkWell "Invite key=a1-invite" | snackbar, platform:dev.fluttercommunity.plus/share#share, ui-change |

## a1_chat_call_events

| button | effect |
|---|---|
| #0 InkWell "icon:0xe12c / Video call · 12:34 / 14:25 key=a1-call-4" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #1 InkWell "icon:0xe128 / Video call · No answer / 14:05 key=a1-call-3" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #2 InkWell "icon:0xe128 / Voice call · 3:12 / 13:46 key=a1-call-2" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #3 InkWell "icon:0xe12a / Missed voice call / 13:20 key=a1-call-1" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #4 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #5 IconButton "tip:Attach / icon:0xe050" | push:sheet, ui-change |
| #6 IconButton "icon:0xe571" | ui-change |
| #7 InkWell "A / Abul Kashem key=t1-header" | push:page, api:GET /circle/71/info, ui-change |
| #8 IconButton "tip:Video / icon:0xf48c" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #9 IconButton "tip:Voice call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #10 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## md1_attach_sheet

| button | effect |
|---|---|
| #0 InkWell "icon:0xf29d / Gallery key=attach-gallery" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 InkWell "icon:0xf29b / Camera key=attach-camera" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #2 InkWell "icon:0xf1c9 / Voice note key=attach-voice" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #3 InkWell "icon:0xf12d / Document key=attach-document" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## md1_chat

| button | effect |
|---|---|
| #0 InkWell "PDF / ID-card-scan.pdf / 820 KB key=md1-doc-ccccccccccccccccccccccccccccccc5" | push:sheet, ui-change |
| #1 IconButton "tip:Download (51 KB) / icon:0xe203 key=md1-dl-ccccccccccccccccccccccccccccccc6" | net, ui-change |
| #2 InkWell "PDF / Rent receipt October.pdf / 1.2 MB key=md1-dl-ccccccccccccccccccccccccccccccc4" | net, ui-change |
| #3 IconButton "tip:Play / icon:0xe4cd key=md1-voice-play" | snackbar, platform:xyz.luan/audioplayers.global/events#listen xyz.luan/audioplayers.global#init, ui-change, ERROR:async: MissingPluginException(No implementation found for method init on channel xyz.luan/audioplayers.global) ; MissingPluginException(No implementation found for method listen on channel xyz.luan/audioplayers.global/events) |
| #4 InkWell "icon:0xe3b1 / This chat is end-to-end encrypted — the server and its A…" | push:dialog, ui-change |
| #5 IconButton "tip:Attach / icon:0xe050" | push:sheet, ui-change |
| #6 IconButton "icon:0xe571" | ui-change |
| #7 InkWell "Nadia key=t1-header" | push:page, api:GET /circle/71/info, ui-change |
| #8 IconButton "tip:Video / icon:0xf48c" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#keepScreenOn com.assisto/calls#pipSupported com.assisto/calls#stopTone, ui-change |
| #9 IconButton "tip:Voice call / icon:0xef1a" | push:page, api:GET /rt/events?after=0 GET /rtc/turn POST /circle/71/call, net, platform:com.assisto/calls#pipSupported com.assisto/calls#stopTone com.assisto/calls#keepScreenOn, ui-change |
| #10 IconButton "tip:More / icon:0xe404" | push:sheet, ui-change |

## md1_viewer

| button | effect |
|---|---|
| #0 IconButton "tip:Save / icon:0xf333 key=mv-save" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 IconButton "tip:Share / icon:0xf378 key=mv-share" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## md1_photo_preview

| button | effect |
|---|---|
| #0 IconButton "tip:Send / icon:0xe571 key=md1-photo-send" | pop:page, ui-change |
| #1 IconButton "tip:Cancel / icon:0xe16a" | pop:page, ui-change |

## md1_recorder

| button | effect |
|---|---|
| #0 IconButton "tip:Delete recording / icon:0xe1bb key=md1-rec-discard" | ALLOWED-DEAD (reviewed: fixture/device-only) |
| #1 FilledButton "icon:0xe571 / Send key=md1-rec-send" | ALLOWED-DEAD (reviewed: fixture/device-only) |

## md1_storage_settings

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xe6e7 / On Wi-Fi / Photos, voice messages and documents download… key=md1-auto-wifi" | ui-change |
| #1 SwitchListTile "icon:0xf29e / Photos key=md1-auto-mobile-photo" | ui-change |
| #2 SwitchListTile "icon:0xf1c9 / Voice messages key=md1-auto-mobile-voice" | ui-change |
| #3 SwitchListTile "icon:0xefae / Documents key=md1-auto-mobile-document" | ui-change |

## x_msgr_set_account

| button | effect |
|---|---|
| #0 ListTile "icon:0xf2aa / Two-step verification / Protect your account with a PIN" | push:page, api:GET /circle/account/two-step, ui-change |
| #1 ListTile "icon:0xf408 / Change number / Move your circle & chats to a new number" | push:page, api:GET /circle/account/change-number, ui-change |
| #2 ListTile "icon:0xeff2 / Request my data export / Download a copy of your data" | snackbar, net, ui-change |
| #3 ListTile "icon:0xefa8 / Delete account / Permanently delete your account" | push:dialog, ui-change |

## x_msgr_set_chats

| button | effect |
|---|---|
| #0 GestureDetector "Default" | ui-change |
| #1 GestureDetector "icon:0xe156 / Cyan to Blue" | state-change |
| #2 GestureDetector "Blue to Purple" | ui-change |
| #3 GestureDetector "Night Ink" | ui-change |
| #4 GestureDetector "Warm Paper" | ui-change |
| #5 GestureDetector "Calm Forest" (scrolled) | ui-change |
| #6 ListTile "icon:0xeeb6 / Create chat backup / Encrypted backup with a recovery co…" | push:sheet, ui-change |
| #7 ListTile "icon:0xf318 / Restore from backup / Bring back chats with your recover…" | push:sheet, ui-change |
| #8 ListTile "icon:0xefab / Clear chat history / Remove cached messages from this de…" | push:dialog, ui-change |

## x_msgr_set_privacy

| button | effect |
|---|---|
| #0 ListTile "icon:0xf4a1 / Who can see my info / Last seen, online, photo, about, s…" | push:page, api:GET /circle/privacy, ui-change |
| #1 ListTile "icon:0xe1f7 / Read receipts / Turn blue ticks off or on" | push:page, api:GET /circle/privacy, ui-change |
| #2 ListTile "icon:0xef1a / Who can call me / Control who may ring you" | push:page, api:GET /circle/privacy, ui-change |
| #3 ListTile "icon:0xf0b0 / Who can message & number / Choose who can message you an…" | push:page, api:GET /circle/settings/message-privacy, ui-change |
| #4 ListTile "icon:0xf1c6 / Who can message me / Review requests from outside your c…" | push:page, api:GET /circle/message-requests, ui-change |
| #5 ListTile "icon:0xe0e1 / Blocked list / People you've blocked" | push:page, api:GET /circle/blocked, ui-change |

## x_msgr_set_calls

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xef1b / Incoming calls / Turn receiving calls on or off" | api:POST /circle/settings/calls, ui-change |
| #1 SwitchListTile "icon:0xf289 / Silence unknown callers / Calls from outside your circle…" | api:POST /circle/settings/calls, ui-change |
| #2 ListTile "icon:0xe3b1 / Who can call me / Set call permissions in privacy" | push:page, api:GET /circle/privacy, ui-change |
| #3 ListTile "icon:0xf1fb / Ringtone / Phone default key=sound-ringtone" | platform:com.assisto/calls#pickSound |
| #4 SwitchListTile "tip:Play preview / icon:0xe4ce / Assisto ringtone / An original Assist… key=sound-signature" | snackbar, platform:com.assisto/calls#installRingtone, ui-change |

## x_msgr_set_storage

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xe6e7 / On Wi-Fi / Photos, voice messages and documents download… key=md1-auto-wifi" | ui-change |
| #1 SwitchListTile "icon:0xf29e / Photos key=md1-auto-mobile-photo" | ui-change |
| #2 SwitchListTile "icon:0xf1c9 / Voice messages key=md1-auto-mobile-voice" | ui-change |
| #3 SwitchListTile "icon:0xefae / Documents key=md1-auto-mobile-document" | ui-change |

## x_msgr_set_twostep

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xf2aa / Enable two-step verification / Turned off" | push:dialog, ui-change |

## x_linked_devices

| button | effect |
|---|---|
| #0 ListTile "icon:0xe4f6 / Link a device / Scan this code in the web or desktop cli…" | snackbar, api:POST messenger/link/start, net, ui-change |
| #1 OutlinedButton "icon:0xe514 / Retry" | api:GET messenger/linked-devices, net, state-change |

## x_connection_requests

| button | effect |
|---|---|
| #0 InkWell "Requests / Tab 1 of 2" | SKIP:already the selected option |
| #1 InkWell "Sent / Tab 2 of 2" | snackbar, ui-change |

## x_channel_list

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe047 / Create channel" | push:sheet, ui-change |
| #1 IconButton "tip:Discover / icon:0xf037" | push:page, api:GET /channels/discover, net, ui-change |
| #2 FAB "icon:0xe047 / Create channel" | push:sheet, ui-change |

## x_msgr_discover

| button | effect |
|---|---|
| #0 FilterChip "All" | SKIP:already the selected option |
| #1 FilterChip "News" | api:GET /channels/discover?category=news, net, ui-change |
| #2 FilterChip "Religion" | api:GET /channels/discover?category=religion, net, ui-change |
| #3 FilterChip "Entertainment" | api:GET /channels/discover?category=entertainment, net, ui-change |
| #4 FilterChip "Education" (scrolled) | api:GET /channels/discover?category=education, net, ui-change |
| #5 FilterChip "Sports" | SKIP:could not scroll it into view |
| #6 FilterChip "Business" | SKIP:could not scroll it into view |

## x_security

| button | effect |
|---|---|
| #0 FilledButton "Retry" | api:GET /security/state, net, state-change |

## x_delete_account

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xeff2 / Download my data first" | snackbar, net, ui-change |
| #1 OutlinedButton "icon:0xf04f / Send feedback key=del-acct-feedback" | push:sheet, platform:dev.fluttercommunity.plus/package_info#getAll, ui-change |
| #2 OutlinedButton "icon:0xe30b / Contact support key=del-acct-support" | push:page, ui-change |
| #3 FilledButton "Continue to delete" | ui-change |
| #4 TextButton "Keep my account" | pop:page, ui-change |

## x_accessibility_mode

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xf04d8 / High contrast / Makes text and borders sharper — easier…" | ui-change |
| #1 SwitchListTile "icon:0xe086 / Reduce motion / Softens or stops page transitions and mo…" | ui-change |
| #2 SwitchListTile "icon:0xf48f / Simplified layout / Reduces decoration where supported. …" | ui-change |
| #3 SwitchListTile "icon:0xf2f3 / Screen-reader hints / Adds extra descriptions to icon bu…" | ui-change |
| #4 SwitchListTile "icon:0xe6a0 / Haptic feedback / Gives a gentle vibration when you tap." | ui-change |

## x_lost_stolen

| button | effect |
|---|---|
| #0 FilledButton "Enable" | snackbar, platform:com.assisto/device_admin#requestAdmin com.assisto/device_admin#isAdminActive, ui-change |
| #1 ListTile "icon:0xf065d / Always-on protection / Keep watch for snatch, SIM chang…" | push:page, api:GET /security/engine/state, platform:com.assisto/antitheft#capabilities com.assisto/antitheft#isRunning com.assisto/antitheft#flush, ui-change |
| #2 ListTile "icon:0xf45f / My lost phone / What Assisto can see about this phone wh…" | push:page, api:GET /security/lost-phone, net, ui-change |
| #3 ListTile "icon:0xf0c0 / Recovery help / GD draft, SP letter, evidence and neares…" | push:page, ui-change |
| #4 TextButton "Set" | push:dialog, ui-change |
| #5 SwitchListTile "Lock the screen / This needs device-admin to work." | push:dialog, platform:plugins.flutter.io/local_auth#isDeviceSupported, ui-change |
| #6 SwitchListTile "Loud alarm / Plays at max volume and vibrates." | ui-change |
| #7 OutlinedButton "icon:0xe6c5 / Test alarm" | snackbar, platform:com.assisto/device_admin#startAlarm, ui-change |
| #8 SwitchListTile "Report last location / Uses the existing SOS location service." | ui-change |
| #9 OutlinedButton "icon:0xe418 / Report location now" | snackbar, platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, ui-change |
| #10 SwitchListTile "Lock-screen message / Shows a "lost phone" note with the owner's numbe…" | ui-change |
| #11 TextButton "Edit" | push:dialog, ui-change |

## x_my_lost_phone

| button | effect |
|---|---|
| #0 FilledButton "Retry" | api:GET /security/lost-phone, net, state-change |

## x_phone_safety

| button | effect |
|---|---|
| #0 ChoiceChip "Stock Android" | SKIP:already the selected option |
| #1 ChoiceChip "Realme / ColorOS" | ui-change |
| #2 ChoiceChip "Samsung / One UI" | ui-change |
| #3 ChoiceChip "Xiaomi / HyperOS" | ui-change |
| #4 ChoiceChip "Vivo / Funtouch" | ui-change |
| #5 ListTile "icon:0xe504 / Turn on Identity Check / On supported phones, this force…" | ui-change |
| #6 ListTile "icon:0xe504 / Lock the notification shade on the lock screen / Stops a…" | ui-change |
| #7 ListTile "icon:0xe504 / Require PIN to power off / A thief can't switch the phon…" | ui-change |
| #8 ListTile "icon:0xe504 / Lock network & security / Stops a thief from turning on …" | ui-change |
| #9 ListTile "icon:0xe504 / Turn on Google Theft Protection / Auto-locks the phone i…" | ui-change |
| #10 ListTile "icon:0xe504 / Enable Find My Device / Find Hub / Lets you locate, ring…" | ui-change |
| #11 ListTile "icon:0xe504 / Lock your SIM with a PIN / Stops a thief from moving you…" | ui-change |
| #12 ListTile "icon:0xe504 / Use a strong screen lock / A 6+ digit PIN or password is…" | ui-change |
| #13 ListTile "icon:0xe504 / Add a Google account (Factory Reset Protection) / With a…" | ui-change |
| #14 ListTile "icon:0xe504 / Brand account lock / A reactivation lock tied to your br…" | ui-change |
| #15 ListTile "icon:0xe504 / Google 2-Step Verification / A thief needs your Google a…" | ui-change |
| #16 FilledButton "icon:0xf089f / Check your family's phones too" | push:page, api:POST /circle/keys GET /circle/members GET /circle/chats, net, ui-change |
| #17 OutlinedButton "icon:0xf138 / Share this checklist" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |
| #18 IconButton "tip:Share checklist / icon:0xf138" | platform:dev.fluttercommunity.plus/share#share, ERROR:async: MissingPluginException(No implementation found for method share on channel dev.fluttercommunity.plus/share) |

## x_recovery

| button | effect |
|---|---|
| #0 FilledButton "icon:0xe45c / Open GD draft" | snackbar, api:GET /recovery/gd-draft, net, ui-change |
| #1 OutlinedButton "icon:0xe4f0 / Open Online GD" | snackbar, platform:plugins.flutter.io/url_launcher#launch, ui-change |
| #2 FilledButton "icon:0xe45c / Open SP letter" | snackbar, api:GET /recovery/sp-letter, net, ui-change |
| #3 FilledButton "icon:0xe201 / Download & share PDF" | snackbar, platform:plugins.flutter.io/path_provider#getTemporaryDirectory, ui-change |
| #4 FilledButton "icon:0xe418 / Find stations near me" | snackbar, platform:flutter.baseflow.com/geolocator#isLocationServiceEnabled, ui-change |

## x_sell_my_phone

| button | effect |
|---|---|
| #0 ListTile "icon:0xef64 / Take an encrypted backup / So you keep your photos, cont…" | ui-change |
| #1 ListTile "icon:0xee35 / Remove your Google account / If you factory-reset WITHOU…" | ui-change |
| #2 ListTile "icon:0xeeb8 / Remove your brand account / Samsung / Mi / brand account…" | ui-change |
| #3 ListTile "icon:0xf196 / Disarm Assisto protection / Turn off Assisto’s ownership…" | ui-change |
| #4 ListTile "icon:0xee53 / Remove device admin / While Assisto (or any app) is a de…" | ui-change |
| #5 ListTile "icon:0xf39c / Remove SIM and SD card / Your number and files should no…" | ui-change |
| #6 ListTile "icon:0xf314 / Factory reset — do this LAST / Only after the accounts a…" | ui-change |
| #7 FilledButton "icon:0xf2ef / Create receipt" | snackbar, ui-change |
| #8 FilledButton "icon:0xeff0 / Accept phone" | snackbar, ui-change |
| #9 TextButton "icon:0xf30d / Report my phone stolen" | push:page, ui-change |

## x_voice_sos

| button | effect |
|---|---|
| #0 SwitchListTile "icon:0xe307 / Turn on hands-free SOS / Off (default). Turn on when you…" | push:dialog, ui-change |
| #1 TextButton "Change" | push:dialog, ui-change |

## x_fall_detect

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe0ee / Simulate a fall" | push:page, ui-change |

## x_report_stolen

| button | effect |
|---|---|
| #0 OutlinedButton "icon:0xe45c / Open Online GD" | platform:plugins.flutter.io/url_launcher#canLaunch, ERROR:async: MissingPluginException(No implementation found for method canLaunch on channel plugins.flutter.io/url_launcher) |
| #1 FilledButton "icon:0xf30f / Report stolen" | snackbar, ui-change |
| #2 OutlinedButton "icon:0xe15a / Mark recovered" | snackbar, ui-change |

