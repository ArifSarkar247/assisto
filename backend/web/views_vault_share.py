"""p3docs — lifeassisto.com/d/<token>#<key>: ONE vault document someone shared
with a time-limited link. No login, no app.

End-to-end: the phone encrypted the copy with a fresh key that lives ONLY in
the #fragment — browsers never send a fragment to a server — and this page
decrypts it in the browser (ChaCha20-Poly1305, the same chunked format as
app/lib/messaging/media/media_crypto.dart). The server stores the token's
SHA-256 and ciphertext, nothing else (core.vault_e2e).

The page itself does NOT count an open (WhatsApp/Messenger link previews fetch
it); only the "Show the document" button's /blob fetch does. States: open /
expired / used / revoked / bad (404). noindex, no-store, no ads, no referrer,
rate-limited per IP.
"""
import json

from django.core.cache import cache
from django.http import HttpResponse
from django.utils import timezone
from django.utils.html import escape
from django.views.decorators.http import require_GET

from core import vault_e2e as VE

from .views import _ip_hash

RATE_PER_MIN = 30

TXT = {
    "bn": {
        "title": "শেয়ার করা কাগজ", "brand": "Assisto ডকুমেন্টস",
        "show": "কাগজটি দেখুন", "until": "লিংক খোলা থাকবে",
        "left": "আর খোলা যাবে", "times": "বার",
        "e2e": "এই কাগজ এন্ড-টু-এন্ড এনক্রিপ্টেড: চাবি শুধু এই লিংকের মধ্যে, Assisto-র সার্ভার এটা পড়তে পারে না। আপনার ব্রাউজারেই খোলা হয়।",
        "count": "'দেখুন' চাপলে একবার খোলা গোনা হয়।",
        "expired": "এই লিংকের মেয়াদ শেষ। কাগজটি মুছে ফেলা হয়েছে।",
        "used": "এই লিংক যতবার খোলার কথা ছিল, খোলা হয়ে গেছে। কাগজটি মুছে ফেলা হয়েছে।",
        "revoked": "যিনি পাঠিয়েছেন তিনি এই লিংকটি বন্ধ করে দিয়েছেন।",
        "bad": "লিংকটি ঠিক নেই।",
        "nokey": "লিংকটি অসম্পূর্ণ — '#'-এর পরের অংশসহ পুরো লিংকটি আবার কপি করে খুলুন।",
        "wrong": "কাগজটি খোলা গেল না — লিংক বদলে গেছে বা ভাঙা।",
        "loading": "খোলা হচ্ছে…", "save": "ফাইলটি সেভ করুন",
        "limited": "অনেকবার চেষ্টা হয়েছে। এক মিনিট পরে আবার খুলুন।",
        "offline": "ইন্টারনেট নেই — আবার চেষ্টা করুন।",
        "other": "English",
    },
    "en": {
        "title": "Shared document", "brand": "Assisto Documents",
        "show": "Show the document", "until": "Link open until",
        "left": "Opens left", "times": "",
        "e2e": "This document is end-to-end encrypted: the key is only inside this link, Assisto's server cannot read it. It opens in your browser.",
        "count": "Pressing 'Show' counts one open.",
        "expired": "This link has expired. The document was deleted.",
        "used": "This link has been opened as many times as allowed. The document was deleted.",
        "revoked": "The sender turned this link off.",
        "bad": "This link is not valid.",
        "nokey": "This link is incomplete — copy the WHOLE link, including the part after '#'.",
        "wrong": "The document could not be opened — the link was changed or is broken.",
        "loading": "Opening…", "save": "Save the file",
        "limited": "Too many tries. Open it again in a minute.",
        "offline": "No internet — try again.",
        "other": "বাংলা",
    },
}

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def _lang(request):
    return "en" if request.GET.get("lang") == "en" else "bn"


def _rate_ok(request):
    key = "dshare:%s:%s" % (_ip_hash(request), timezone.now().strftime("%Y%m%d%H%M"))
    try:
        n = cache.get(key, 0) + 1
        cache.set(key, n, 90)
        return n <= RATE_PER_MIN
    except Exception:  # noqa: BLE001
        return True


def _headers(resp):
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    resp["Content-Security-Policy"] = (
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        "img-src blob: data:; frame-src blob:; object-src blob:; connect-src 'self'; "
        "base-uri 'none'; form-action 'none'")
    return resp


_JS = r"""
(function(){
var B=JSON.parse(document.getElementById('boot').textContent),T=B.T;
var btn=document.getElementById('show'),msg=document.getElementById('msg'),out=document.getElementById('out');
function say(t){msg.textContent=t;}
function b64(s){s=s.replace(/-/g,'+').replace(/_/g,'/');while(s.length%4)s+='=';var r=atob(s),u=new Uint8Array(r.length);for(var i=0;i<r.length;i++)u[i]=r.charCodeAt(i);return u;}
function rotl(x,n){return (x<<n)|(x>>>(32-n));}
function block(key32,ctr,nonce32){var s=new Uint32Array(16);s[0]=0x61707865;s[1]=0x3320646e;s[2]=0x79622d32;s[3]=0x6b206574;
for(var i=0;i<8;i++)s[4+i]=key32[i];s[12]=ctr;s[13]=nonce32[0];s[14]=nonce32[1];s[15]=nonce32[2];var x=new Uint32Array(s);
function q(a,b,c,d){x[a]+=x[b];x[d]=rotl(x[d]^x[a],16);x[c]+=x[d];x[b]=rotl(x[b]^x[c],12);x[a]+=x[b];x[d]=rotl(x[d]^x[a],8);x[c]+=x[d];x[b]=rotl(x[b]^x[c],7);}
for(var r=0;r<10;r++){q(0,4,8,12);q(1,5,9,13);q(2,6,10,14);q(3,7,11,15);q(0,5,10,15);q(1,6,11,12);q(2,7,8,13);q(3,4,9,14);}
for(i=0;i<16;i++)x[i]+=s[i];return new Uint8Array(x.buffer);}
function w32(b){var o=new Uint32Array(b.length/4);for(var i=0;i<o.length;i++)o[i]=b[4*i]|(b[4*i+1]<<8)|(b[4*i+2]<<16)|(b[4*i+3]<<24);return o;}
function chacha(key,nonce,ctr,data){var k=w32(key),n=w32(nonce),out=new Uint8Array(data.length);for(var i=0;i<data.length;i+=64){var ks=block(k,ctr++,n);for(var j=0;j<64&&i+j<data.length;j++)out[i+j]=data[i+j]^ks[j];}return out;}
function le(b){var h='';for(var i=b.length-1;i>=0;i--)h+=(b[i]<16?'0':'')+b[i].toString(16);return h?BigInt('0x'+h):0n;}
function poly(key,m){var r=le(key.subarray(0,16))&0x0ffffffc0ffffffc0ffffffc0fffffffn,s=le(key.subarray(16,32)),p=(1n<<130n)-5n,a=0n;
for(var i=0;i<m.length;i+=16){var b=m.subarray(i,Math.min(i+16,m.length));a=((a+le(b)+(1n<<BigInt(8*b.length)))*r)%p;}
a=(a+s)&((1n<<128n)-1n);var o=new Uint8Array(16);for(i=0;i<16;i++){o[i]=Number(a&255n);a>>=8n;}return o;}
function pad(n){return (16-n%16)%16;}
function open(key,nonce,sealed,aad){if(sealed.length<16)return null;var ct=sealed.subarray(0,sealed.length-16),tag=sealed.subarray(sealed.length-16);
var pk=block(w32(key),0,w32(nonce)).subarray(0,32),L=aad.length+pad(aad.length)+ct.length+pad(ct.length)+16,m=new Uint8Array(L),o=0;
m.set(aad,o);o+=aad.length+pad(aad.length);m.set(ct,o);o+=ct.length+pad(ct.length);var dv=new DataView(m.buffer);dv.setUint32(o,aad.length,true);dv.setUint32(o+8,ct.length,true);
var t=poly(pk,m),d=0;for(var i=0;i<16;i++)d|=t[i]^tag[i];if(d)return null;return chacha(key,nonce,1,ct);}
var PRE=new TextEncoder().encode('assisto-md1'),CH=65536,CC=CH+16;
function cnonce(n,i){var o=new Uint8Array(n);var v=i;for(var b=4;b<12;b++){o[b]^=v&255;v=Math.floor(v/256);}return o;}
function caad(i,last){var a=new Uint8Array(PRE.length+9);a.set(PRE,0);var v=i;for(var b=0;b<8;b++){a[PRE.length+b]=v&255;v=Math.floor(v/256);}a[PRE.length+8]=last?1:0;return a;}
function openAll(key,nonce,c){var n=Math.ceil(c.length/CC),parts=[],tot=0;for(var i=0;i<n;i++){var s=i*CC,e=Math.min(s+CC,c.length);var p=open(key,cnonce(nonce,i),c.subarray(s,e),caad(i,i==n-1));if(!p)return null;parts.push(p);tot+=p.length;}
var o=new Uint8Array(tot),k=0;parts.forEach(function(p){o.set(p,k);k+=p.length;});return o;}
var key=null;try{var h=location.hash.replace(/^#/,'');if(h){key=b64(h);if(key.length!==32)key=null;}}catch(e){key=null;}
if(!key){say(T.nokey);if(btn)btn.disabled=true;return;}
if(!btn)return;
btn.addEventListener('click',function(){btn.disabled=true;say(T.loading);
fetch(B.api,{credentials:'omit',cache:'no-store'}).then(function(r){if(r.status===429)throw T.limited;if(!r.ok)return r.json().then(function(j){throw (T[j.state]||T.bad);});return r.arrayBuffer();})
.then(function(buf){var c=new Uint8Array(buf);if(c.length<32||String.fromCharCode(c[0],c[1],c[2],c[3])!=='AVS1')throw T.wrong;
setTimeout(function(){var p=openAll(key,c.subarray(4,16),c.subarray(16));if(!p){say(T.wrong);return;}
var hl=new DataView(p.buffer).getUint32(0,true),meta=JSON.parse(new TextDecoder().decode(p.subarray(4,4+hl))),file=p.subarray(4+hl);
var mime=/^(image\/(jpeg|png|webp|gif)|application\/pdf)$/.test(meta.m||'')?meta.m:'application/octet-stream';
var url=URL.createObjectURL(new Blob([file],{type:mime}));say(meta.t||'');out.textContent='';
if(mime.indexOf('image/')===0){var im=document.createElement('img');im.src=url;im.alt=meta.t||T.title;out.appendChild(im);}
else if(mime==='application/pdf'){var ob=document.createElement('iframe');ob.src=url;ob.title=meta.t||T.title;out.appendChild(ob);}
var a=document.createElement('a');a.href=url;a.download=(meta.n||'document').replace(/[\\/:*?"<>|]/g,'_');a.textContent=T.save;a.className='btn';out.appendChild(a);},30);})
.catch(function(e){say(typeof e==='string'?e:T.offline);btn.disabled=false;});});
})();
"""

_CSS = ("body{font-family:system-ui,'Noto Sans Bengali',sans-serif;margin:0;background:#f6f7fb;color:#14161f;line-height:1.6}"
        "main{max-width:40rem;margin:0 auto;padding:1.25rem 1rem 3rem}"
        "h1{font-size:1.35rem;margin:.25rem 0 1rem}.brand{color:#3b47d6;font-weight:600}"
        ".card{background:#fff;border-radius:16px;padding:1rem;box-shadow:0 1px 4px rgba(0,0,0,.08);margin:.75rem 0}"
        ".btn{display:inline-block;min-height:48px;padding:.75rem 1.25rem;border-radius:12px;border:0;background:#3b47d6;color:#fff;font-size:1rem;text-decoration:none;margin-top:.75rem;cursor:pointer}"
        ".btn:disabled{opacity:.5}#out img{max-width:100%;border-radius:12px;margin-top:.75rem}"
        "#out iframe{width:100%;height:70vh;border:0;margin-top:.75rem}.muted{color:#4b5163;font-size:.92rem}"
        "@media (prefers-color-scheme:dark){body{background:#0f1117;color:#eceef5}.card{background:#1a1d27}.muted{color:#b4b9c9}.brand{color:#9aa3ff}}")


def _page(lang, state, link, token):
    T = TXT[lang]
    num = (lambda v: str(v).translate(_BN)) if lang == "bn" else str
    other = "" if lang == "en" else "?lang=en"
    body = ['<p class="brand">%s</p><h1>%s</h1>' % (escape(T["brand"]), escape(T["title"]))]
    if state == "open":
        until = timezone.localtime(link.expires_at).strftime("%d/%m/%Y %H:%M")
        body.append('<div class="card"><p>%s</p><p class="muted">%s: %s · %s: %s %s</p>'
                    '<button id="show" class="btn">%s</button><p class="muted">%s</p>'
                    '<p id="msg" role="status" aria-live="polite"></p><div id="out"></div></div>'
                    % (escape(T["e2e"]), escape(T["until"]), escape(num(until)),
                       escape(T["left"]), escape(num(max(0, link.max_opens - link.opens))),
                       escape(T["times"]), escape(T["show"]), escape(T["count"])))
    else:
        body.append('<div class="card"><p id="msg" role="status">%s</p></div>'
                    % escape(T.get(state, T["bad"])))
    body.append('<p><a href="%s" lang="%s">%s</a></p>'
                % (escape(other or "?"), "en" if lang == "bn" else "bn", escape(T["other"])))
    boot = json.dumps({"T": T, "api": "/d/%s/blob" % token}).replace("</", "<\\/")
    html = ('<!doctype html><html lang="%s"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer">'
            '<title>%s</title><style>%s</style></head><body><main>%s</main>'
            '<script id="boot" type="application/json">%s</script><script>%s</script></body></html>'
            % (lang, escape(T["title"]), _CSS, "".join(body), boot,
               _JS if state == "open" else ""))
    return html


@require_GET
def share_page(request, token):
    lang = _lang(request)
    if not _rate_ok(request):
        return _headers(HttpResponse(escape(TXT[lang]["limited"]), status=429,
                                     content_type="text/plain; charset=utf-8"))
    state, link = VE.peek_share(token)
    code = 404 if state == "bad" else (200 if state == "open" else 410)
    return _headers(HttpResponse(_page(lang, state, link, token), status=code,
                                 content_type="text/html; charset=utf-8"))


@require_GET
def share_blob(request, token):
    if not _rate_ok(request):
        return _headers(HttpResponse(json.dumps({"state": "limited"}), status=429,
                                     content_type="application/json"))
    state, data = VE.open_share(token)
    if state != "open":
        code = 404 if state == "bad" else 410
        return _headers(HttpResponse(json.dumps({"state": state}), status=code,
                                     content_type="application/json"))
    return _headers(HttpResponse(data, content_type="application/octet-stream"))
