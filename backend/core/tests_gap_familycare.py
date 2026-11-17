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


class SharedLedgerTest(Base):
    """gap-familycare slice 3: one family ledger every member sees; exact
    integer poisha; the personal ledger stays separate; strangers locked out."""

    def setUp(self):
        super().setUp()
        self.fid = self.fam()["families"][0]["id"]       # Rina = admin
        self.join(self.ab, self.cb, self.fid)            # Ammu
        self.join(self.ac, self.cc, self.fid)            # Rafi
        self.ub, self.uc = "u%d" % self.b.id, "u%d" % self.c.id

    def add(self, client, payer, total, members, **kw):
        return client.post(f"{V}/family/accounting/expenses", {
            "family": self.fid, "payer": payer, "total_poisha": total,
            "category": "groceries", "mode": "equal", "members": members, **kw},
            format="json")

    def summary(self, client):
        r = client.get(f"{V}/family/accounting/summary?family={self.fid}")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def test_everyone_sees_one_ledger_with_exact_poisha(self):
        r = self.add(self.ca, "self", 1000, ["self", self.ub, self.uc])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual([s["share_poisha"] for s in r.json()["shares"]], [334, 333, 333])
        # Ammu sees it on HER phone; for her, Rina is "u<id>" and she is "self"
        s = self.summary(self.cb)
        self.assertEqual(s["total_poisha"], 1000)
        nets = {m["member"]: m["net_poisha"] for m in s["members"]}
        self.assertEqual(nets["self"], -333)
        self.assertEqual(nets["u%d" % self.a.id], 666)
        self.assertEqual(sum(nets.values()), 0)
        self.assertEqual(s["family"]["id"], self.fid)
        # Ammu adds her own spend: Rafi owes both, sums stay exact
        self.assertEqual(self.add(self.cb, "self", 701, ["self", self.uc]).status_code, 201)
        s = self.summary(self.cc)
        nets = {m["member"]: m["net_poisha"] for m in s["members"]}
        self.assertEqual(sum(nets.values()), 0)
        owed = sum(t["amount_poisha"] for t in s["settlements"] if t["from"] == "self")
        self.assertEqual(owed, 333 + 350)  # 701 = 351 (Ammu) + 350 (Rafi)

    def test_personal_ledger_stays_separate(self):
        self.add(self.ca, "self", 5000, ["self", self.ub])
        mine = self.ca.get(f"{V}/family/accounting/summary").json()
        self.assertEqual(mine["total_poisha"], 0)
        self.assertIn("pool", mine)
        self.assertNotIn("goals", mine)

    def test_strangers_and_bad_members(self):
        self.assertEqual(self.cx.get(f"{V}/family/accounting/summary?family={self.fid}")
                         .status_code, 404)
        r = self.cx.post(f"{V}/family/accounting/expenses",
                         {"family": self.fid, "payer": "self", "total_poisha": 100,
                          "members": ["self"]}, format="json")
        self.assertEqual(r.status_code, 404)
        stranger = "u%d" % self.x.id
        self.assertEqual(self.add(self.ca, "self", 100, ["self", stranger]).status_code, 400)
        self.assertEqual(self.add(self.ca, "self", 100, ["self", "12"]).status_code, 400)

    def test_delete_only_who_added_or_admin_and_settle(self):
        eid = self.add(self.cb, "self", 900, ["self", self.uc]).json()["id"]
        r = self.cc.post(f"{V}/family/accounting/expenses/delete",
                         {"family": self.fid, "id": eid}, format="json")
        self.assertEqual(r.status_code, 403)
        # Rafi pays Ammu back 450 -> nothing left
        r = self.cc.post(f"{V}/family/accounting/settle",
                         {"family": self.fid, "from": "self", "to": self.ub,
                          "amount_poisha": 451}, format="json")
        self.assertEqual(r.status_code, 400)          # more than he owes
        r = self.cc.post(f"{V}/family/accounting/settle",
                         {"family": self.fid, "from": "self", "to": self.ub,
                          "amount_poisha": 450}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["remaining"], [])
        # the admin may delete anyone's row
        r = self.ca.post(f"{V}/family/accounting/expenses/delete",
                         {"family": self.fid, "id": eid}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_named_goals(self):
        r = self.cb.post(f"{V}/family/accounting/goals",
                         {"family": self.fid, "name": "Eid fund", "target_poisha": 1000000},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        gid = r.json()["id"]
        self.ca.post(f"{V}/family/accounting/goals",
                     {"family": self.fid, "name": "School fees", "target_poisha": 300000},
                     format="json")
        for client, amt in ((self.ca, 250000), (self.cc, 50001)):
            r = client.post(f"{V}/family/accounting/goals/{gid}/contribute",
                            {"member": "self", "amount_poisha": amt}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
        g = r.json()
        self.assertEqual((g["collected_poisha"], g["remaining_poisha"], g["pct"]),
                         (300001, 699999, 30))
        self.assertEqual(sum(b["amount_poisha"] for b in g["breakdown"]), 300001)
        names = [x["name"] for x in self.summary(self.cc)["goals"]]
        self.assertEqual(sorted(names), ["Eid fund", "School fees"])
        # only who made it / admin can close; closed takes no more money
        self.assertEqual(self.cc.post(f"{V}/family/accounting/goals/{gid}/close").status_code, 403)
        self.assertEqual(self.ca.post(f"{V}/family/accounting/goals/{gid}/close").status_code, 200)
        r = self.cb.post(f"{V}/family/accounting/goals/{gid}/contribute",
                         {"member": "self", "amount_poisha": 100}, format="json")
        self.assertEqual(r.status_code, 400)
        # validation + strangers
        for bad in ({"name": "", "target_poisha": 100}, {"name": "X", "target_poisha": 0},
                    {"name": "X", "target_poisha": "abc"}):
            r = self.cb.post(f"{V}/family/accounting/goals", {"family": self.fid, **bad},
                             format="json")
            self.assertEqual(r.status_code, 400, bad)
        self.assertEqual(self.cx.post(f"{V}/family/accounting/goals/{gid}/reopen").status_code, 404)
        self.assertEqual(self.ca.get(f"{V}/family/accounting/goals").status_code, 400)
