import re, glob, os

# key -> (zh-Hans, zh-Hant, ja)
T = [
 ("Speed & Grouping", "测速与分组", "測速與分組", "速度とグループ"),
 ("Every Source", "全部源", "全部源", "すべてのソース"),
 ("One Group", "单个分组", "單個分組", "単一グループ"),
 ("Measure", "测速范围", "測速範圍", "計測範囲"),
 ("Group", "分组", "分組", "グループ"),
 ("Skip readings newer than", "跳过此时间内的读数", "跳過此時間內的讀數", "この時間内の測定値をスキップ"),
 ("Never skip", "从不跳过", "從不跳過", "スキップしない"),
 ("5 minutes", "5 分钟", "5 分鐘", "5 分"),
 ("10 minutes", "10 分钟", "10 分鐘", "10 分"),
 ("30 minutes", "30 分钟", "30 分鐘", "30 分"),
 ("1 hour", "1 小时", "1 小時", "1 時間"),
 ("A source measured inside this window is left alone, so a second sweep costs only what changed. Set it to Never skip to re-measure everything.",
  "在此时间窗内测过的源会被跳过，所以再按一次只需补测变化的部分。设为「从不跳过」则全量重测。",
  "在此時間窗內測過的源會被跳過，所以再按一次只需補測變化的部分。設為「從不跳過」則全量重測。",
  "この時間内に測定済みのソースはスキップされるため、2 回目の計測は変化分だけで済みます。「スキップしない」にすると全件を再計測します。"),
 ("Scope", "范围", "範圍", "範囲"),
 ("Sweep", "批量测速", "批次測速", "一括計測"),
 ("%lld of %lld measured", "已测 %lld / %lld", "已測 %lld / %lld", "%lld / %lld を計測済み"),
 ("%lld skipped: measured recently.", "跳过 %lld 个：刚刚测过。", "跳過 %lld 個：剛剛測過。", "%lld 件をスキップ：最近測定済み。"),
 ("Measure This Group", "测这个分组", "測這個分組", "このグループを計測"),
 ("Measure Every Source", "测全部源", "測全部源", "すべてのソースを計測"),
 ("%lld sources will be measured.", "将测 %lld 个源。", "將測 %lld 個源。", "%lld 件のソースを計測します。"),
 ("%lld to measure, %lld skipped as recent.", "待测 %lld 个，跳过 %lld 个（读数较新）。", "待測 %lld 個，跳過 %lld 個（讀數較新）。", "%lld 件を計測、%lld 件は新規測定のためスキップ。"),
 ("Nothing to measure here.", "这里没有可测的源。", "這裡沒有可測的源。", "計測できるソースがありません。"),
 ("Readings", "读数", "讀數", "測定値"),
 ("Sources", "源数", "源數", "ソース数"),
 ("Answered", "可达", "可達", "到達可"),
 ("Silent", "不通", "不通", "到達不可"),
 ("Not measured", "未测", "未測", "未測定"),
 ("Newest reading", "最新读数", "最新讀數", "最新の測定値"),
 ("Grouping", "分组", "分組", "グループ化"),
 ("New group from everything that answered", "把可达的建成新分组", "把可達的建成新分組", "到達可のものを新しいグループに"),
 ("New group from everything silent", "把不通的建成新分组", "把不通的建成新分組", "到達不可のものを新しいグループに"),
 ("Answered into %@", "可达 → %@", "可達 → %@", "到達可 → %@"),
 ("Silent into %@", "不通 → %@", "不通 → %@", "到達不可 → %@"),
 ("Move a batch into an existing group", "把一批移入已有分组", "把一批移入已有分組", "まとめて既存のグループへ移動"),
 ("New group", "新建分组", "新建分組", "新規グループ"),
 ("%lld filed into %@.", "%lld 个已归入 %@。", "%lld 個已歸入 %@。", "%lld 件を %@ に移動しました。"),
 ("%lld moved into %@.", "%lld 个已移入 %@。", "%lld 個已移入 %@。", "%lld 件を %@ に移動しました。"),
 ("Created %@.", "已创建 %@。", "已建立 %@。", "%@ を作成しました。"),
 ("A source with no reading is left where it is. Filing an unmeasured source is a guess, and a working source hidden in the wrong group is worse than one that is slow.",
  "没有读数的源原地不动。把未测的源归组只是猜测，而把一个还能用的源藏进错误分组，比它慢更糟。",
  "沒有讀數的源原地不動。把未測的源歸組只是猜測，而把一個還能用的源藏進錯誤分組，比它慢更糟。",
  "測定値のないソースはそのままにします。未測定のソースを分類するのは推測であり、使えるソースを誤ったグループに隠すほうが、遅いより悪いからです。"),
 ("Routing", "路由", "路由", "ルーティング"),
 ("Answered to Direct, Silent to Proxy", "可达走直连，不通走代理", "可達走直連，不通走代理", "到達可は直接接続、到達不可はプロキシ"),
 ("%lld to Direct, %lld to Proxy, %lld left unmeasured.", "%lld 个设为直连，%lld 个设为代理，%lld 个因未测保持原样。",
  "%lld 個設為直連，%lld 個設為代理，%lld 個因未測保持原樣。",
  "%lld 件を直接接続、%lld 件をプロキシに設定。%lld 件は未測定のため変更なし。"),
 ("A route changes the address a source API is fetched from. Media comes from whatever CDN the source hands back and is not rewritten, so a source whose API answers but whose segments are blocked still needs hiding.",
  "路由只改源 API 的请求地址。媒体由源返回的 CDN 直接提供、不会被改写，所以 API 通但分片被墙的源仍然需要隐藏。",
  "路由只改源 API 的請求位址。媒體由源回傳的 CDN 直接提供、不會被改寫，所以 API 通但分片被封的源仍然需要隱藏。",
  "ルーティングが変えるのはソース API の取得先だけです。メディアはソースが返す CDN から直接取得され書き換えないため、API は通るがセグメントが遮断されるソースは非表示にする必要があります。"),
 ("Forget Every Reading", "清除全部读数", "清除全部讀數", "すべての測定値を消去"),
 ("Unreachable", "不通", "不通", "到達不可"),
 ("Group %lld", "分组 %lld", "分組 %lld", "グループ %lld"),
]

INDEX = {"zh-Hans": 1, "zh-Hant": 2, "ja": 3}

def esc(s):
    return s.replace('"', '\\"')

for lang, idx in INDEX.items():
    path = "Sources/TVCore/Resources/%s.lproj/Localizable.strings" % lang
    if not os.path.exists(path):
        continue
    text = open(path, encoding="utf-8").read()
    block = []
    for row in T:
        key = row[0]
        if ('"' + key + '"') in text:
            continue
        block.append('"%s" = "%s";' % (esc(key), esc(row[idx])))
    if block:
        text = text.rstrip() + "\n\n/* Speed & Grouping (SourceSpeedLab) */\n" + "\n".join(block) + "\n"
        open(path, "w", encoding="utf-8").write(text)
    print(lang, "added", len(block))
