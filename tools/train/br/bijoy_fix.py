"""Decode the broken-ToUnicode Bangla text layer of the BR west-zone PDF."""
import re, unicodedata
G = {
 'Ӆ':'পু','ɼ':'ক্স','ɛ':'প্র','ˉ':'ন্ত','ʊ':'ঙ্গ','ʛ':'ঞ্জ','ʙ':'ঞ্চ','ɪ':'টি','Ӌ':'বু','Ҏ':'খু',
 'ˍ':'ন্দ','͵':'শ্ব','ɑ':'ট্র','Ɋ':'গ্র','̲':'কু','̳':'কু','ː':'ন্ধ','̙':'স্ট','ɝ':'ব্র','Ɉ':'ক্র',
 'ɢ':'শ্র','Ҷ':'তু','ɻ':'ক্ষ','ʹ':'শু','\u0374':'শু','ӈ':'ফু','̂':'ল্লা','ʾ':'দ্ম','ɖ':'ত্র','Ͱ':'রু','ͱ':'রু',
 'ɮ':'ক্ক','ҙ':'চু','і':'ব্দু','ӑ':'মু','˯':'ম্ভ','Ε':'ব্য','ʯ':'ত্ত','Ӡ':'সূ','ˌ':'ন্দ্র','ҿ':'ধু',
 'Ӎ':'বৃ','˴':'ক্স','Ӏ':'ধূ','ӗ':'লু','Ӓ':'মূ','ҧ':'টু','ӟ':'সু','˅':'ন্ড','ɇ':'্য','˂':'ন্ট',
 '˷':'ল্ট','͍':'দ্রু','͎':'দ্রু','̶':'গুড়ি','ϟ':'থ','̃':'শ্চ','˖':'প্ত','̡':'স্প','ҭ':'ত্ত','Ҽ':'দু',
 '̌':'ষ্ট','̜':'ত্য',
}
VS = 'াীুূৃৄৗঁংঃ়্'
PRE = {'ǯ':'ে','ে':'ে','ি':'ি','ǰ':'ৈ','ৈ':'ৈ'}
BN2 = str.maketrans('০১২৩৪৫৬৭৮৯','0123456789')
def units(s):
    out=[]
    for ch in s:
        if ch=='ϲ': out.append(('v','াঁ')); continue
        if ch in G: out.append(('c',G[ch])); continue
        if ch in PRE: out.append(('p',PRE[ch])); continue
        if ch=='ȟ': out.append(('r','র্')); continue
        if ch in VS or unicodedata.category(ch)=='Mn': out.append(('v',ch)); continue
        if 'ক'<=ch<='হ' or ch in 'ড়ঢ়য়ৎ': out.append(('c',ch)); continue
        out.append(('o',ch))
    return out
def fix(s):
    s=s.replace('\u09dc','\u09a1\u09bc').replace('\u09dd','\u09a2\u09bc').replace('\u09df','\u09af\u09bc')
    u=units(s); res=[]; pend=[]
    i=0
    # attach following hasanta+consonant into cluster
    merged=[]
    for k,t in u:
        if merged and merged[-1][0]=='c' and merged[-1][1].endswith('্') and k=='c':
            merged[-1]=('c',merged[-1][1]+t); continue
        if k=='v' and t=='়' and merged and merged[-1][0]=='c':
            merged[-1]=('c',merged[-1][1]+t); continue
        if k=='v' and t=='্' and merged and merged[-1][0]=='c':
            merged[-1]=('c',merged[-1][1]+t); continue
        merged.append((k,t))
    out=[]
    for k,t in merged:
        if k=='p': pend.append(t); continue
        if k=='r':
            # reph goes before the previous consonant unit
            for j in range(len(out)-1,-1,-1):
                if out[j][0]=='c': out[j]=('c','র্'+out[j][1]); break
            continue
        out.append((k,t))
        if k=='c' and pend:
            # cluster may be followed by ya-phala glyph etc; apply after cluster
            out.append(('v',''.join(pend))); pend=[]
        elif k=='o' and pend:
            out.insert(len(out)-1,('v',''.join(pend))); pend=[]
    s=''.join(t for _,t in out)+''.join(pend)
    s=s.replace('ে্য','্যে').replace('ি্য','্যি')
    s=s.replace('ো','ো').replace('ৌ','ৌ')
    s=unicodedata.normalize('NFC',s)
    return s.replace('ড়','ড়').replace('ঢ়','ঢ়').replace('য়','য়')
def num(s):
    s=s.translate(BN2)
    return re.sub(r'\D','',s)
