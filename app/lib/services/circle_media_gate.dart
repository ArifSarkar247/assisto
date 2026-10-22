/// NO SHOWPIECES (round 2 item 4): My Circle's encrypted media blob storage is
/// not built yet (backend core/logic/circle.MEDIA_UNLOCKED is all False), so a
/// photo / video / voice send could only carry the caption. While this is
/// false, media entry points in My Circle that would be dead ends are hidden
/// (status Photo/Video tabs, camera "send to chats / post as status") and the
/// camera offers the phone's real share menu instead. Flip together with the
/// blob-storage build.
bool get kCircleMediaStorageOn => false;
