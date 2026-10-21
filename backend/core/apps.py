from django.apps import AppConfig


class CoreConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'core'

    def ready(self):
        # c1-contacts: canonical User.phone + UserPhoneHash sync.
        from . import signals_c1_phone
        signals_c1_phone.connect()
