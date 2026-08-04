#!/bin/sh
# Synology Task Scheduler boot-up task (run as root).
#
# DSM fires boot-up tasks before dockerd is listening on /var/run/docker.sock,
# so this waits for the daemon before touching the stack. It also creates
# /dev/net/tun, which DSM does not reliably provide after a reboot and which
# gluetun needs to start at all.

# Resolved from this script's own location, so the stack can live anywhere.
STACK_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOG="$STACK_DIR/boot.log"

exec >> "$LOG" 2>&1
echo "=== boot script: $(date) ==="

# 1. TUN device for gluetun. The tun module is often already loaded and may
#    create the node itself, so both steps are allowed to fail quietly.
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  insmod /lib/modules/tun.ko 2>/dev/null
  mknod /dev/net/tun c 10 200 2>/dev/null
  chmod 600 /dev/net/tun
fi
echo "tun: $(ls -l /dev/net/tun 2>&1)"

# 2. Wait for the Docker daemon, up to 5 minutes.
i=0
until docker info >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "docker daemon unreachable after 5 minutes, aborting"
    exit 1
  fi
  sleep 5
done
echo "docker daemon ready after $((i * 5))s"

# 3. Start the stack.
cd "$STACK_DIR" || exit 1
docker-compose up -d

# 4. qbittorrent shares gluetun's network namespace and waits on its
#    healthcheck, so retry it in case gluetun was still connecting.
i=0
while [ "$i" -lt 6 ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' qbittorrent 2>/dev/null)" = "true" ]; then
    echo "qbittorrent up"
    break
  fi
  i=$((i + 1))
  echo "qbittorrent not up, retry $i"
  sleep 15
  docker-compose up -d qbittorrent
done

echo "=== done: $(date) ==="
docker-compose ps
