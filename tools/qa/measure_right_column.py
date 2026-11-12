#!/usr/bin/env python3
"""从截图里量右栏的段落结构（行级墨迹分析）。

为什么不用 AX：模拟器 headless 下读不到 SwiftUI Text 的 label，
只能靠像素。判据是「某一行有墨迹 → 那里有内容」，能给出段落的 y 起止。

用法: measure_right_column.py <screenshot.png> [split_x]
"""
import sys
from PIL import Image

def main():
    path = sys.argv[1]
    im = Image.open(path).convert('RGB')
    W, H = im.size
    # 截图像素 ÷ 逻辑画布 = 渲染缩放。三种已知组合：
    #   内屏横持 2853×2007px  ↔ 951×669 逻辑  → scale = 2853/951 = 3.000
    #   内屏竖持 2007×2853px  ↔ 669×951 逻辑  → scale = 2007/669  = 3.000
    #   外屏竖持 1398×2034px  ↔ 466×678 逻辑  → scale = 1398/466  = 3.000
    # 全部是 3.0（点=3倍像素），所以直接用 3 判断逻辑宽高。
    scale = 3.0
    logical_w = W / scale
    logical_h = H / scale
    # 右栏起点：内屏横持 x=523pt；按比例换算成像素
    split_pt = float(sys.argv[2]) if len(sys.argv) > 2 else 523.0
    if split_pt >= logical_w: split_pt = logical_w * 0.55
    x0 = int(split_pt * scale)
    x1 = W

    rows = []
    for y in range(H):
        lum = []
        for x in range(x0, x1, max(1, (x1 - x0) // 60)):
            p = im.getpixel((x, y))
            lum.append(sum(p) / 3)
        rows.append(sum(lum) / len(lum))

    # 背景亮度：取全列中位数
    srt = sorted(rows)
    bg = srt[len(srt) // 2]
    thr = bg + 12

    segs, start = [], None
    for y, v in enumerate(rows):
        if v > thr and start is None:
            start = y
        elif v <= thr and start is not None:
            if y - start >= int(3 * scale):   # 至少 3pt 高
                segs.append((start, y))
            start = None
    if start is not None:
        segs.append((start, len(rows)))

    print(f"画布 {W}x{H}px → 逻辑 {logical_w:.0f}x{logical_h:.0f}pt  右栏 x>={split_pt}pt  背景 lum={bg:.1f}")
    print(f"{'段':>2} {'y起(pt)':>9} {'y止(pt)':>9} {'高(pt)':>8}")
    print("-" * 34)
    for i, (a, b) in enumerate(segs, 1):
        print(f"{i:>2} {a/scale:>9.1f} {b/scale:>9.1f} {(b-a)/scale:>8.1f}")
    print(f"\n共 {len(segs)} 段（真 One 基准 8 段）")

if __name__ == '__main__':
    main()
