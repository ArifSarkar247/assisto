"""srvperf probe — prints query count + time per hot endpoint for a seeded
heavy user. Skipped unless SRVPERF_PROBE=1 (run by loadtest.yml's probe job
on both the before and after code)."""
import os
import unittest
import time
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient
from core import perf_seed as S
from core.models import CircleMember, CircleGroupMember

@unittest.skipUnless(os.getenv("SRVPERF_PROBE") == "1", "probe only")
class Probe(TestCase):
    def test_probe(self):
        us = S.make_users(40)
        users = [u for u, _ in us]
        print(S.seed_world(users, peers=20, msgs=30, groups=3, group_size=8, group_msgs=40))
        me = users[0]
        c = APIClient(); c.force_authenticate(me)
        edge = CircleMember.objects.filter(user=me).first()
        g = CircleGroupMember.objects.filter(member=me).first()
        eps = [("post","/api/v1/circle/receipts/sync",{}),
               ("post","/api/v1/circle/receipts/sync",{}),
               ("post","/api/v1/devices/register",{"push_token":"tok-x","platform":"android","app_version":"1.0.255"}),
               ("get","/api/v1/circle/calls/incoming",None),
               ("get","/api/v1/circle/chats",None),
               ("get","/api/v1/home/badges",None),
               ("get","/api/v1/discover/cards",None),
               ("get","/api/v1/rt/events?after=0&online=1",None),
               ("post","/api/v1/rt/send",{"topic":"typing.set","payload":{"chat_kind":"member","chat_id":edge.id,"state":"typing"}}),
               ("get","/api/v1/alerts",None),
               ("get","/api/v1/ads/slot?screen=home",None),
               ("get","/api/v1/ads/config",None),
               ("get","/api/v1/circle/calls",None),
               ("get","/api/v1/features",None),
               ("get","/api/v1/security/lost-phone",None),
               ("get","/api/v1/circle/calls/missed_pending",None),
               ("get","/api/v1/circle/e2/resend",None),
               ("get","/api/v1/health",None),
               ("get","/api/v1/circle/%d/messages"%edge.id,None),
               ("get","/api/v1/circle/groups/%d/messages"%g.group_id,None),
               ("get","/api/v1/transactions/",None),
               ("get","/api/v1/goals/",None),
               ("post","/api/v1/discover/track",{"key":"x","event":"view"}),
               ("post","/api/v1/ads/event",{"event":"impression","slot":"home"}),
               ]
        for m,u,d in eps:
            with CaptureQueriesContext(connection) as q:
                t=time.perf_counter()
                r = getattr(c,m)(u,d,format="json") if d is not None else getattr(c,m)(u)
                dt=time.perf_counter()-t
            print("PROBE %-4s %-50s %s q=%3d %.0fms"%(m,u[:50],r.status_code,len(q),dt*1000))
            if len(q)>25:
                import collections
                cc=collections.Counter(x['sql'][:90] for x in q.captured_queries)
                for s,n in cc.most_common(5): print("     %3d %s"%(n,s))
