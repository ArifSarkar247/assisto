"""Pure self-tests for core.logic.telegram_bot (Step 6 sandbox)."""
from . import telegram_bot as TB


def test_parse_command_strips_botname_and_arg():
    assert TB.parse_command("/remind@AssistoBot buy milk") == ("/remind", "buy milk")
    assert TB.parse_command("hello") == (None, "hello")
    assert TB.parse_command("/help") == ("/help", "")


def test_help_is_default_and_bilingual():
    en = TB.route("/help", lang="en")
    bn = TB.route("/start", lang="bn")
    assert "commands" in en["reply"].lower() and en["action"] is None
    assert bn["reply"] != en["reply"]  # localized


def test_link_requires_code():
    assert TB.route("/link", lang="en")["action"] is None
    d = TB.route("/link ABC123", lang="en")
    assert d["action"] == "link" and d["arg"] == "ABC123"


def test_balance_requires_linked_account():
    assert TB.route("/balance", lang="en", is_linked=False)["action"] is None
    assert TB.route("/balance", lang="en", is_linked=True)["action"] == "balance"


def test_remind_needs_text_and_linked():
    assert TB.route("/remind", lang="en", is_linked=True)["action"] is None
    assert TB.route("/remind call mom", lang="en", is_linked=True)["action"] == "remind"


def test_unknown_command_is_safe():
    d = TB.route("/wat", lang="en", is_linked=True)
    assert d["action"] is None and "help" in d["reply"].lower()


def test_sandbox_status_inert_without_token():
    assert TB.sandbox_status(False)["live"] is False
    assert TB.sandbox_status(True)["live"] is True


def run_all():
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); n += 1
    print(f"telegram_bot: {n} tests passed")
    return n


if __name__ == "__main__":
    run_all()
