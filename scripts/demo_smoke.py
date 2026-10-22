"""通过真实 HTTP 接口验证注册、登录、发布、Feed、视频和封面，生成本地播放页。"""

import html
import json
import pathlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request


repo_dir = pathlib.Path(__file__).resolve().parent.parent
demo_dir = repo_dir / ".local_demo"
api_url = "http://127.0.0.1:8089"


def request_json(route, fields=None, method="GET"):
    query = "?" + urllib.parse.urlencode(fields) if fields else ""
    request = urllib.request.Request(api_url + route + query, method=method)
    with urllib.request.urlopen(request, timeout=20) as response:
        result = json.load(response)
    if result.get("status_code") != 0:
        raise RuntimeError(str(result))
    return result


def get_media(media_url):
    with urllib.request.urlopen(media_url, timeout=10) as response:
        return response.status, response.headers.get("Content-Type"), response.read()


def main():
    sample_path = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else demo_dir / "sample.mp4"
    if not sample_path.is_file():
        raise RuntimeError("先运行 bash scripts/local_demo.sh start，或传入已有的小型 MP4 文件路径")
    credentials = {"username": "demo_" + str(time.time_ns()), "password": "demo_pass_123"}
    registered = request_json("/douyin/user/register/", credentials, "POST")
    logged_in = request_json("/douyin/user/login/", credentials, "POST")
    if logged_in["user_id"] != registered["user_id"]:
        raise RuntimeError("登录和注册的用户 ID 不一致")
    print("PASS 注册、登录；user_id =", registered["user_id"])
    token = logged_in["token"]
    title = "local_demo_" + str(time.time_ns())[-10:]
    published = subprocess.check_output(
        ["curl", "-fsS", "--max-time", "60", "-F", "token=" + token, "-F", "title=" + title,
         "-F", "data=@" + str(sample_path), api_url + "/douyin/publish/action/"], text=True)
    published = json.loads(published)
    if published.get("status_code") != 0:
        raise RuntimeError(str(published))
    print("PASS 发布请求：", published.get("status_msg"))

    # 返回成功只表示已插入记录。必须等视频和封面都能真实读取才算通过。
    last_error = None
    for attempt in range(60):
        try:
            feed = request_json("/douyin/feed")
            video = next(item for item in feed["video_list"] if item["title"] == title)
            video_status, video_type, video_data = get_media(video["play_url"])
            cover_status, cover_type, cover_data = get_media(video["cover_url"])
            if video_data != sample_path.read_bytes():
                raise RuntimeError("下载的视频与上传的视频字节不同")
            if not cover_data.startswith((b"\xff\xd8\xff", b"\x89PNG")):
                raise RuntimeError("封面不是有效的 JPEG/PNG 文件")
            for field in ("avatar", "background_image"):
                get_media(video["author"][field])
            break
        except (OSError, KeyError, StopIteration, RuntimeError) as error:
            last_error = error
            time.sleep(1)
    else:
        raise RuntimeError("60 次轮询仍无法读取媒体，请查看 .local_demo/video.log：" + str(last_error))

    listing = request_json("/douyin/publish/list/", {"user_id": registered["user_id"], "token": token})
    if not any(item["id"] == video["id"] for item in listing["video_list"]):
        raise RuntimeError("作品列表没有刚发布的视频")
    print("PASS 游客 Feed、个人作品列表；video_id =", video["id"])
    print("PASS 视频 HTTP", video_status, video_type, len(video_data), "字节；与上传文件完全一致")
    print("PASS 封面 HTTP", cover_status, cover_type, len(cover_data), "字节；头像和背景可读取")
    range_request = urllib.request.Request(video["play_url"], headers={"Range": "bytes=0-31"})
    with urllib.request.urlopen(range_request, timeout=10) as response:
        if response.status != 206 or response.read() != video_data[:32]:
            raise RuntimeError("视频 Range 请求未返回预期的 206 和前 32 字节")
    print("PASS 视频 Range 请求：206，32 字节")

    # URL 保留完整签名；不代理接口，也不更改后端返回的 host。
    safe_play_url = html.escape(video["play_url"], quote=True)
    safe_cover_url = html.escape(video["cover_url"], quote=True)
    viewer = f'''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>极简抖音 · 本地视频验证</title>
<style>body {{ max-width:760px; margin:32px auto; padding:0 20px; font-family:system-ui; background:#111827; color:#f9fafb; }} video {{ height:65vh; max-width:100%; background:black; }} a {{ color:#67e8f9; }}</style>
<h1>你发布的视频已经到这里了</h1>
<p>通过当前项目的注册、发布和 Feed 接口获得；这是本地验收页，原仓库没有网页前端。</p>
<video controls playsinline preload="metadata" poster="{safe_cover_url}" src="{safe_play_url}"></video>
<p>标题：{html.escape(title)} · 视频 ID：{video["id"]}</p>
<p><a href="{safe_play_url}">直接打开视频</a> · <a href="{safe_cover_url}">打开封面</a></p>
<p>点击播放查看三秒测试画面。链接约一小时后过期；重新运行验收命令会发布新视频并刷新本页。</p>
</html>'''
    (demo_dir / "public" / "watch.html").write_text(viewer, encoding="utf-8")
    report = {"user_id": registered["user_id"], "video_id": video["id"], "title": title,
              "video_bytes": len(video_data), "cover_bytes": len(cover_data), "range_status": 206}
    (demo_dir / "last_result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print("打开浏览器：http://127.0.0.1:18090/watch.html")


if __name__ == "__main__":
    main()
