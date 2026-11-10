# designv2: mark a screen done — recount its raw TextStyle/Color in app/test/ds2_lint_allow.json,
# add its gallery shot to ds2_golden_test, tick owner_actions/DESIGN_SCREENS_CHECKLIST_BN.md.
# usage: python3 owner_actions/design/ds2_mark.py <batch> <gallery_shot or -> <file under app/lib/> "<Bangla note>"
import json,re,sys
batch,shot,f,note=sys.argv[1:5]
import os
root=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))+'/'
p=root+'app/test/ds2_lint_allow.json'; d=json.load(open(p))
lf='lib/'+f
def cnt(rx): return sum(len(re.findall(rx,l.split('//')[0])) for l in open(root+'app/'+lf) if not l.lstrip().startswith('//'))
for k,rx in (('textStyle',r'\bTextStyle\('),('color',r'\bColor\(|\bColor\.from(?:ARGB|RGBO)\(')):
    n=cnt(rx)
    if n: d[k][lf]=n
    else: d[k].pop(lf,None)
json.dump(d,open(p,'w'),indent=1)
if shot!='-':
    g=root+'app/test/ds2_golden_test.dart'; s=open(g).read()
    if f"'{shot}'" not in s:
        s=s.replace("\n];\n",f"\n  '{shot}', // batch {batch}\n];\n",1); open(g,'w').write(s)
c=root+'owner_actions/DESIGN_SCREENS_CHECKLIST_BN.md'; s=open(c).read()
s=s.replace(f"- ⬜ — `{f}`",f"- ✅ batch {batch} ({note}) — `{f}`")
bn=str.maketrans('0123456789','০১২৩৪৫৬৭৮৯')
done=s.count('- ✅')+s.count('- 🎨'); total=s.count('\n- ')
s=re.sub(r"\*\*স্ক্রিন শেষ: [^*]*\*\*[^\n]*",f"**স্ক্রিন শেষ: {str(done).translate(bn)} / মোট {str(total).translate(bn)}**",s)
open(c,'w').write(s); print(done,total)
