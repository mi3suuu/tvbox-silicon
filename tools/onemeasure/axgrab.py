import json, subprocess, sys, os
S=os.path.expanduser("~/.vphone/machines/Fig/vphone.sock")
def rpc(m, p=None):
    req=json.dumps({"t":"rpc","method":m,"params":p or {}})+"\n"
    r=subprocess.run(["nc","-U",S],input=req,capture_output=True,text=True,timeout=30)
    try: return json.loads(r.stdout)
    except Exception: return None
d=rpc("ui.tree",{"max_elements":400})
els=(d or {}).get('result',{}).get('elements',[])
scr=rpc("device.screen",{}).get('result',{})
out={"screen":scr,"count":len(els),"elements":[]}
for e in els:
    f=e.get('frame') or {}
    out["elements"].append({
        "role":e.get('role'), "label":str(e.get('label','')),
        "x":round(f.get('x',0),2), "y":round(f.get('y',0),2),
        "w":round(f.get('width',0),2), "h":round(f.get('height',0),2),
    })
tag=sys.argv[1] if len(sys.argv)>1 else "unnamed"
p=f"/Users/mi3s/WorkBuddy/2026-10-21-13-54-46/tvsilicon/tvbox-silicon-fusion/tools/onemeasure/ax/{tag}.json"
json.dump(out,open(p,'w'),ensure_ascii=False,indent=1)
print(f"{tag}: {len(els)} 元素, screen={scr.get('width')}x{scr.get('height')} orient={scr.get('orientation')}")
