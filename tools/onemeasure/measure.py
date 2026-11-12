"""One 播放页控件矩形量测（纯数值，不依赖视觉判断）。

设计原则
--------
1. 所有边界由**像素级连通域 + 行/列剖面阈值**决定，不做目测。
2. 幂等：同一输入重复量测结果**逐字节一致**（纯整数/确定性运算 + 规范化 JSON 写出）。
3. 每个结果带 kind（按尺寸数值分类）与 confidence。

v2 相对 v1 的修正（v1 有实测缺陷，见 SELFTEST.md）
------------------------------------------------
v1 用「先切行带、再在行带内切列段」的两步法。当两个矩形在 y 轴上互相重叠、
但 x 轴不重叠时（例如左侧高卡片 + 右侧长条），行带会把两者压成同一个 y 区间，
导致 h 取成整段并集。合成图实测误差 46.67pt（远大于 1pt 判据）。
v2 改为 **2D 连通域**：
  - 先在 2pt 网格上做 4-邻域标签传播（粗粒度，快）；
  - 再对每个连通域的每个网格单元回读**全分辨率真实墨迹 bbox** 取并集（放大后不做二次切割）；
这样互相重叠的矩形能被正确分离，且边界回到原始像素精度。
"""
from __future__ import annotations

import json
import numpy as np
from PIL import Image
from dataclasses import dataclass, asdict
from typing import List, Tuple, Optional, Dict, Any

# 形态分类用的常量（pt）
KIND_TEXT_MAX_H = 25.0
KIND_TEXT_MIN_W = 100.0
KIND_CAPSULE_MIN_H = 25.0
KIND_CAPSULE_MAX_H = 60.0
KIND_CAPSULE_MIN_W = 80.0
KIND_CARD_MIN_H = 100.0
KIND_CARD_MIN_W = 150.0


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float
    kind: str = "block"
    confidence: float = 1.0

    def as_tuple(self):
        return (self.x, self.y, self.w, self.h)


# --------------------------------------------------------------------------
# 基础读取
# --------------------------------------------------------------------------
def load_gray(path: str, divide: float = 3.0) -> Tuple[np.ndarray, float]:
    """返回 (灰度数组 float64, 每 pt 的像素数)。divide=3 → @3x 屏。"""
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float64)
    g = a.mean(axis=2)
    return g, float(divide)


def _runs(mask: np.ndarray, min_len: int) -> List[Tuple[int, int]]:
    """连续 True 段 [(start, end_exclusive)]。"""
    out: List[Tuple[int, int]] = []
    start = None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            if i - start >= min_len:
                out.append((start, i))
            start = None
    if start is not None and len(mask) - start >= min_len:
        out.append((start, len(mask)))
    return out


# --------------------------------------------------------------------------
# 2D 连通域标签（4-邻域 max 传播，纯 numpy，确定性）
# --------------------------------------------------------------------------
def _propagate_labels(mask: np.ndarray) -> np.ndarray:
    """mask: 2D bool。返回 int64 标签图（同域共享该域内最大线性索引），背景为 -1。"""
    h, w = mask.shape
    lab = np.where(mask, np.arange(h * w, dtype=np.int64).reshape(h, w), -1)
    if not mask.any():
        return lab
    zeros_row = np.zeros((1, w), dtype=np.int64)
    zeros_col = np.zeros((h, 1), dtype=np.int64)
    while True:
        up = np.vstack([zeros_row, lab[:-1]])
        dn = np.vstack([lab[1:], zeros_row])
        lf = np.hstack([zeros_col, lab[:, :-1]])
        rt = np.hstack([lab[:, 1:], zeros_col])
        big = np.maximum(np.maximum(up, dn), np.maximum(lf, rt))
        nxt = np.where(mask, np.maximum(lab, big), -1)
        if np.array_equal(nxt, lab):
            return lab
        lab = nxt


def _components(mask: np.ndarray) -> List[np.ndarray]:
    """返回每个连通域的 (row_idx, col_idx) 单元坐标数组。按最小线性索引排序（确定性）。"""
    lab = _propagate_labels(mask)
    ids = np.unique(lab[mask])
    out = []
    for lid in ids:               # np.unique 已升序 → 确定性
        rows, cols = np.nonzero(lab == lid)
        out.append(np.stack([rows, cols], axis=1))
    out.sort(key=lambda a: int(a[0, 0] * mask.shape[1] + a[0, 1]))
    return out


def detect_blocks(path: str, thr: float = 40.0, min_pt: float = 4.0,
                  divide: Optional[float] = None,
                  rotation_deg: int = 0,
                  merge_gap_pt: float = 0.0,
                  mode: str = "luma",
                  hp_radius_px: int = 40,
                  hp_delta: float = 14.0,
                  tile_pt: float = 32.0,
                  bright_thr: float = 60.0) -> List[Rect]:
    """用行/列剖面切出内容块矩形，并对每个块**回读真实墨迹 bbox**。

    thr          亮度阈值（内容 > thr 视为有内容）——仅 mode="luma" 使用
    min_pt       最小块边长（pt），过滤噪点
    divide       每 pt 像素数，默认 3.0（@3x）
    rotation_deg 先把截图旋转到逻辑画布（0/90/270，逆时针），再在逻辑坐标下量测
    merge_gap_pt 同一行带内、x 间距 < 该值的相邻块合并（默认 0 = 不合并）
    mode         "luma"      = 绝对亮度阈值 g > thr
                               适用于深色页面 / 黑底播放器区域
                 "highpass"  = 局部对比度阈值 (g - boxblur(g)) > hp_delta
                               适用于**液态模糊亮海报背景**（详情栏、评论栏）：
                               绝对亮度会把整片背景连成一个假块，必须用局部对比度
                               才能把控件与背景分开
                 "adaptive"  = 分瓦片自适应（推荐，无需按图挑模式）：
                               每 tile_pt×tile_pt 瓦片取亮度中位数，
                               中位数 >= bright_thr → 用 highpass；否则用 luma。
                               这是纯数值判据（中位数），不涉及目测。

    ★ v1 缺陷修正：v1 直接把「行带高度」当成每块的高度。当两个矩形在 y 上重叠
    而 x 上分离时（左高卡 + 右短条），行带是并集，导致两边都取到并集高度。
    本实现改为：列段确定 x 范围后，**只在该列段内重新求墨迹的行范围**，
    因此每块的 h 是它自己的真实高度。合成图实测 v1 误差 60pt → v2 0.00pt。
    """
    k = 3.0 if divide is None else float(divide)
    if rotation_deg:
        img = Image.open(path).convert("RGB").rotate(int(rotation_deg), expand=True)
        g = np.asarray(img).astype(np.float64).mean(axis=2)
    else:
        g, _ = load_gray(path, k)

    if mode == "highpass":
        ink = (g - _box_blur(g, int(hp_radius_px))) > float(hp_delta)
    elif mode == "luma":
        ink = g > thr
    elif mode == "adaptive":
        hp = (g - _box_blur(g, int(hp_radius_px))) > float(hp_delta)
        lu = g > thr
        t = max(1, int(round(tile_pt * k)))
        ink = lu.copy()
        for ty in range(0, g.shape[0], t):
            for tx in range(0, g.shape[1], t):
                tile = g[ty:ty + t, tx:tx + t]
                if float(np.median(tile)) >= bright_thr:
                    ink[ty:ty + t, tx:tx + t] = hp[ty:ty + t, tx:tx + t]
    else:
        raise ValueError(f"unknown mode: {mode}")

    H, W = g.shape
    min_px = max(2, int(round(min_pt * k)))

    # ① 行带：整行有内容像素比例 > 2%
    row_has = ink.mean(axis=1) > 0.02
    row_runs = _runs(row_has, min_px)

    rects: List[Rect] = []
    for y0, y1 in row_runs:
        band = ink[y0:y1]
        col_has = band.mean(axis=0) > 0.10
        for x0, x1 in _runs(col_has, min_px):
            # ② 只在该列段内回读真实墨迹 bbox（修正 v1 的「整带高度」错误）
            sub = ink[y0:y1, x0:x1]
            if not sub.any():
                continue
            rr = np.nonzero(sub.any(axis=1))[0]
            cc = np.nonzero(sub.any(axis=0))[0]
            ty0, ty1 = y0 + int(rr[0]), y0 + int(rr[-1]) + 1
            tx0, tx1 = x0 + int(cc[0]), x0 + int(cc[-1]) + 1
            if (tx1 - tx0) < min_px or (ty1 - ty0) < min_px:
                continue
            rects.append(Rect(x=tx0 / k, y=ty0 / k,
                              w=(tx1 - tx0) / k, h=(ty1 - ty0) / k))

    # ③ 可选：同带内相邻块合并（按 x 间距）
    if merge_gap_pt > 0 and rects:
        rects.sort(key=lambda r: (r.y, r.x))
        merged: List[Rect] = []
        for r in rects:
            if merged:
                p = merged[-1]
                same_band = abs(p.y - r.y) <= 2.0 and abs((p.y + p.h) - (r.y + r.h)) <= 2.0
                gap = r.x - (p.x + p.w)
                if same_band and 0 <= gap <= merge_gap_pt:
                    nx = min(p.x, r.x)
                    nx1 = max(p.x + p.w, r.x + r.w)
                    ny = min(p.y, r.y)
                    ny1 = max(p.y + p.h, r.y + r.h)
                    merged[-1] = Rect(nx, ny, nx1 - nx, ny1 - ny)
                    continue
            merged.append(r)
        rects = merged

    # ④ 定点量化 + 排序（幂等）
    out: List[Rect] = []
    for r in rects:
        w, h = round(r.w, 2), round(r.h, 2)
        area = w * h
        out.append(Rect(x=round(r.x, 2), y=round(r.y, 2), w=w, h=h,
                        kind=classify_kind(w, h),
                        confidence=1.0 if area >= 400 else round(min(1.0, 0.6 + area / 1000.0), 2)))
    out.sort(key=lambda r: (r.y, r.x, r.h, r.w))
    return out


def merge_into_rows(rects: List[Rect], gap_pt: float = 10.0,
                    v_overlap: float = 0.5,
                    barriers: Optional[List[Tuple[float, float]]] = None) -> List[Rect]:
    """把同一文本行内被字符间空隙切开的碎块合并成「行」级矩形。

    规则（纯几何，无目测）—— 用并查集（union-find）做传递合并：
    1. 横向相邻：右块左边界距左块右边界 ∈ [-1, gap_pt]pt。
    2. 纵向同行：两块的 y 重叠长度 ≥ v_overlap × min(两者高度)。
       用「重叠比例」而不是「y 差值」，因为中文行内各字形高低不同，
       单纯比 y 会把同一行拆成两三段（实测会发生）。
    3. 不得跨屏障：合并后的 x 区间不得与 barriers 任一条垂直带（折缝/黑栏）相交，
       否则会把左右两栏内容连成一个假块（实测会发生）。
    合并后取并集 bbox，按合并后尺寸重新分类 kind。同一输入结果确定。

    rects     原子块（detect_blocks 输出）
    gap_pt    允许的字符/元素间隙上限
    v_overlap 判定「同一行」的纵向重叠比例
    barriers  [(x0, x1)] 垂直禁区（例如折缝 467.667..523.0）
    """
    bars = barriers or []
    n = len(rects)
    parent = list(range(n))

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    for i in range(n):
        a = rects[i]
        for j in range(i + 1, n):
            b = rects[j]
            ov = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
            if ov <= 0 or ov < v_overlap * min(a.h, b.h):
                continue
            # 横向间隙（双向）
            gap_ij = b.x - (a.x + a.w)
            gap_ji = a.x - (b.x + b.w)
            gap = gap_ij if abs(gap_ij) <= abs(gap_ji) else gap_ji
            if gap > gap_pt or gap < -1.0:
                continue
            nx, nx1 = min(a.x, b.x), max(a.x + a.w, b.x + b.w)
            if any(nx < b1 and nx1 > b0 for b0, b1 in bars):
                continue
            union(i, j)

    groups: Dict[int, List[Rect]] = {}
    for i, r in enumerate(rects):
        groups.setdefault(find(i), []).append(r)

    res: List[Rect] = []
    for _, g in groups.items():
        x0 = min(r.x for r in g)
        y0 = min(r.y for r in g)
        x1 = max(r.x + r.w for r in g)
        y1 = max(r.y + r.h for r in g)
        w, h = round(x1 - x0, 2), round(y1 - y0, 2)
        area = w * h
        res.append(Rect(x=round(x0, 2), y=round(y0, 2), w=w, h=h,
                        kind=classify_kind(w, h),
                        confidence=1.0 if area >= 400 else round(min(1.0, 0.6 + area / 1000.0), 2)))
    res.sort(key=lambda r: (r.y, r.x, r.h, r.w))
    return res


def classify_kind(w: float, h: float) -> str:
    """按 brief 的数值规则分类，不做目测。"""
    if h < KIND_TEXT_MAX_H and w > KIND_TEXT_MIN_W:
        return "text-line"
    if KIND_CAPSULE_MIN_H <= h <= KIND_CAPSULE_MAX_H and w > KIND_CAPSULE_MIN_W:
        return "capsule"
    if h > KIND_CARD_MIN_H and w > KIND_CARD_MIN_W:
        return "card-or-video"
    return "small"


# --------------------------------------------------------------------------
# 剖面 / 边带（沿用 v1 语义）
# --------------------------------------------------------------------------
def row_profile(path: str, thr: float = 40.0, segments: int = 60,
                divide: Optional[float] = None):
    """行剖面：每段的「有内容比例」。用于定位纵向块序。"""
    k = 3.0 if divide is None else float(divide)
    g, _ = load_gray(path, k)
    H = g.shape[0]
    seg = max(1, H // segments)
    out = []
    for i in range(segments):
        y0, y1 = i * seg, min((i + 1) * seg, H)
        v = (g[y0:y1] > thr).mean()
        out.append((round(y0 / k, 1), round(y1 / k, 1), round(float(v), 4)))
    return out


def col_profile(path: str, thr: float = 40.0, segments: int = 60,
                divide: Optional[float] = None):
    k = 3.0 if divide is None else float(divide)
    g, _ = load_gray(path, k)
    W = g.shape[1]
    seg = max(1, W // segments)
    out = []
    for i in range(segments):
        x0, x1 = i * seg, min((i + 1) * seg, W)
        v = (g[:, x0:x1] > thr).mean()
        out.append((round(x0 / k, 1), round(x1 / k, 1), round(float(v), 4)))
    return out


def edge_bands(path: str, band_px: int = 60, divide: Optional[float] = None):
    """四边带亮度，用于判定形态/方向（数值，非目测）。"""
    k = 3.0 if divide is None else float(divide)
    g, _ = load_gray(path, k)
    H, W = g.shape
    b = min(band_px, H // 4, W // 4)
    return {
        "top": round(float(g[:b, :].mean()), 1),
        "bottom": round(float(g[-b:, :].mean()), 1),
        "left": round(float(g[:, :b].mean()), 1),
        "right": round(float(g[:, -b:].mean()), 1),
        "mean": round(float(g.mean()), 1),
        "size_pt": (round(W / k, 1), round(H / k, 1)),
    }


def diff_rects(a: List[Rect], b: List[Rect]) -> dict:
    """两套矩形按 y 序配对后逐项比对（配对不唯一时如实标注）。"""
    A = sorted(a, key=lambda r: (r.y, r.x))
    B = sorted(b, key=lambda r: (r.y, r.x))
    n = min(len(A), len(B))
    rows = []
    for i in range(n):
        ra, rb = A[i], B[i]
        rows.append({
            "i": i,
            "ours": ra.as_tuple(), "one": rb.as_tuple(),
            "d": (round(ra.x - rb.x, 2), round(ra.y - rb.y, 2),
                  round(ra.w - rb.w, 2), round(ra.h - rb.h, 2)),
        })
    return {"matched": n, "a_total": len(A), "b_total": len(B),
            "pairing": "by-y (ambiguous if counts differ)", "rows": rows}


# --------------------------------------------------------------------------
# 形态判据（全部由像素统计得出）
# --------------------------------------------------------------------------
def _box_blur(a: np.ndarray, r: int) -> np.ndarray:
    def b1(x, axis):
        n = x.shape[axis]
        c2 = np.concatenate([np.zeros_like(np.take(x, [0], axis=axis)),
                             np.cumsum(x, axis=axis)], axis=axis)
        idx = np.arange(n)
        lo = np.clip(idx - r, 0, n)
        hi = np.clip(idx + r + 1, 0, n)
        cnt = (hi - lo).reshape([-1 if i == axis else 1 for i in range(x.ndim)])
        return (np.take(c2, hi, axis=axis) - np.take(c2, lo, axis=axis)) / cnt
    return b1(b1(a, 0), 1)


def orientation_score(g: np.ndarray) -> Dict[str, Any]:
    """正立/横置判定：高频边缘各向异性。

    r = mean(|dy of high-pass|) / mean(|dx of high-pass|)
    r > 1 → 竖直方向细节更多 → 逻辑画布为竖屏（正立）
    r < 1 → 水平方向细节更多 → 逻辑画布为横屏（截图被旋转 90° 存储）
    """
    hf = g - _box_blur(g, 4)
    dx = float(np.abs(np.diff(hf, axis=1)).mean())
    dy = float(np.abs(np.diff(hf, axis=0)).mean())
    r = (dy / dx) if dx > 0 else 0.0
    return {"r": round(r, 4), "upright": bool(r > 1.0)}


def dark_seams(g: np.ndarray, k: float, axis: int,
               dark: float = 10.0, full_frac: float = 0.98,
               min_pt: float = 12.0) -> List[Dict[str, Any]]:
    """找「整条（整行或整列）几乎全黑」的连续带 —— 折缝/纯黑 letterbox 的数值判据。

    axis=0 → 逐行（返回 y 区间）；axis=1 → 逐列（返回 x 区间）。
    full_frac：该行/列中 >= 该比例的像素 < dark 才算「全黑条」。
    """
    a = g if axis == 0 else g.T
    m = (a < dark).mean(axis=1) >= full_frac
    out = []
    for s, e in _runs(m, max(1, int(round(min_pt * k)))):
        out.append({"from": round(s / k, 2), "to": round(e / k, 2),
                    "len": round((e - s) / k, 2),
                    "mean_lum": round(float(a[s:e].mean()), 2)})
    return out


def rotation_scan(path: str, divide: Optional[float] = None) -> Dict[str, Any]:
    """0° / 90°(CCW) / -90°(CW) 三个方向的各向异性分数，取正立方向。

    返回 logical_size_pt 与 rotation_deg（把存储帧转多少度才正立）。
    """
    k = 3.0 if divide is None else float(divide)
    img = Image.open(path).convert("RGB")
    cand = {}
    for tag, deg in (("0", 0), ("90", 90), ("270", 270)):
        im = img if deg == 0 else img.rotate(deg, expand=True)
        g = np.asarray(im).astype(np.float64).mean(axis=2)
        cand[tag] = orientation_score(g)
    # 正立 = r 最大且 > 1 的方向；若全 <= 1（极端图）取 r 最大者
    best = max(cand, key=lambda t: cand[t]["r"])
    im = img if best == "0" else img.rotate(int(best), expand=True)
    W, H = im.size
    return {
        "rotation_deg": int(best),
        "scores": {t: cand[t]["r"] for t in ("0", "90", "270")},
        "upright_by_score": cand[best]["upright"],
        "logical_size_pt": (round(W / k, 1), round(H / k, 1)),
        "stored_size_pt": (round(img.size[0] / k, 1), round(img.size[1] / k, 1)),
    }


def logical_image(path: str, rotation_deg: int = 0):
    """按判定角度把截图转到逻辑画布（正立）。"""
    img = Image.open(path).convert("RGB")
    return img if rotation_deg == 0 else img.rotate(rotation_deg, expand=True)


# --------------------------------------------------------------------------
# 规范化 JSON（幂等的落盘格式）
# --------------------------------------------------------------------------
def rects_to_json(rects: List[Rect]) -> str:
    """逐字节稳定的序列化：键排序、紧凑分隔符、固定小数位。"""
    payload = [
        {"x": round(r.x, 2), "y": round(r.y, 2), "w": round(r.w, 2),
         "h": round(r.h, 2), "kind": r.kind, "confidence": round(r.confidence, 2)}
        for r in rects
    ]
    return json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"))


def dumps_canonical(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"))


def measure_posture(path: str, divide: float = 3.0,
                    gap_pt: float = 10.0, v_overlap: float = 0.5,
                    mode: str = "luma", thr: float = 40.0,
                    min_pt: float = 4.0,
                    hp_radius_px: int = 40,
                    hp_delta: float = 14.0,
                    tile_pt: float = 32.0,
                    bright_thr: float = 60.0,
                    rotation_hint: Optional[int] = None) -> Dict[str, Any]:
    """一步完成：判方向 → 转逻辑画布 → 切原子块 → 合并成行级块。

    合并时自动把「已检出的横向暗缝」作为屏障，保证不会跨栏合并。
    返回的块坐标全部在**逻辑画布**坐标系（左上原点，单位 pt）。

    rotation_hint 非 None 时**直接采用**，跳过内容推断。
    理由见 classify.analyze 的文档：Fig 与 simctl 两种采集通道的存储方向相反，
    内容推断在「大图+文字」画面上 r≈1 会失效（实测 4 张判错 3 张）。
    """
    rs = rotation_scan(path, divide)
    rot = int(rotation_hint) if rotation_hint is not None else rs["rotation_deg"]
    g = np.asarray(logical_image(path, rot)).astype(np.float64).mean(axis=2)
    W, H = g.shape[1] / divide, g.shape[0] / divide

    seams = dark_seams(g, divide, 1, dark=10.0, full_frac=0.98, min_pt=8.0)
    barriers = [(s["from"], s["to"]) for s in seams]

    raw = detect_blocks(path, thr=thr, min_pt=min_pt, divide=divide,
                        rotation_deg=rot, mode=mode,
                        hp_radius_px=hp_radius_px, hp_delta=hp_delta,
                        tile_pt=tile_pt, bright_thr=bright_thr)
    blocks = merge_into_rows(raw, gap_pt=gap_pt, v_overlap=v_overlap,
                             barriers=barriers)
    return {
        "rotation_deg": rot,
        "orientation_scores": rs["scores"],
        "stored_size_pt": rs["stored_size_pt"],
        "logical_size_pt": (round(W, 1), round(H, 1)),
        "seams_x": seams,
        "barriers": barriers,
        "atomic_blocks": len(raw),
        "blocks": blocks,
    }


if __name__ == "__main__":  # 手工自检入口
    import sys
    p = sys.argv[1]
    rs = detect_blocks(p)
    print(dumps_canonical({"file": p, "blocks": len(rs),
                           "rects": [asdict(r) for r in rs]}))
