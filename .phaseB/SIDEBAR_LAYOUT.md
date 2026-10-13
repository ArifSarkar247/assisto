# SIDEBAR — EXACT REGROUP (owner FINAL v2; SUPERSEDES earlier partial regroup). Each module in ONE place only. Rewrite app/lib/widgets/sidebar_sections.dart + app_drawer.dart to THIS. Labels bn / en.

## TOP (always visible, above sections):
- "নতুন চ্যাট / New chat" → starts a new Connected Circle chat (CircleScreen new-chat)
- "মেসেজ / Messages" → Connected Circle (CircleScreen)
- search box (filters all modules by bn/en name + synonyms)

## SECTIONS (collapsible ExpansionTile; remember open/closed state):
1. **রিমাইন্ডার ও মেমোরি / Reminders & Memory**: Reminders(RemindersScreen), Birthdays & memorable days(BirthdaysScreen), Meetings & appointments(MeetingsScreen), Notes & tasks(NotesTodosScreen), AI knows(MemoryScreen)
2. **আমার হিসাব / My Account**: My Account ledger(MoneyScreen), Subscriptions(SubscriptionsScreen), Finance tools(FinanceScreen)
3. **পরিবার / Family**: Family care & medicine schedule(FamilyScreen), Contacts/কন্টাক্টস(CrmContactsScreen), Nominee access(NomineeScreen)
4. **নিরাপত্তা / Safety**: Safe Journey(JourneyStartScreen), Emergency card & SOS(EmergencyScreen), Scam protection(ScamScreen)
5. **স্বাস্থ্য / Health**: Medicine database(MedicineDbScreen), Health tips(HealthTipsScreen) [+ health timeline if present]
6. **দৈনন্দিন জীবন / Daily Life**: Documents/ডকুমেন্টস(VaultScreen), Government service guide(GuideScreen), Nearby(NearbyScreen), Unseen World(UnseenWorldScreen), Dictionary(DictionaryScreen), Prayer & Ramadan(RamadanScreen), Watch feed/alerts(WatchFeedScreen), Exam results(ExamResultScreen)
7. **কাজ / Work**: Agent Studio(AgentStudioScreen), Job hunter(JobsScreen), AI Inbox(InboxScreen)
8. **ব্যবসা / Business**: Business(BusinessScreen), CRM(CrmHomeScreen)

## BOTTOM (pinned):
- Settings(SettingsScreen) — and INSIDE Settings: "In progress"(InProgressScreen) + "Connected apps"(SourcesScreen)
- Plans & points(PlansScreen incl referral points)
- Profile (name + phone) — profile view (SettingsScreen profile section or a dedicated ProfileScreen)

## UNLISTED MODULES — decisions (record): Photo enhance(PhotoEnhanceScreen)→Daily Life (a tool). Battery guidance(BatteryGuidanceScreen)→inside Settings (reliability). Legal(LegalScreen)→inside Settings. Password reset→login flow (not sidebar). Safety settings/Safe-Journey settings→inside Safety or Settings.

## RULES: remember open/closed per section; search box finds any module by bn OR en name + synonyms (reuse chatnav/screen_synonyms vocabulary); every module ALSO opens from chat ("আমার রিমাইন্ডার দেখাও","open documents") via ChatNav+screen_synonyms — ensure every module above has a chatnav route + synonyms. ARB section header keys: reuse/rename sidebarMoney=[আমার হিসাব,My Account], sidebarLife→(new) sidebarDaily=[দৈনন্দিন জীবন,Daily Life] (or keep sidebarLife value), + NEW keys sidebarRemindersMemory, sidebarSafety(exists?), sidebarWork, sidebarBusiness, sidebarHealth, sidebarFamily — author bn/en. "CRM"/"CRM" (crmTitle) with lang-gate exception. NO "Money"/"টাকা" labels anywhere.
