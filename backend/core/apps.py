from django.apps import AppConfig


class CoreConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'core'

    def ready(self):
        # c1-contacts: canonical User.phone + UserPhoneHash sync.
        from . import signals_c1_phone
        signals_c1_phone.connect()
        # b2-badges: badges.update realtime events (new message / notif).
        from . import b2_badges
        b2_badges.connect()
        # md1: deleting a CircleMediaBlob row (purge, delete-for-everyone,
        # account deletion cascade) removes its ciphertext file.
        from . import circle_blobs
        circle_blobs.connect()
