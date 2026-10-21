"""c1-contacts — keep User.phone canonical and UserPhoneHash in sync.

pre_save : any parseable User.phone is stored in the ONE canonical form
           (core.phone.canonical_phone); unparseable legacy values are left
           exactly as they are (never destroyed).
post_save: when the phone changed (or the user is new), create / update /
           remove the user's UserPhoneHash so contacts match + manual search
           can find them. Never raises into the save path.
"""
from django.db.models.signals import post_save, pre_save


def _user_pre_save(sender, instance, update_fields=None, **kwargs):
    from .phone import canonical_phone
    if kwargs.get("raw"):
        return
    if update_fields is not None and "phone" not in update_fields:
        return
    raw = instance.phone
    if raw is not None and str(raw).strip() == "":
        instance.phone = None
    elif raw:
        c = canonical_phone(raw)
        if c:
            instance.phone = c
    old = None
    if instance.pk:
        old = (sender.objects.filter(pk=instance.pk)
               .values_list("phone", flat=True).first())
    instance._c1_phone_changed = (instance.pk is None) or (old != instance.phone)


def _user_post_save(sender, instance, created, raw=False, **kwargs):
    if raw:
        return
    if created or getattr(instance, "_c1_phone_changed", False):
        from .phone import sync_phone_hash
        sync_phone_hash(instance)
        instance._c1_phone_changed = False


def connect():
    from django.contrib.auth import get_user_model
    User = get_user_model()
    pre_save.connect(_user_pre_save, sender=User,
                     dispatch_uid="c1_phone_canonical_pre")
    post_save.connect(_user_post_save, sender=User,
                      dispatch_uid="c1_phone_hash_post")
