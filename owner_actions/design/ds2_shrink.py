# designv2: shrink the raw TextStyle( / Color( baseline to what the code has now
# (removes migrated files, lowers counts) and lowers the guard's ceilings.
# usage: python3 owner_actions/design/ds2_shrink.py
import json,re,os
root=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
app=os.path.join(root,'app'); os.chdir(app)
ts=re.compile(r'\bTextStyle\('); col=re.compile(r'\bColor\(|\bColor\.from(?:ARGB|RGBO)\(')
p='test/ds2_lint_allow.json'; d=json.load(open(p))
def count(f):
    t=c=0
    for l in open(f,encoding='utf-8'):
        if l.lstrip().startswith('//'): continue
        code=l.split('//')[0]; t+=len(ts.findall(code)); c+=len(col.findall(code))
    return t,c
for key,idx in (('textStyle',0),('color',1)):
    for f in list(d[key]):
        n=count(f)[idx] if os.path.exists(f) else 0
        if n==0: del d[key][f]
        elif n<d[key][f]: d[key][f]=n
json.dump(d,open(p,'w'),indent=1)
files=len(set(d['textStyle'])|set(d['color'])); st=sum(d['textStyle'].values()); sc=sum(d['color'].values())
g='test/ds2_guard_test.dart'; s=open(g).read()
s=re.sub(r'const maxFiles = \d+, maxTextStyle = \d+, maxColor = \d+;',f'const maxFiles = {files}, maxTextStyle = {st}, maxColor = {sc};',s)
open(g,'w').write(s)
print(files,st,sc)
