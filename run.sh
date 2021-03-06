#!/bin/sh

set -ex

PROC="$$"
LOCAL_VOLUME_PATH=${LOCAL_VOLUME_PATH:-/data/local}
REMOTE_VOLUME_PATH=${REMOTE_VOLUME_PATH:-/data/remote}
SNAPSHOT_INTERVAL=${SNAPSHOT_INTERVAL:-120}

DISABLE_SYNC_FLAG="$LOCAL_VOLUME_PATH/nosync"

INITIAL_SYNC_DELAY=5

force_sync() {
  echo "Replication now signal"
  rm -f "$DISABLE_SYNC_FLAG"
  killall -SIGTERM sleep || echo "No replication task available"
}

trap 'exit 1' SIGTERM
trap 'kill ${!}; force_sync' SIGUSR1

abort(){
  echo "$@" "aborting $PROC" >&2
  kill -SIGTERM "$PROC"
  wait "$PROC"
}

[ ! -d "${REMOTE_VOLUME_PATH}" ] && abort "Missing REMOTE_VOLUME_PATH"
[ ! -d "${LOCAL_VOLUME_PATH}"  ] && abort "Missing LOCAL_VOLUME_PATH"


echo "Initial sync from $REMOTE_VOLUME_PATH"

crash="$LOCAL_VOLUME_PATH-crash-`date +"%Y-%m-%d-%H-%M-%S"`"


if [ ! -f "$DISABLE_SYNC_FLAG" ] ; then
  cp -al "$LOCAL_VOLUME_PATH" "$crash"
  rsync -av --delete "$REMOTE_VOLUME_PATH"/ "$LOCAL_VOLUME_PATH"/
else
  echo "Skipping initial sync"
  INITIAL_SYNC_DELAY=infinity
fi



background_sync(){
  sleep $INITIAL_SYNC_DELAY || true # wait for prometheus to be ready (todo, better)

  while true; do
  echo "Now running snapshot"
  trace=$(curl -s -XPOST http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot)
  guid=$(echo -e "$trace"| jq -r '.data.name')

  echo "Got replication guid $guid"
  snapshot_dir="$LOCAL_VOLUME_PATH/snapshots/$guid"
  ( [ -z "$guid" ] || [ ! -d "$snapshot_dir" ] ) && echo -e "$trace" && abort "Invalid snapshot"

  rm -rf "$REMOTE_VOLUME_PATH.next"
  cp -lr "$REMOTE_VOLUME_PATH" "$REMOTE_VOLUME_PATH.next"
  rsync -av --delete $snapshot_dir/ "$REMOTE_VOLUME_PATH.next/"
  mv "$REMOTE_VOLUME_PATH" "$REMOTE_VOLUME_PATH.old"
  mv "$REMOTE_VOLUME_PATH.next" "$REMOTE_VOLUME_PATH"
  rm -rf "$REMOTE_VOLUME_PATH.old"

  rm -rf "$snapshot_dir"
  echo "Replication done, now sleeping ${SNAPSHOT_INTERVAL}"
  sleep $SNAPSHOT_INTERVAL || true
  done
}

background_sync &

/bin/prometheus "$@" &


# wait forever
while true
do
  tail -f /dev/null & wait ${!} || true
done
