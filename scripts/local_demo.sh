#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
demo_dir="$repo_dir/.local_demo"
docker_cmd=(docker)

use_docker()
{
    if ! docker info >/dev/null 2>&1; then
        docker_cmd=(sudo docker)
        "${docker_cmd[@]}" info >/dev/null
    fi
}

compose()
{
    "${docker_cmd[@]}" compose -p tiktok_local_demo -f "$demo_dir/compose.yml" "$@"
}

stop_processes()
{
    local pid_file process_id
    for pid_file in "$demo_dir"/*.pid; do
        [ -f "$pid_file" ] || continue
        read -r process_id < "$pid_file"
        if [[ "$process_id" =~ ^[0-9]+$ ]] && [ "$(readlink "/proc/$process_id/cwd" 2>/dev/null || true)" = "$demo_dir" ]; then
            kill "$process_id" 2>/dev/null || true
        fi
        rm -f -- "$pid_file"
    done
}

start_process()
{
    local process_name="$1"
    shift
    (cd "$demo_dir" && exec nohup "$@") >"$demo_dir/$process_name.log" 2>&1 &
    echo "$!" > "$demo_dir/$process_name.pid"
}

wait_http()
{
    local target_url="$1"
    local attempt
    for attempt in {1..90}; do
        if curl -fsS --max-time 2 "$target_url" >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    echo "服务未就绪：$target_url；请查看 $demo_dir/*.log" >&2
    return 1
}

wait_rpc()
{
    local target_port="$1"
    local attempt
    for attempt in {1..90}; do
        if (echo > "/dev/tcp/127.0.0.1/$target_port") 2>/dev/null; then
            return
        fi
        sleep 1
    done
    echo "RPC 未就绪：$target_port；请查看 $demo_dir/*.log" >&2
    return 1
}

case "${1:-help}" in
    stop)
        stop_processes
        if [ -f "$demo_dir/compose.yml" ]; then
            use_docker
            compose stop
        fi
        echo "演示进程和容器已停止，测试数据保留。"
        exit
        ;;
    start) ;;
    *)
        echo "用法：bash scripts/local_demo.sh start|stop"
        exit
        ;;
esac

for dependency in curl git python3 ffmpeg docker; do
    command -v "$dependency" >/dev/null || { echo "缺少工具：$dependency" >&2; exit 1; }
done
use_docker
"${docker_cmd[@]}" compose version >/dev/null
mkdir -p "$demo_dir"/{tools,bin,config,public,minio_data}
stop_processes

# 固定旧工具链，避免改动系统 Go；仅面向 Linux x86_64 本地演示。
if [ "$(uname -m)" != x86_64 ]; then
    echo "本脚本仅验证过 Linux x86_64。" >&2
    exit 1
fi
go_bin="${DEMO_GO:-$demo_dir/tools/go/bin/go}"
if [ ! -x "$go_bin" ]; then
    curl -fL --retry 2 https://go.dev/dl/go1.19.13.linux-amd64.tar.gz -o "$demo_dir/tools/go.tar.gz"
    tar -xzf "$demo_dir/tools/go.tar.gz" -C "$demo_dir/tools"
fi
"$go_bin" version | grep -q 'go1.19.13 ' || { echo "需要 Go 1.19.13" >&2; exit 1; }

if [ ! -x "$demo_dir/bin/minio" ]; then
    if [ ! -d "$demo_dir/tools/minio_source/.git" ]; then
        git clone --depth 1 --branch RELEASE.2023-02-10T18-48-39Z https://github.com/minio/minio.git "$demo_dir/tools/minio_source"
    fi
    [ "$(git -C "$demo_dir/tools/minio_source" rev-parse HEAD)" = d0f4cc89a5d0ca45e7ba00fbb7733c2fead3f44e ]
    (cd "$demo_dir/tools/minio_source" && "$go_bin" build -o "$demo_dir/bin/minio" .)
fi
if [ ! -x "$demo_dir/bin/mc" ]; then
    GOBIN="$demo_dir/bin" "$go_bin" install github.com/minio/mc@v0.0.0-20230203133213-3aebb3362b18
fi
for service_name in user video api; do
    (cd "$repo_dir" && "$go_bin" build -o "$demo_dir/bin/$service_name" "./cmd/$service_name")
done

python3 - <<'PY'
import socket

for port in (8085, 8086, 8089, 18090, 19000, 19001):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
        except OSError as error:
            raise SystemExit(f"端口 {port} 已被占用，请先检查旧实例：{error}")
PY

# 在独立目录生成配置。读写都指向演示数据库，避免缺少主从复制时读不到刚写入的数据。
python3 - "$repo_dir" "$demo_dir" <<'PY'
import pathlib
import sys

repo_dir, demo_dir = map(pathlib.Path, sys.argv[1:])
for source_path in (repo_dir / "config").glob("*.yml"):
    content = source_path.read_text()
    content = content.replace("0.0.0.0", "127.0.0.1")
    if source_path.name == "db.yml":
        for port in ("3309", "3310", "3308"):
            content = content.replace("port: " + port, "port: 13309")
    if source_path.name == "minio.yml":
        content = content.replace(":9000", ":19000")
        content = content.replace('AccessKeyId: minio', 'AccessKeyId: tiktokMinio')
        content = content.replace('SecretAccessKey: minio', 'SecretAccessKey: tiktokMinio')
    content = content.replace("port: 2379", "port: 12379")
    (demo_dir / "config" / source_path.name).write_text(content)
PY

cat > "$demo_dir/compose.yml" <<'YAML'
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: demo_root
      MYSQL_DATABASE: db_tiktok
      MYSQL_USER: tiktokDB
      MYSQL_PASSWORD: tiktokDB
    ports:
      - "127.0.0.1:13309:3306"
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysql", "-h127.0.0.1", "-utiktokDB", "-ptiktokDB", "db_tiktok", "-e", "SELECT 1"]
      interval: 3s
      timeout: 5s
      retries: 60
  etcd:
    image: quay.io/coreos/etcd:v3.5.6
    command:
      - /usr/local/bin/etcd
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://127.0.0.1:12379
    ports:
      - "127.0.0.1:12379:2379"
    healthcheck:
      test: ["CMD", "/usr/local/bin/etcdctl", "endpoint", "health"]
      interval: 3s
      timeout: 5s
      retries: 30
volumes:
  mysql_data:
YAML
compose up -d --wait --wait-timeout 240

start_process minio env MINIO_ROOT_USER=tiktokMinio MINIO_ROOT_PASSWORD=tiktokMinio \
    "$demo_dir/bin/minio" server "$demo_dir/minio_data" --address 127.0.0.1:19000 --console-address 127.0.0.1:19001
wait_http http://127.0.0.1:19000/minio/health/live
mc_cmd=("$demo_dir/bin/mc" --config-dir "$demo_dir/mc_config")
"${mc_cmd[@]}" alias set demo http://127.0.0.1:19000 tiktokMinio tiktokMinio >/dev/null
for bucket_name in tiktok-videos tiktok-video-covers tiktok-user-avatars tiktok-user-backgrounds; do
    "${mc_cmd[@]}" mb --ignore-existing "demo/$bucket_name"
done
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=360x640:rate=25' \
    -t 3 -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$demo_dir/sample.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$demo_dir/sample.mp4" -frames:v 1 "$demo_dir/default.png"
ffmpeg -hide_banner -loglevel error -y -i "$demo_dir/sample.mp4" -frames:v 1 "$demo_dir/default_background.jpg"
for avatar_index in {0..9}; do
    "${mc_cmd[@]}" cp "$demo_dir/default.png" "demo/tiktok-user-avatars/default$avatar_index.png" >/dev/null
done
"${mc_cmd[@]}" cp "$demo_dir/default_background.jpg" demo/tiktok-user-backgrounds/default_background.jpg >/dev/null

# 顺序启动，防止两个进程同时迁移同一份空数据库。
start_process user "$demo_dir/bin/user"
wait_rpc 8085
start_process video "$demo_dir/bin/video"
wait_rpc 8086
start_process api "$demo_dir/bin/api"
wait_http http://127.0.0.1:8089/douyin/feed
start_process viewer python3 -m http.server 18090 --bind 127.0.0.1 --directory "$demo_dir/public"
wait_http http://127.0.0.1:18090/
echo "基础视频服务已启动。下一步运行：python3 scripts/demo_smoke.py"
