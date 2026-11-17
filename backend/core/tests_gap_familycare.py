"""gap-familycare (17 Nov): the server side of the Family Care gaps fixed in
the app (owner_actions/gaps/familycare_BN.md).

  * task undo / delete — the new app buttons: a mistaken "done" comes back;
    only the one who added a task (or a family admin) can delete it
  * Location from a member card picks the person: /journey/requests gives
    each My Circle row its peer_user_id and each request the other side's
    user id (so the app never re-asks an already-live request)
"""
from core.tests_fcscreen import V, Base
from core.tests_guardian_journey import GBase, U


class TaskUndoDeleteTest(Base):
    def setUp(self):
        super().setUp()
        self.fid = self.fam()["families"][0]["id"]       # Rina is the admin
        self.join(self.ab, self.cb, self.fid)
        self.join(self.ac, self.cc, self.fid)

    def _task(self, client, title="Gas bill"):
        r = client.post(f"{V}/family/v3/families/{self.fid}/tasks",
                        {"title": title, "kind": "bill"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["task"]["id"]

    def _tasks(self, client=None):
        return (client or self.ca).get(
            f"{V}/family/v3/families/{self.fid}/tasks").json()["tasks"]

    def test_undo_a_mistaken_done(self):
        tid = self._task(self.cb)
        self.assertEqual(self.cc.post(f"{V}/family/v3/tasks/{tid}/done").status_code, 200)
        self.assertTrue(self._tasks()[0]["done"])
        self.assertEqual(self.cc.post(f"{V}/family/v3/tasks/{tid}/undo").status_code, 200)
        t = self._tasks()[0]
        self.assertFalse(t["done"])
        self.assertEqual(t["done_by_name"], "")

    def test_delete_only_creator_or_admin(self):
        tid = self._task(self.cb)                          # Ammu added it
        self.assertEqual(self.cc.post(f"{V}/family/v3/tasks/{tid}/delete").status_code, 403)
        self.assertEqual(len(self._tasks()), 1)
        self.assertEqual(self.cb.post(f"{V}/family/v3/tasks/{tid}/delete").status_code, 200)
        self.assertEqual(self._tasks(), [])
        tid2 = self._task(self.cc, "Doctor visit")         # Rafi added it
        self.assertEqual(self.ca.post(f"{V}/family/v3/tasks/{tid2}/delete").status_code, 200)
        self.assertEqual(self._tasks(), [])
        # a stranger can never touch a family task
        tid3 = self._task(self.cb, "Rice")
        self.assertEqual(self.cx.post(f"{V}/family/v3/tasks/{tid3}/delete").status_code, 404)

    def test_created_by_is_sent_so_the_app_knows_who_may_delete(self):
        self._task(self.cb)
        self.assertEqual(self._tasks()[0]["created_by"], self.b.id)


class LocationPreselectTest(GBase):
    def test_people_carry_peer_user_id_and_requests_other_user_id(self):
        d = self.cb.get(U).json()
        row = [p for p in d["people"] if p["member_id"] == self.ba.id][0]
        self.assertEqual(row["peer_user_id"], self.a.id)
        r = self.ask()
        self.assertEqual(r.status_code, 201, r.content)
        out = self.cb.get(U).json()["outgoing"]
        self.assertEqual(out[0]["other_user_id"], self.a.id)
        inc = self.ca.get(U).json()["incoming"]
        self.assertEqual(inc[0]["other_user_id"], self.b.id)
