#!/usr/bin/env bash
set -euo pipefail
cd $(dirname "$0")
trap 'pkill -P $$' EXIT # Kill child processes on exit

NATS="docker compose exec nats-cli nats"
BUCKET="inconsistency"
NATS_CLI_ERROR_LOG="/tmp/nats-err-$RANDOM.log"
SEQ_ERR_COUNT_TARGET=3
NO_RESTART=${NO_RESTART:-}

if [ -z "${NO_RESTART}" ]; then
    docker compose up -d --wait
    $NATS -s nats-0 kv rm -f $BUCKET || true
    $NATS -s nats-0 kv add --replicas=3 $BUCKET
fi

function Producer() {
    set +e
    # random garbage payload
    PAYLOAD="$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | base64 | tr -d '\n')"
    while :; do
        # use a random key "key.[0-999]"
        KEY="key.$(($RANDOM % 1000))"

        # add values for 3 seconds and remove values for 2 seconds
        if [ "$(($(date +%s) % 5))" -ge 2 ]; then 
            ACTION="add"
        else
            ACTION="rm" 
        fi

        case $ACTION in
        'add')
            # adding a value tries to update first - if that fails it creates the key instead
            $NATS -s nats-$(($RANDOM % 3)) --timeout=250ms kv update $BUCKET $KEY $PAYLOAD >/dev/null 2>>$NATS_CLI_ERROR_LOG || \
            $NATS -s nats-$(($RANDOM % 3)) --timeout=250ms kv create $BUCKET $KEY $PAYLOAD >/dev/null 2>>$NATS_CLI_ERROR_LOG
        ;;
        'rm')
            $NATS -s nats-$(($RANDOM % 3)) --timeout=250ms kv del -f $BUCKET $KEY >/dev/null 2>>$NATS_CLI_ERROR_LOG
        ;;
        esac

        # log action
        if [ $? -eq 0 ]; then
            echo -e "[$(date +"%T.%N")] [KV] $ACTION $KEY"
        else
            echo -e "[$(date +"%T.%N")] [KV] $ACTION $KEY - fail"
        fi
    done
}

Producer &
PPID0=$!

set +e
while :; do
    # give time for the producer to do its thing
    sleep 3

    # fetch current stream leader (can fail soon after restart)
    STREAM_LEADER="$($NATS -s nats-0 kv info $BUCKET | grep Leader | cut -d ':' -f 2 | xargs)"
    if [ -z "$STREAM_LEADER" ]; then continue; fi
    
    # kill the stream leader
    docker compose --progress quiet kill $STREAM_LEADER
    echo -e "[$(date +"%T.%N")] [PS] \e[91mkill $STREAM_LEADER\e[00m"
    
    # let it be dead for a bit
    sleep 2

    # restart the killes node
    docker compose --progress quiet start $STREAM_LEADER
    echo -e "[$(date +"%T.%N")] [PS] \e[92mstart $STREAM_LEADER\e[00m"
    
    # stop when we reach target squence error count
    # kill producer and break loop
    SEQ_ERR_COUNT="$(cat $NATS_CLI_ERROR_LOG | grep "wrong last sequence" | wc -l)"
    echo -e "[$(date +"%T.%N")][SEQ] \e[93mwrong last sequence count: $SEQ_ERR_COUNT\e[00m"
    if [ $SEQ_ERR_COUNT -ge $SEQ_ERR_COUNT_TARGET ]; then
        echo -e "[$(date +"%T.%N")][SEQ] \e[92mtarget error count observed\e[00m"
        kill $PPID0
        break
    fi
done

# cluster may still be unavailable
echo -e "[$(date +"%T.%N")] waiting for KV to be ready..."
while ! $NATS -s nats-0 kv ls $BUCKET >/dev/null 2>&1; do sleep 0.5; done;

# get number of keys in KV 
# if inconsistent we will get different values for the same request
RESULTS=$(echo "$(for i in $(seq 10); do $NATS -s nats-0 kv ls $BUCKET | wc -l; done )" | sort | uniq)
if [ "$(echo $RESULTS | tr ' ' '\n' | wc -l)" -gt 1 ]; then
    echo -e "[$(date +"%T.%N")] inconsistent results for '$NATS -s nats-0 kv ls $BUCKET | wc -l':"
    echo -e "[$(date +"%T.%N")] $(echo $RESULTS | xargs)"
else
    echo -e "[$(date +"%T.%N")] kv state remains consistent - trying again..."
    NO_RESTART=1 $0 $@
fi