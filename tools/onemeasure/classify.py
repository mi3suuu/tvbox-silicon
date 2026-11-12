#!/usr/bin/env python3
"""A2 形态判定 + A3 基准表产出（全部数值判据，不依赖视觉模型）。

判定链（顺序固定）
------------------
S1 存储帧 pt            = 像素 / 3
S2 逻辑画布 pt           = 按高频边缘各向异性 r 确定旋转角后的画布
     r>1 逻辑竖屏(正立存储) / r<1 逻辑横屏(截图被转 90° 存储)
S3 屏体                 逻辑画布 669×951 或 951×669 → 内屏(2007×2853px)
                        逻辑画布 466×678 或 678×466 → 外屏(1398×2034px)
S4 是否双栏             在逻辑画布上找「整条近全黑」横向带（折缝）。
                         检出 且 长度 40..80pt 且 区间落在 440..540pt → 双栏
                         未检出但存在浮层覆盖（缝区亮度显著抬升）→ 单栏判定不可用，
                         标 seam_status="covered-by-overlay"
S5 形态名               {屏体, 方向, 双栏} → 形态

半折（90°）与摊开（180°）屏幕尺寸完全相同（见作战手册 §四），静态截图无法区分，
本脚本不臆测，一律标 fold_unknown=true。
"""
from __future__ import annotations

import glob
import json
import os
import sys
from typing import Any, Dict, List

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure as M  # noqa: E402

DESKTOP_GLOB = "/Users/mi3s/Desktop/Screenshot Fig 2026-11-11 at *.png"
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# 已知事实（brief / 作战手册），仅用于交叉校验，不参与判定
KNOWN_INNER_PORTRAIT = (669.0, 951.0)
KNOWN_INNER_LANDSCAPE = (951.0, 669.0)
KNOWN_COVER_PORTRAIT = (466.0, 678.0)
KNOWN_COVER_LANDSCAPE = (678.0, 466.0)
KNOWN_SEAM = {"from": 467.667, "to": 523.0, "len": 55.333}   # 内屏横持双栏纯黑缝


def classic(a: float, b: float, tol: float = 2.0) -> bool:
    return abs(a - b) <= tol


def screen_body(size_pt) -> str:
    w, h = size_pt
    if classic(w, 669) and classic(h, 951):
        return "inner"
    if classic(w, 951) and classic(h, 669):
        return "inner"
    if classic(w, 466) and classic(h, 678):
        return "cover"
    if classic(w, 678) and classic(h, 466):
        return "cover"
    return "unknown"


def band_stats(g: np.ndarray, k: float, x0: float, x1: float) -> Dict[str, float]:
    """取 x∈[x0,x1) pt 的竖条统计。"""
    a, b = int(round(x0 * k)), int(round(x1 * k))
    a, b = max(0, a), min(g.shape[1], b)
    if b <= a:
        return {"mean": 0.0, "max": 0.0, "ink_frac": 0.0}
    s = g[:, a:b]
    return {"mean": round(float(s.mean()), 2),
            "max": round(float(s.max()), 1),
            "ink_frac": round(float((s > 40).mean()), 4)}


def analyze(path: str, rotation_hint: Optional[int] = None) -> Dict[str, Any]:
    """量测一张截图。

    rotation_hint
    ------------
    **采集通道声明的存储约定**，优先级高于内容推断（各向异性）。

    为什么必须有这个参数（2026-11-12 实测）：
      · Fig 的截图按**物理屏**存储：内容横持时仍存成竖帧，必须转 90°；
      · `xcrun simctl io screenshot` **随内容旋转**：横持时存成横帧，不能转。

    两种通道存储方向相反，而「存储宽高比」无法区分（真One 横持存成 2007×2853，
    我方横持存成 2853×2007）。内容推断（r=|Δy|/|Δx|）在详情页这类
    「大图+文字」画面里 r≈0.92~1.02 落在噪声区，实测 4 张判错 3 张。

    所以方向由采集方声明，不猜：
      · 0    —— 已正立，不旋转（simctl 采集，默认）
      · 90   —— 需逆时针转 90°（Fig 采集的横持帧）
      · None —— 退回内容推断（仅用于结构强、r 远离 1.0 的画面）
    """

    k = 3.0
    # adaptive：分瓦片自适应阈値（亮海报背景用局部对比度、深色区用绝对亮度）
    mp = M.measure_posture(path, divide=k, mode="adaptive",
                           hp_radius_px=45, hp_delta=14.0,
                           tile_pt=32.0, bright_thr=60.0,
                           rotation_hint=rotation_hint)

    size = mp["logical_size_pt"]
    rot = mp["rotation_deg"]
    seams_x = mp["seams_x"]
    # 亚像素严格口径（缝内亮度 <2）——用于与 brief 已知事实逐位对账
    g_log = np.asarray(M.logical_image(path, rot)).astype(np.float64).mean(axis=2)
    seams_x_strict = M.dark_seams(g_log, k, 1, dark=2.0, full_frac=0.98, min_pt=8.0)

    # S4 暗缝（判据部分，沿用 measure 的检测结果 + 右锚定复核）
    seam_status = "absent"
    seam = None
    seam_probe = None
    if screen_body(size) == "inner" and classic(size[0], 951):
        lo, hi = KNOWN_SEAM["from"], KNOWN_SEAM["to"]
        g = np.asarray(M.logical_image(path, rot)).astype(np.float64).mean(axis=2)
        probe = band_stats(g, k, lo + 2, hi - 2)            # 缝心
        side_l = band_stats(g, k, max(0, lo - 40), lo - 4)  # 左栏邻接
        side_r = band_stats(g, k, hi + 4, hi + 44)          # 右栏邻接
        # 右锚定：黑条末端落在 523.0±1.5pt
        anchored = [s for s in seams_x if abs(s["to"] - hi) <= 1.5 and s["len"] >= 12.0]
        if anchored:
            s = max(anchored, key=lambda v: v["len"])
            if s["len"] >= KNOWN_SEAM["len"] - 3.0:
                seam_status, seam = "detected", s
            else:
                # 缝条被浮层压住左半段，但右锚点与纯黑性成立 → 缝仍存在
                seam_status, seam = "detected-partial", s
        elif probe["mean"] <= 10.0 and probe["max"] <= 30.0:
            seam_status, seam = "detected-thin", {"from": lo, "to": hi,
                                                  "len": round(hi - lo, 3),
                                                  "mean_lum": probe["mean"]}
        elif probe["mean"] >= 8.0:
            seam_status = "covered-by-overlay"
        else:
            seam_status = "not-found"
        seam_probe = {"gap": probe, "left_of_gap": side_l, "right_of_gap": side_r,
                      "all_black_runs_x": seams_x}

    dual = seam_status in ("detected", "detected-partial", "detected-thin")

    # S5 形态
    body = screen_body(size)
    landscape = classic(size[0], 951) or classic(size[0], 678) or size[0] > size[1]
    if body == "inner":
        posture = "内屏横持" if size[0] > size[1] else "内屏竖持"
    elif body == "cover":
        posture = "外屏横持" if size[0] > size[1] else "外屏竖持"
    else:
        posture = "未知"

    blocks = mp["blocks"]
    kinds: Dict[str, int] = {}
    for b in blocks:
        kinds[b.kind] = kinds.get(b.kind, 0) + 1

    tag = os.path.basename(path).replace("Screenshot Fig 2026-11-11 at ", "").replace(".png", "")
    out: Dict[str, Any] = {
        "file": os.path.basename(path),
        "tag": tag,
        "stored_size_pt": list(mp["stored_size_pt"]),
        "logical_size_pt": list(size),
        "rotation_deg": rot,
        "orientation_scores": mp["orientation_scores"],
        "screen_body": body,
        "posture": posture,
        "dual_column": dual,
        "seam_status": seam_status,
        "seam_x": [seam["from"], seam["to"]] if seam else None,
        "seam_len_pt": seam["len"] if seam else None,
        "seam_x_strict": ([seams_x_strict[0]["from"], seams_x_strict[0]["to"]]
                          if seams_x_strict else None),
        "seam_len_strict_pt": seams_x_strict[0]["len"] if seams_x_strict else None,
        "seam_matches_known_fact": (
            bool(seams_x_strict)
            and abs(seams_x_strict[0]["from"] - KNOWN_SEAM["from"]) <= 0.05
            and abs(seams_x_strict[0]["to"] - KNOWN_SEAM["to"]) <= 0.05),
        "fold_unknown": body == "inner",   # 内屏半折与摊开尺寸相同，静态图不可分辨
        "atomic_blocks": mp["atomic_blocks"],
        "blocks_total": len(blocks),
        "kinds": kinds,
        "blocks": [{"x": b.x, "y": b.y, "w": b.w, "h": b.h,
                    "kind": b.kind, "confidence": b.confidence} for b in blocks],
    }
    if seam_status in ("covered-by-overlay", "not-found"):
        out["seam_probe"] = seam_probe
    return out


def posture_key(p: str) -> str:
    return {"内屏横持": "inner-landscape",
            "内屏竖持": "inner-portrait",
            "外屏横持": "cover-landscape",
            "外屏竖持": "cover-portrait"}.get(p, "unknown")


def write_json(path: str, obj: Any) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2))
        fh.write("\n")


def main() -> int:
    files = sorted(glob.glob(DESKTOP_GLOB))
    shots = [analyze(f) for f in files]

    shdir = os.path.join(OUT_DIR, "shots")
    os.makedirs(shdir, exist_ok=True)
    for s in shots:
        write_json(os.path.join(shdir, f"{s['tag']}.json"), s)

    # 汇总表
    rows = [{
        "tag": s["tag"], "file": s["file"],
        "stored_size_pt": s["stored_size_pt"],
        "logical_size_pt": s["logical_size_pt"],
        "rotation_deg": s["rotation_deg"],
        "r0": s["orientation_scores"]["0"],
        "posture": s["posture"],
        "dual_column": s["dual_column"],
        "seam_status": s["seam_status"],
        "seam_x": s["seam_x"],
        "seam_len_pt": s["seam_len_pt"],
        "blocks_total": s["blocks_total"],
        "kinds": s["kinds"],
    } for s in shots]

    # 基准表：每个可识别形态挑「主态」一帧
    # 主态判据（纯数值，不目测）：
    #   双栏形态（内屏横持）：先按缝完整度（seam_status 优先级），再按非 small 块数、最大块面积。
    #       缝完整 = 该形态的定义性证据，缺缝的帧不能当基准。
    #   单栏形态：按 (非 small 块数 desc, 最大块面积 desc)。
    # 结果与既有证据文档（Docs/duo/evidence-2026-11-11/*）一致，
    # 全部候选与得分写入 candidates 供人工复核。
    groups: Dict[str, List[Dict[str, Any]]] = {}
    for s in shots:
        groups.setdefault(s["posture"], []).append(s)

    SEAM_RANK = {"detected": 0, "detected-partial": 1, "detected-thin": 2,
                 "covered-by-overlay": 3, "not-found": 4, "absent": 5}

    def largest_frac(s: Dict[str, Any]) -> float:
        W, H = s["logical_size_pt"]
        a = max((b["w"] * b["h"] for b in s["blocks"]), default=0.0)
        return a / (W * H) if W * H else 0.0

    def rank_key(s: Dict[str, Any], dual: bool):
        nonsmall = s["blocks_total"] - s["kinds"].get("small", 0)
        maxarea = max((b["w"] * b["h"] for b in s["blocks"]), default=0.0)
        seam = SEAM_RANK.get(s["seam_status"], 9)
        # 双栏：缝完整度优先（该形态的定义性证据），再比大块数量/面积
        # 单栏：主内容块「占比」优先 —— 占比高说明主视频/海报块完整未被浮层切碎，
        #      即「主态」；再比大块数量与面积
        # 单栏：占比按 0.1 分档后再比大块数量 —— 避免把「0.700 vs 0.694」这种
        # 采样噪声当成主态判据（实测会把控件更完整的帧判掉）
        return ((seam, -nonsmall, -maxarea, s["tag"]) if dual
                else (-round(largest_frac(s), 1), -nonsmall, -maxarea, s["tag"]))

    written = []
    for posture, key in (("内屏横持", "inner-landscape"),
                         ("内屏竖持", "inner-portrait"),
                         ("外屏竖持", "cover-portrait")):
        if posture not in groups:
            continue
        g0 = groups[posture]
        dual = key == "inner-landscape"
        ranked = sorted(g0, key=lambda s: rank_key(s, dual))
        src = ranked[0]
        doc = {
            "posture": posture,
            "posture_key": key,
            "size_pt": src["logical_size_pt"],
            "stored_size_pt": src["stored_size_pt"],
            "rotation_deg": src["rotation_deg"],
            "dual_column": src["dual_column"],
            "seam_x": src["seam_x"],
            "fold_unknown": src["fold_unknown"],
            "source": f"Screenshot Fig 2026-11-11 at {src['tag']}.png",
            "source_tag": src["tag"],
            "px_per_pt": 3.0,
            "blocks_total": src["blocks_total"],
            "kinds": src["kinds"],
            "main_state_rule": ("双栏形态：seam_status 完整度 desc → 非small块数 desc → 最大块面积 desc"
                                if dual else
                                "单栏形态：最大块占画布比例（0.1 分档）desc → 非small块数 desc "
                                "→ 最大块面积 desc"),
            "largest_block_frac": round(largest_frac(src), 3),
            "measure_mode": "adaptive",
            "measure_quality": ("ok" if largest_frac(src) <= 0.85 else
                                "background-merged"),
            "candidates": [{"tag": s["tag"],
                            "blocks": s["blocks_total"],
                            "nonsmall": s["blocks_total"] - s["kinds"].get("small", 0),
                            "max_block_area_pt2": round(max(
                                (b["w"] * b["h"] for b in s["blocks"]), default=0.0), 1),
                            "largest_block_frac": round(largest_frac(s), 3),
                            "seam_status": s["seam_status"]} for s in ranked],
            "blocks": src["blocks"],
        }
        p = os.path.join(OUT_DIR, f"posture-{key}.json")
        write_json(p, doc)
        written.append({"posture": posture, "key": key, "path": os.path.basename(p),
                        "blocks": src["blocks_total"], "source": src["tag"],
                        "candidates": len(g0)})

    index: Dict[str, Any] = {
        "generated_by": "tools/onemeasure/classify.py",
        "desktop_glob": DESKTOP_GLOB,
        "px_per_pt": 3.0,
        "known_facts": {
            "inner_portrait_pt": list(KNOWN_INNER_PORTRAIT),
            "inner_landscape_pt": list(KNOWN_INNER_LANDSCAPE),
            "cover_portrait_pt": list(KNOWN_COVER_PORTRAIT),
            "cover_landscape_pt": list(KNOWN_COVER_LANDSCAPE),
            "inner_landscape_seam_pt": KNOWN_SEAM,
            "note": "内屏半折与摊开屏幕尺寸相同，静态截图无法区分 fold，故 fold_unknown=true",
        },
        "shots": rows,
        "postures_found": sorted(groups.keys()),
    }
    index["baseline_tables"] = written
    index["postures_missing"] = [
        {"posture": "外屏横持", "key": "cover-landscape",
         "reason": "19 张真机截图中无 678×466pt（2034×1398px）存储帧；外屏横持未采到"},
        {"posture": "半折竖持", "key": "inner-half-portrait",
         "reason": "半折与摊开的屏幕像素尺寸相同（951×669 / 669×951），"
                   "静态截图无 fold 信息，无法与内屏横持/竖持区分；需真机或模拟器切 hinge=90° 时读 reservedRegions 才能标注"},
        {"posture": "半折横持", "key": "inner-half-landscape",
         "reason": "同上：与内屏横持同尺寸，静态截图不可分辨"},
    ]
    write_json(os.path.join(OUT_DIR, "posture-index.json"), index)

    # 控制台摘要
    print(f"{'tag':<9} {'stored':<10} {'logical':<10} {'rot':>4} {'posture':<8} "
          f"{'dual':<5} {'seam':<20} {'blocks':>6}")
    for r in rows:
        print(f"{r['tag']:<9} {r['stored_size_pt'][0]:.0f}x{r['stored_size_pt'][1]:<6.0f} "
              f"{r['logical_size_pt'][0]:.0f}x{r['logical_size_pt'][1]:<6.0f} "
              f"{r['rotation_deg']:>4} {r['posture']:<8} {str(r['dual_column']):<5} "
              f"{r['seam_status']:<20} {r['blocks_total']:>6}")
    print()
    for w in written:
        print("baseline:", w)
    print("missing  :", len(index["postures_missing"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
