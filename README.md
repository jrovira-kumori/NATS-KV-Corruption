# NATS KV Corruption

This repository contains a minimal reproducible example of a NATS Jetstream KeyValue corruption error. 

JetStream sometimes does not automatically recover correctly from a forced termination. The original error was found after an OOM kill. Restarting the corrupted instance does not fix the issue. Only removing the persistent volume and restarting the affected instance fixed the issue.

## Dependencies

[`docker`](https://docs.docker.com/engine/install/) and [`bash`](https://www.gnu.org/software/bash/).

## Reproduction steps

1. Execute the bash script `run.sh`[^1]

[^1]: The script may occasionally get stuck in a failed state. Logs with `nats: error: nats: bucket not found` and `[KV] <...> - fail` are printed indefinitely. Stop the execution in this case and try again.

> _**Note:** The `run.sh` script has a non-deterministic runtime. The average measured runtime of 5 executions was ~1m30s._

## Repro explanation

First, `docker compose up` deploys a JetStream cluster $N=3$ and creates a KV bucket $R=3$.

This reproduction consist of two loops. The *Producer* loop and the *Killer* loop. The *Producer* loop removes (`nats kv del`) and writes (`nats kv update` or `nats kv create`) to random keys. The *Killer* loop kills the current leader of the stream with `SIGKILL` and restarts it after a short delay.

The *Producer* loop eventually generates `wrong last sequence` errors when executing `nats kv update` calls. After observing `SEQ_ERR_COUNT_TARGET` errors of this nature, both loops are halted. Then, the script checks if the KeyValue bucket is in an inconsistent state.

An inconsistent state is observed by counting the number of keys returned by `nats kv ls`. Repeated executions give different results when the KV has been corrupted. 

There is an example execution log [`example.log`](./example.log).
