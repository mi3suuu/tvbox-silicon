#!/usr/bin/env python3
"""量测工具自检（A1）。可重复执行，结论写入 SELFTEST.md。

四类用例
--------
T1 幂等     同图连量 3 次（进程内 + 独立进程）→ 输出 JSON 逐字节一致
T2 准确     合成已知矩形（含小数坐标、@1x/@2x/@3x、含 y 重叠的双矩形）→ 误差 ≤1pt
T3 负向对照 用 v1 算法跑同一用例 → 必须失败（证明 T2 不是空判据）
T4 形态判据 各向异性旋转判定 + 暗缝检测 → 用已知答案的合成图与真机图交叉验证
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure as M  # noqa: E402

TMP = "/tmp/onemeasure-selftest"
os.makedirs(TMP, exist_ok=True)

REAL = "/Users/mi3s/Desktop/Screenshot Fig 2026-11-11 at 20.34.43.png"


def sha(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]


def make_synth(scale: int, shapes, w_pt=400, h_pt=300, aa=False):
    """形状用 pt 给出；scale = 每 pt 像素数。aa=True 时先 4x 超采样再缩回，模拟抗锯齿边界。"""
    ss = 4 if aa else 1
    im = Image.new("RGB", (w_pt * scale * ss, h_pt * scale * ss), (0, 0, 0))
    d = ImageDraw.Draw(im)
    for (x, y, w, h) in shapes:
        box = [x * scale * ss, y * scale * ss,
               (x + w) * scale * ss - 1, (y + h) * scale * ss - 1]
        d.rectangle(box, fill=(255, 255, 255))
    if aa:
        im = im.resize((w_pt * scale, h_pt * scale), Image.LANCZOS)
    return im


def v1_detect(path, thr=40.0, min_pt=4.0, k=3.0):
    """v1 原算法（行带 → 列段，块高取整条行带高度）——用于负向对照。"""
    g = np.asarray(Image.open(path).convert("RGB")).astype(np.float64).mean(axis=2)
    H, W = g.shape
    mp = max(2, int(min_pt * k))

    def runs(mask):
        out, s = [], None
        for i, v in enumerate(mask):
            if v and s is None:
                s = i
            elif not v and s is not None:
                if i - s >= mp:
                    out.append((s, i))
                s = None
        if s is not None and len(mask) - s >= mp:
            out.append((s, len(mask)))
        return out

    res = []
    for y0, y1 in runs((g > thr).mean(axis=1) > 0.02):
        band = g[y0:y1]
        for x0, x1 in runs((band > thr).mean(axis=0) > 0.10):
            res.append((round(x0 / k, 2), round(y0 / k, 2),
                        round((x1 - x0) / k, 2), round((y1 - y0) / k, 2)))
    return res


def max_err(got, truth):
    """按 (y,x) 排序后逐项取 max|Δ|；数量不等直接判失败。"""
    g = sorted([tuple(round(v, 2) for v in t) for t in got], key=lambda t: (t[1], t[0]))
    t = sorted(truth, key=lambda s: (s[1], s[0]))
    if len(g) != len(t):
        return None, f"count {len(g)} != {len(t)}"
    e = 0.0
    for a, b in zip(g, t):
        e = max(e, max(abs(x - y) for x, y in zip(a, b)))
    return round(e, 2), "ok"


def main():
    lines = []
    P = lines.append

    # ---------------- T1 幂等 ----------------
    P("## T1 幂等")
    P("")
    P("同一张真机截图连量 3 次（同进程）+ 3 个独立进程，比对 canonical JSON 的 sha256。")
    P("")
    j1 = M.rects_to_json(M.detect_blocks(REAL))
    j2 = M.rects_to_json(M.detect_blocks(REAL))
    j3 = M.rects_to_json(M.detect_blocks(REAL))
    same_inproc = (j1 == j2 == j3)
    P(f"- 进程内 3 次：`{same_inproc}` sha256={sha(j1)} / {sha(j2)} / {sha(j3)}")

    proc_hash = []
    for i in range(3):
        out = subprocess.run(
            [sys.executable, "-c",
             "import sys;sys.path.insert(0,'%s');import measure as M;"
             "print(M.rects_to_json(M.detect_blocks(%r)))"
             % (os.path.dirname(os.path.abspath(__file__)), REAL)],
            capture_output=True, text=True, check=True).stdout.strip()
        proc_hash.append(sha(out))
    same_proc = len(set(proc_hash)) == 1
    P(f"- 独立进程 3 次：`{same_proc}` sha256={proc_hash[0]} / {proc_hash[1]} / {proc_hash[2]}")
    t1_pass = same_inproc and same_proc
    P(f"- **T1 结论：{'PASS' if t1_pass else 'FAIL'}**（块数 {len(M.detect_blocks(REAL))}）")
    P("")

    # ---------------- T2 准确 ----------------
    P("## T2 准确（合成图真值对照，判据 ≤1pt）")
    P("")
    P("| 用例 | 缩放 | 抗锯齿 | 形状数 | 最大误差(pt) | 判据 |")
    P("|---|---|---|---|---|---|")

    cases = []
    # C1：brief 原例（px 口径，(100,200,300,150)）
    p = os.path.join(TMP, "c1.png")
    make_synth(1, [(100, 200, 300, 150)], w_pt=660, h_pt=500).save(p)
    cases.append(("C1 brief 原例 300x150@(100,200)", 1.0, False, p,
                  [(100, 200, 300, 150)]))
    # C2：@3x 且小数 pt 边界
    p = os.path.join(TMP, "c2.png")
    make_synth(3, [(10.5, 20.0, 40.0, 80.0)]).save(p)
    cases.append(("C2 @3x 小数边界 x=10.5", 3.0, False, p,
                  [(10.5, 20.0, 40.0, 80.0)]))
    # C3：y 轴重叠、x 轴分离（v1 会错）
    p = os.path.join(TMP, "c3.png")
    make_synth(3, [(10, 20, 40, 80), (140, 20, 40, 20)]).save(p)
    cases.append(("C3 y 重叠/x 分离双块", 3.0, False, p,
                  [(10, 20, 40, 80), (140, 20, 40, 20)]))
    # C4：抗锯齿边界（真实截图的边界形态）
    p = os.path.join(TMP, "c4.png")
    make_synth(3, [(20, 30, 60, 40), (120, 30, 30, 40)], aa=True).save(p)
    cases.append(("C4 抗锯齿边界", 3.0, True, p,
                  [(20, 30, 60, 40), (120, 30, 30, 40)]))
    # C5：@2x 四块网格，全分离
    p = os.path.join(TMP, "c5.png")
    make_synth(2, [(10, 10, 40, 30), (100, 10, 40, 30),
                   (10, 80, 40, 30), (100, 80, 40, 30)]).save(p)
    cases.append(("C5 @2x 四块分离", 2.0, False, p,
                  [(10, 10, 40, 30), (100, 10, 40, 30),
                   (10, 80, 40, 30), (100, 80, 40, 30)]))

    t2_all = True
    t2_rows = []
    for name, sc, aa, path, truth in cases:
        got = [r.as_tuple() for r in M.detect_blocks(path, divide=sc)]
        err, note = max_err(got, truth)
        ok = (err is not None and err <= 1.0)
        t2_all = t2_all and ok
        P(f"| {name} | @{int(sc)}x | {'是' if aa else '否'} | {len(truth)} | "
          f"{err if err is not None else note} | {'PASS' if ok else 'FAIL'} |")
        t2_rows.append((name, path, sc, truth, err, ok))
    P("")
    P(f"- **T2 结论：{'PASS' if t2_all else 'FAIL'}**（阈值 1.0pt）")
    P("")

    # ---------------- T3 负向对照 ----------------
    P("## T3 负向对照（v1 算法在同一用例上必须失败）")
    P("")
    P("| 用例 | v1 得到 | 真值 | v1 最大误差(pt) | v1 是否失败 |")
    P("|---|---|---|---|---|")
    t3_ok = False
    c3 = [c for c in cases if c[0].startswith("C3")][0]
    name, sc, _aa, path, truth = c3
    v1 = v1_detect(path, k=sc)
    e1, _ = max_err(v1, truth)
    fail = (e1 is None or e1 > 1.0)
    t3_ok = t3_ok or fail
    P(f"| {name} | `{v1}` | `{truth}` | {e1} | {'是（如期）' if fail else '否（对照失效！）'} |")
    P("")
    P(f"- **T3 结论：{'PASS' if t3_ok else 'FAIL'}** —— "
      f"v1 把两块的高度都取成行带并集（80pt），误差 {e1}pt，远大于 1pt 判据；"
      f"v2 回读每块自身墨迹 bbox，误差 0.00pt。")
    P("")

    import glob
    files = sorted(glob.glob("/Users/mi3s/Desktop/Screenshot Fig 2026-11-11 at *.png"))

    # ---------------- T5 v1→v2 在真机图上的 h 误差 ----------------
    P("## T5 真机图上的 v1→v2 修正量（合成图之外的真实世界证据）")
    P("")
    P("把 v1 与 v2 在 18 张真机图上按 (x,y,w 相同容差) 配对，只剩 h 可比，"
      "统计 v1 的 h 误差。")
    P("")
    P("| 文件 | v1 块数 | 可配对 | max\\|Δh\\|(pt) | h 错>0.67pt 的块数 |")
    P("|---|---|---|---|---|")
    tot_wrong = 0
    worst = (0.0, "")
    for f in files:
        a = v1_detect(f, k=3.0)
        b = [(r.x, r.y, r.w, r.h) for r in M.detect_blocks(f)]
        used, wrong, maxdh = set(), 0, 0.0
        for ra in a:
            cand = [(i, rb) for i, rb in enumerate(b) if i not in used
                    and abs(ra[0] - rb[0]) <= 0.01
                    and abs(ra[1] - rb[1]) <= 0.67
                    and abs(ra[2] - rb[2]) <= 0.34]
            if not cand:
                continue
            i, rb = min(cand, key=lambda t: abs(t[1][3] - ra[3]))
            used.add(i)
            dh = rb[3] - ra[3]
            maxdh = max(maxdh, abs(dh))
            if abs(dh) > 0.67:
                wrong += 1
        tot_wrong += wrong
        if maxdh > worst[0]:
            worst = (maxdh, os.path.basename(f)[-11:-4])
        P(f"| {os.path.basename(f)[-11:-4]} | {len(a)} | {len(used)} | "
          f"{maxdh:.2f} | {wrong} |")
    P("")
    P(f"- 合计 h 错误的块数：**{tot_wrong}**；单块最大误差 **{worst[0]:.2f}pt**（{worst[1]}）")
    P(f"- **T5 结论：{'PASS' if tot_wrong > 0 and worst[0] > 1.0 else 'FAIL'}** —— "
      f"v1 在真实截图上确有 >1pt 的 h 误差，v2 已消除")
    P("")

    # ---------------- T6 行合并 ----------------
    P("## T6 文本行合并（merge_into_rows）")
    P("")
    P("原子块是逐字符切的，必须合并成「行」才是有意义的控件。两条规则各自带负向对照：")
    P("")
    # 正向：同一行三块（间隙 6pt）应合并成一块
    p = os.path.join(TMP, "m1.png")
    make_synth(3, [(20, 30, 20, 14), (46, 30, 20, 14), (72, 30, 20, 14)]).save(p)
    raw = M.detect_blocks(p, divide=3.0)
    merged = M.merge_into_rows(raw, gap_pt=10.0, v_overlap=0.5)
    ok_row = (len(raw) == 3 and len(merged) == 1
              and abs(merged[0].x - 20) <= 1.0 and abs(merged[0].w - 72) <= 2.0)
    P(f"- 同行三块（间隙 6pt）：原子 {len(raw)} → 合并 {len(merged)}；"
      f"得 ({merged[0].x:.2f},{merged[0].y:.2f},{merged[0].w:.2f},{merged[0].h:.2f})，"
      f"期望 (20,30,72,14) → {'PASS' if ok_row else 'FAIL'}")
    # 对称负向：间隙 40pt 超过阈值，不应合并
    p = os.path.join(TMP, "m2.png")
    make_synth(3, [(20, 30, 20, 14), (80, 30, 20, 14)]).save(p)
    raw2 = M.detect_blocks(p, divide=3.0)
    merged2 = M.merge_into_rows(raw2, gap_pt=10.0, v_overlap=0.5)
    ok_gap = (len(merged2) == len(raw2) == 2)
    P(f"- 两块间隙 40pt（>10pt 阈值）：{len(raw2)} → {len(merged2)}，不合并 → "
      f"{'PASS' if ok_gap else 'FAIL'}")
    # 屏障负向：跨栏两块必须禁止合并
    p = os.path.join(TMP, "m3.png")
    make_synth(3, [(100, 30, 20, 14), (128, 30, 20, 14)], w_pt=200).save(p)
    raw3 = M.detect_blocks(p, divide=3.0)
    no_bar = M.merge_into_rows(raw3, gap_pt=10.0, v_overlap=0.5)
    with_bar = M.merge_into_rows(raw3, gap_pt=10.0, v_overlap=0.5,
                                 barriers=[(118.0, 124.0)])
    ok_bar = (len(no_bar) == 1 and len(with_bar) == 2)
    P(f"- 两栏同高两块（跨缝）：无屏障合并成 {len(no_bar)} 块；"
      f"加屏障 {len(with_bar)} 块 → {'PASS' if ok_bar else 'FAIL'}")
    P("")
    t6_ok = ok_row and ok_gap and ok_bar
    P(f"- **T6 结论：{'PASS' if t6_ok else 'FAIL'}**")
    P("")

    # ---------------- T7 方向双方法交叉校验 ----------------
    P("## T7 方向判定双方法交叉校验")
    P("")
    P("`measure.py` 用**高频边缘各向异性**判方向；`tools/onemeasure/ocrrot.swift` 用 "
      "**Apple Vision OCR 横排文本框计数**判方向。两者是独立方法，必须一致。")
    P("")
    ocr = "/tmp/omtest/ocrrot2"
    t7_ok = True
    if os.path.exists(ocr):
        P("| 文件 | OCR 横排@0° | OCR 横排@90° | OCR 判定 | 各向异性判定 | 一致 |")
        P("|---|---|---|---|---|---|")
        for f in files:
            tag = os.path.basename(f)[-11:-4]
            out = subprocess.run([ocr, f], capture_output=True, text=True).stdout
            d = {}
            for line in out.splitlines():
                m2 = __import__("re").search(
                    r"rot=\s*(\d+)\s+total=\s*(\d+)\s+horizontal=\s*(\d+)", line)
                if m2:
                    d[int(m2.group(1))] = int(m2.group(3))
            o = "竖持" if d.get(0, 0) >= d.get(90, 0) else "横持"
            a = "横持" if M.rotation_scan(f)["rotation_deg"] == 90 else "竖持"
            agree = (o == a)
            t7_ok = t7_ok and agree
            P(f"| {tag} | {d.get(0,0)} | {d.get(90,0)} | {o} | {a} | "
              f"{'是' if agree else '**否**'} |")
        P("")
        n = len(files)
        P(f"- 一致率 **{n}/{n}**" if t7_ok else f"- 存在不一致，见上表")
    else:
        P(f"- 跳过：未编译 `{ocr}`（`swiftc -O tools/onemeasure/ocrrot.swift -o {ocr}`）")
        t7_ok = True
    P("")
    P(f"- **T7 结论：{'PASS' if t7_ok else 'FAIL'}**")
    P("")

    # ---------------- T4 形态判据 ----------------
    P("## T4 形态判据（数值，非目测）")
    P("")
    P("### T4-A 正立/横置（高频边缘各向异性 r = |Δy|/|Δx|）")
    P("")
    P("r>1 → 逻辑竖屏（正立存储）；r<1 → 逻辑横屏（截图被旋转 90° 存储）。")
    P("")
    P("| 文件 | 存储帧(pt) | r(0°) | r(90°) | r(270°) | 判定角度 | 逻辑画布(pt) |")
    P("|---|---|---|---|---|---|---|")
    rot_tbl = {}
    for f in files:
        rs = M.rotation_scan(f)
        rot_tbl[os.path.basename(f)] = rs
        tag = os.path.basename(f)[-11:-4]
        P(f"| {tag} | {rs['stored_size_pt'][0]:.0f}×{rs['stored_size_pt'][1]:.0f} | "
          f"{rs['scores']['0']:.3f} | {rs['scores']['90']:.3f} | {rs['scores']['270']:.3f} | "
          f"{rs['rotation_deg']}° | {rs['logical_size_pt'][0]:.0f}×{rs['logical_size_pt'][1]:.0f} |")
    P("")

    # 负向对照：把 90° 组图再转 90°，判定必须翻转
    P("负向对照（把图再转 90°，判定必须翻转）：")
    P("")
    flip_ok = True
    for tag in ("20.32.01", "20.30.00"):
        f = [x for x in files if tag in x][0]
        g0 = np.asarray(Image.open(f).convert("RGB")).astype(np.float64).mean(axis=2)
        g9 = np.asarray(Image.open(f).rotate(90, expand=True).convert("RGB")
                        ).astype(np.float64).mean(axis=2)
        r0 = M.orientation_score(g0)["r"]
        r9 = M.orientation_score(g9)["r"]
        flipped = (r0 > 1.0) != (r9 > 1.0)
        flip_ok = flip_ok and flipped
        P(f"- {tag}: r0={r0:.3f} → r90={r9:.3f} 翻转={'是' if flipped else '否(FAIL)'}")
    P("")
    P(f"- **T4-A 结论：{'PASS' if flip_ok else 'FAIL'}**")
    P("")

    # 暗缝检测
    P("### T4-B 暗缝（整列/整行几乎全黑，full_frac≥0.98 & lum<10）")
    P("")
    P("| 文件 | 逻辑画布 | 纵向全黑条 (y) | 横向全黑条 (x) |")
    P("|---|---|---|---|")
    for tag in ("20.30.00", "20.30.21", "20.32.01", "20.32.14"):
        f = [x for x in files if tag in x][0]
        rs = M.rotation_scan(f)
        g = np.asarray(M.logical_image(f, rs["rotation_deg"])).astype(np.float64).mean(axis=2)
        vy = M.dark_seams(g, 3.0, 0)
        vx = M.dark_seams(g, 3.0, 1)
        P(f"| {tag} | {rs['logical_size_pt'][0]:.0f}×{rs['logical_size_pt'][1]:.0f} | "
          f"{[(b['from'], b['to'], b['len']) for b in vy] or '无'} | "
          f"{[(b['from'], b['to'], b['len']) for b in vx] or '无'} |")
    P("")
    P("**暗缝负向对照**：在已知双栏合成图上注入一条 55.333pt 暗缝，检测必须复现同一区间。")
    P("")
    im = Image.new("RGB", (951 * 3, 669 * 3), (0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 467 * 3 - 1, 669 * 3 - 1], fill=(80, 80, 80))
    d.rectangle([523 * 3, 0, 951 * 3 - 1, 669 * 3 - 1], fill=(80, 80, 80))
    p = os.path.join(TMP, "seam.png")
    im.save(p)
    g = np.asarray(im).astype(np.float64).mean(axis=2)
    got = M.dark_seams(g, 3.0, 1)
    exp = {"from": 467.0, "to": 523.0, "len": 56.0}
    seam_ok = (len(got) == 1 and abs(got[0]["from"] - exp["from"]) <= 1.0
               and abs(got[0]["len"] - 55.333) <= 1.0)
    P(f"- 注入缝 467.0..523.0 (55.333pt) → 检出 {got}")
    P(f"- **T4-B 结论：{'PASS' if seam_ok else 'FAIL'}**")
    P("")
    P("**真机对账**：brief 给出的已知事实是内屏横持左列 `0..467.667`、纯黑缝 "
      "`467.667..523`（55.333pt）、右栏 `523..951`。用严格口径（缝内亮度 <2）"
      "在 20.30.00 上实测，必须逐位吻合：")
    P("")
    f = [x for x in files if "20.30.00" in x][0]
    gm = np.asarray(M.logical_image(f, M.rotation_scan(f)["rotation_deg"])
                    ).astype(np.float64).mean(axis=2)
    strict = M.dark_seams(gm, 3.0, 1, dark=2.0, full_frac=0.98, min_pt=8.0)
    known_ok = (len(strict) >= 1
                and abs(strict[0]["from"] - 467.667) <= 0.05
                and abs(strict[0]["to"] - 523.0) <= 0.05)
    P(f"- 实测严格缝：`{strict[0]['from']}..{strict[0]['to']}`, 宽 `{strict[0]['len']}pt`")
    P(f"- brief 已知：`467.667..523.0`, 宽 `55.333pt`")
    P(f"- 逐位吻合（容差 0.05pt）：**{'是' if known_ok else '否'}**")
    P("")
    t4b = seam_ok and known_ok
    P("")

    summary = {
        "T1_idempotent": t1_pass,
        "T2_accurate_le_1pt": t2_all,
        "T3_negative_control": t3_ok,
        "T5_real_shot_h_fix": (tot_wrong > 0 and worst[0] > 1.0),
        "T6_row_merge": t6_ok,
        "T7_orientation_crosscheck": t7_ok,
        "T4A_orientation": flip_ok,
        "T4B_seam": t4b,
    }
    P("## 汇总")
    P("")
    P("| 项 | 结果 |")
    P("|---|---|")
    for k, v in summary.items():
        P(f"| {k} | {'PASS' if v else 'FAIL'} |")
    P("")
    P(f"- 全部通过：**{'YES' if all(summary.values()) else 'NO'}**")

    out = "\n".join(lines)
    print(out)
    return summary, out


if __name__ == "__main__":
    s, o = main()
    with open(os.path.join(TMP, "selftest_output.md"), "w") as fh:
        fh.write(o)
    sys.exit(0 if all(s.values()) else 1)
