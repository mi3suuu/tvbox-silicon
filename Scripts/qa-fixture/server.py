import http.server, socketserver, json, os, re
PORT=8899
# 模拟器里的 127.0.0.1 是模拟器自己，不是 Mac；而 Mac 的局域网地址随网络变化
# （实测 192.168.64.1 只在那台 VM 的网桥上成立）。所以让地址可覆盖：
#   QA_HOST=192.168.124.6 python3 Scripts/qa-fixture/server.py
# 不传时保持原来的 192.168.64.1，脚本的既有用法不变。
BASE=f"http://{os.environ.get('QA_HOST', '192.168.64.1')}:{PORT}"
SUB={"sites":[{"key":"qa","name":"QA Fixture","type":1,"api":f"{BASE}/api","searchable":1,"quickSearch":1},
                # 24 集 × 2 线路：选集抽屉要能看出分页、筛选与高度档位是否正常，
                # 单集片源（上面的 `qa`）根本撑不开列表。
                {"key":"qa2","name":"QA Many","type":1,"api":f"{BASE}/api2","searchable":1,"quickSearch":1}],
     "lives":[{"name":"QA Live","type":0,"url":f"{BASE}/lives.json","playerType":1}]}
LIVES={"lives":[{"name":"QA Channel","group":"QA","urls":[{"name":"HD","url":f"{BASE}/clip.mp4"}]}]}
HOME={"class":[{"type_id":"movie","type_name":"Movies"}],
      # 站点推荐（相关/热门），让详情页的「猜你喜欢」竖排列表有内容、填满视频下方空白。
      "list":[{"vod_id":str(i),"vod_name":f"QA 相关影片 {i}","vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_remarks":"更新至 12 集"}
              for i in range(2, 10)]}
LIST={"page":1,"pagecount":1,"list":[{"vod_id":"1","vod_name":"QA Fixture Movie","vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_remarks":"QA"}]}
DETAIL={"list":[{
  "vod_id":"1","vod_name":"QA Fixture Movie",
  "vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_content":"Fixture.",
  # 单集竖屏(9:16)：activeEpisodes.count==1 触发 VideoDetailView 自动播放，
  # 直接验证 aspectRatio 修复后「竖屏片源默认铺满、无需点填充」。
  # 三条线路：验证「多线路各自测延迟 + 切换」。
  # 三条都用同一个文件，延迟差异来自线路名与串行/并发顺序，不伪造毫秒数。
  "vod_play_from":"lineA$$$lineB$$$lineC",
  "vod_play_url":f"第1集${BASE}/portrait.mp4$$$第1集${BASE}/portrait.mp4$$$第1集${BASE}/clip.mp4",
}]}

DETAIL_MANY={"list":[{
  "vod_id":"1","vod_name":"QA Many Episodes",
  "vod_pic":f"{BASE}/poster.jpg","vod_year":"2024","vod_content":"Fixture: 24 集，用于选集抽屉回归。",
  "vod_play_from":"lineA$$$lineB",
  # TVBox 规则：源与源之间用 $$$，同一个源里的集用 # 分隔。
  "vod_play_url":"#".join(f"第{n}集${BASE}/clip.mp4" for n in range(1,25)) + "$$$"
                 + "#".join(f"第{n}集${BASE}/clip.mp4" for n in range(1,25)),
}]}

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self,fmt,*a): print("REQ "+self.path, flush=True)
    def _j(self,o):
        b=json.dumps(o).encode(); self.send_response(200)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _file(self, n):
        d=open(n,"rb").read(); total=len(d)
        mime={".mp4":"video/mp4",".jpg":"image/jpeg"}.get(os.path.splitext(n)[1],"application/octet-stream")
        rng=self.headers.get("Range")
        if rng:
            m=re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                s=int(m.group(1) or 0)
                e=int(m.group(2)) if m.group(2) else total-1
                e=min(e,total-1)
                chunk=d[s:e+1]
                self.send_response(206)
                self.send_header("Content-Type",mime)
                self.send_header("Content-Range",f"bytes {s}-{e}/{total}")
                self.send_header("Content-Length",str(len(chunk)))
                self.send_header("Accept-Ranges","bytes")
                self.end_headers(); self.wfile.write(chunk); return
        self.send_response(200); self.send_header("Content-Type",mime)
        self.send_header("Content-Length",str(total)); self.send_header("Accept-Ranges","bytes")
        self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        p=self.path.split("?")[0]
        if p=="/sub.json": return self._j(SUB)
        if p=="/lives.json": return self._j(LIVES)
        if p=="/qa.js":
            body=b"var rule={};"
            self.send_response(200); self.send_header("Content-Type","application/javascript")
            self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
        if p.rstrip("/")=="/api2":
            q=self.path.partition("?")[2]
            if "ac=detail" in q: return self._j(DETAIL_MANY)
            if "ac=list" in q or "t=" in q: return self._j(LIST)
            if "play=" in q:
                return self._j({"parse":0,"playUrl":"","url":f"{BASE}/clip.mp4"})
            return self._j(HOME)
        if p.rstrip("/")=="/api":
            q=self.path.partition("?")[2]
            if "ac=detail" in q: return self._j(DETAIL)
            if "ac=list" in q or "t=" in q: return self._j(LIST)
            if "play=" in q:
                return self._j({"parse":0,"playUrl":"","url":f"{BASE}/clip.mp4",
                                "subs":[{"name":"QA 中文字幕","url":f"{BASE}/sub.srt","lang":"zh","format":"srt"}]})
            return self._j(HOME)
        n=p.lstrip("/")
        if n and os.path.exists(n): return self._file(n)
        self.send_error(404)

socketserver.TCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("0.0.0.0",PORT),H).serve_forever()
