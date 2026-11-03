bizauto: Meta webhook payloads in the exact shape Graph API v21 sends them
(Page "feed" field, Instagram "comments" field, Messenger "messaging"), taken
from Meta's webhook reference samples and our own field parsing. Ids are fake;
"__PAGE__", "__IG__", "__NOW__" (unix seconds) are filled in by
core/tests_bizauto.py so the same files run for any test channel and any day.
Used to prove the comment-reply path works the day Meta App Review passes:
switch off -> saved for the inbox only; switch on -> one private reply.
