#!/usr/bin/env python3
"""映匣 App 层静态审计（不依赖模拟器）
每条规则都必须有正负对照，否则不许进闸门。"""
import re, glob, sys, os

def dead_state(files):
    """死交互：@State showsXxx/isShowingXxx 只声明无消费（$name 绑定算消费）"""
    out=[]
    for f in files:
        src=open(f,encoding="utf-8",errors="ignore").read()
        for m in re.finditer(r'@State\s+(?:private\s+)?var\s+(shows\w+|isShowing\w+|isPresenting\w+)\s*(?::\s*Bool)?\s*=\s*(?:false|true)', src):
            name=m.group(1); line=src[:m.start()].count("\n")+1
            total=len(re.findall(r'(?<![\w$])'+re.escape(name)+r'\b', src))
            binds=len(re.findall(r'\$'+re.escape(name)+r'\b', src))
            if total<=1 and binds==0:
                out.append((f,line,name,"DEAD","只声明无任何引用"))
            elif total==2 and binds==0:
                out.append((f,line,name,"SUSPECT","只声明+一处非绑定引用"))
    return out

def appstorage_orphan(files, allfiles):
    """假开关：@AppStorage("key") 的 key 在其它文件有没有被读"""
    keys={}
    for f in files:
        src=open(f,encoding="utf-8",errors="ignore").read()
        for m in re.finditer(r'@AppStorage\(\s*"([^"]+)"', src):
            keys.setdefault(m.group(1),[]).append((f,src[:m.start()].count("\n")+1))
    out=[]
    corpus="".join(open(f,encoding="utf-8",errors="ignore").read() for f in allfiles)
    for k,where in keys.items():
        # 除声明处外，全文是否还有对该 key 字面量的引用
        n=corpus.count('"'+k+'"')
        if n<=len(where):
            out.append((where[0][0],where[0][1],k,"ORPHAN",f"key 只在 {n} 处声明，无其它读取"))
    return out

def dup_keys(allfiles):
    """两套键：同一语义前缀下存在两个近似 key 字面量"""
    ks=set()
    for f in allfiles:
        src=open(f,encoding="utf-8",errors="ignore").read()
        for m in re.finditer(r'"([a-z][A-Za-z0-9.]{5,40})"', src):
            s=m.group(1)
            if '.' in s and not s.startswith(('http','vnd')):
                ks.add(s)
    return sorted(ks)

if __name__=="__main__":
    mode=sys.argv[1] if len(sys.argv)>1 else "scan"
    app=sorted(glob.glob("App/*.swift"))
    if mode=="scan":
        print("=== 规则1 死交互 ===")
        r=dead_state(app); print(f"命中 {len(r)}")
        for x in r: print("  ",x)
        print("\n=== 规则2 AppStorage 孤立 key ===")
        r=appstorage_orphan(app,app); print(f"命中 {len(r)}")
        for x in r[:15]: print("  ",x)
        print("\n=== 规则3 点号 key 清单（人工判同义重复）===")
        d=dup_keys(app); print(f"共 {len(d)} 个")
    else:
        # 正负对照
        print("正对照 dead_state:", dead_state(["/tmp/ds_pos.swift"]))
        print("负对照 dead_state:", dead_state(["/tmp/ds_neg.swift"]))
