import re, glob, sys

def scan(files):
    out=[]
    for f in files:
        try: src=open(f,encoding="utf-8",errors="ignore").read()
        except: continue
        for m in re.finditer(r'@State\s+(?:private\s+)?var\s+(shows\w+|isShowing\w+)\s*(?::\s*Bool)?\s*=\s*(?:false|true)', src):
            name=m.group(1); line=src[:m.start()].count("\n")+1
            # 关键修正：$name 绑定也算消费
            total=len(re.findall(r'(?<![\w$])'+re.escape(name)+r'\b', src))
            binds=len(re.findall(r'\$'+re.escape(name)+r'\b', src))
            if total<=1 and binds==0:
                out.append((f,line,name,total,binds,"DEAD: 只声明，无任何引用"))
            elif total==2 and binds==0:
                out.append((f,line,name,total,binds,"SUSPECT: 只声明+一处非绑定引用"))
    return out

if __name__=="__main__":
    mode=sys.argv[1] if len(sys.argv)>1 else "scan"
    if mode=="scan":
        r=scan(glob.glob("App/*.swift"))
        print(f"命中 {len(r)} 条")
        for f,l,n,t,b,why in r: print(f"  {f}:{l} {n} total={t} bind={b}  {why}")
    else:
        # 正对照：造一个必然命中的样本
        r=scan(["/tmp/deadstate_positive.swift"])
        print(f"正对照命中 {len(r)} 条（应为 1）")
        for f,l,n,t,b,why in r: print(f"  {f}:{l} {n}  {why}")
