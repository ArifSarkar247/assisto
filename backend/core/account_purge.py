"""dl1: the ONE account purge — shared by the hourly purge_deletions command
(grace period elapsed) and the in-app "Delete now and start fresh" choice a
user gets when they sign in during the 7-day grace period.

purge_user(user) removes the user's uploaded FILES off disk first (a DB cascade
drops the rows but NOT the bytes), then hard-deletes the User, which cascades
every CASCADE child (memories, audit, reminders, circle edges, the
AccountDeletionRequest row itself, ...). Only touches Assisto's own DB/media.
"""

# FileField/ImageField attributes to remove from disk, grouped by the related
# accessor on User. Kept explicit so a new upload field is a conscious add.
_FILE_FIELDS = [
    ("documents", ["file"]),        # Document.file  -> vault/
    ("support_tickets", ["screenshot"]),  # SupportTicket.screenshot -> support/
]


def _delete_user_files(user):
    """Best-effort removal of every uploaded file owned by the user, before the
    DB cascade drops the rows. Never raises on a single bad file."""
    removed = 0

    def _wipe(fieldfile):
        nonlocal removed
        try:
            if fieldfile:
                fieldfile.delete(save=False)
                removed += 1
        except Exception:
            pass

    # Avatar on the user row itself.
    _wipe(getattr(user, "photo", None))

    # Captured theft evidence photos (ProtectedPhone -> CapturedEvent.photo,
    # upload_to="theft/"). These hang off the phone, not the user directly.
    try:
        for phone in user.protected_phones.all():
            for cap in phone.captured_events.all():
                _wipe(getattr(cap, "photo", None))
    except Exception:
        pass

    # Generic reverse-relation file fields (vault, support, …).
    for accessor, attrs in _FILE_FIELDS:
        try:
            qs = getattr(user, accessor).all()
        except Exception:
            continue
        for obj in qs:
            for attr in attrs:
                _wipe(getattr(obj, attr, None))

    # Sweep any remaining FileField/ImageField on the user's direct children we
    # didn't name explicitly (catalog/khata bill photos, etc.).
    try:
        from django.db.models import FileField
        for rel in user._meta.related_objects:
            accessor = rel.get_accessor_name()
            if accessor in dict(_FILE_FIELDS) or accessor == "protected_phones":
                continue
            model = rel.related_model
            file_attrs = [f.name for f in model._meta.get_fields()
                          if isinstance(f, FileField)]
            if not file_attrs:
                continue
            try:
                children = getattr(user, accessor).all()
            except Exception:
                continue
            for obj in children:
                for attr in file_attrs:
                    _wipe(getattr(obj, attr, None))
    except Exception:
        pass

    return removed


def purge_user(user):
    """Hard-delete `user` and everything they own. Call inside a transaction.
    Returns the number of files removed from disk."""
    files = _delete_user_files(user)
    user.delete()  # cascades all data + the deletion_request row
    return files
