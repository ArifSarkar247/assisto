"""moneybar: GET /prices/official — TCB's official Dhaka retail price list
(core.tcb_prices). Read-only, the same for every signed-in user. Never
invents a price: {connected: false} until the daily fetch has stored a list."""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import tcb_prices


class OfficialPricesView(APIView):
    def get(self, request):
        return Response(tcb_prices.public_view())
