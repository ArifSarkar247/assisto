#!/usr/bin/env bash
# One load-test pass on the CI runner (NEVER the live server):
#   run_one.sh <sut_backend_dir> <label> <workers> <threads> <users> <seed> <ramp_s> <hold_s>
# Fresh throw-away DB -> migrate + seed (head code: core/perf_seed.py) ->
# gunicorn from <sut_backend_dir> + nginx, both pinned to CPUs 0-1 (the live
# box has 2 vCPU) -> Locust on CPUs 2-3 -> summary + pg stats in out/<label>.
set -u
SUT=$1; LABEL=$2; WORKERS=$3; THREADS=$4; USERS=$5; SEED=$6; RAMP=$7; HOLD=$8
W=$GITHUB_WORKSPACE
OUT=$W/out/$LABEL
mkdir -p "$OUT"
psql_() { docker exec pg psql -U postgres -v ON_ERROR_STOP=1 "$@"; }

psql_ -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" -c "CREATE DATABASE $DB_NAME"
psql_ -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
(cd $W/head/backend && python manage.py migrate -v0 --noinput &&
 python manage.py loadtest_seed --users $SEED --out $W/tokens.json) | tail -2
psql_ -d $DB_NAME -c "SELECT pg_stat_statements_reset()" >/dev/null
docker logs pg 2>&1 | wc -l > $W/pg_lines_before

EXTRA=""
[ "$THREADS" != "0" ] && EXTRA="--worker-class gthread --threads $THREADS"
(cd $SUT && nohup taskset -c 0,1 python -m gunicorn assisto_backend.wsgi:application \
  --workers $WORKERS $EXTRA --bind 127.0.0.1:8700 --timeout 60 \
  > $OUT/gunicorn.log 2>&1 &)
sudo nginx -c $W/head/loadtest/nginx.conf -s stop 2>/dev/null || true
sleep 1
sudo taskset -c 0,1 nginx -c $W/head/loadtest/nginx.conf
for i in $(seq 1 40); do curl -sf http://127.0.0.1:8080/api/v1/health >/dev/null && break; sleep 1; done
vmstat 5 > $OUT/vmstat.log 2>&1 &
VM=$!

ulimit -n 65535
(cd $W/head/loadtest && LT_TOKENS=$W/tokens.json LT_USERS=$USERS LT_RAMP_S=$RAMP LT_HOLD_S=$HOLD \
  taskset -c 2,3 locust -f locustfile.py --headless --host http://127.0.0.1:8080 \
  --processes 2 --csv $OUT/lt --csv-full-history --only-summary --stop-timeout 15 \
  --exit-code-on-error 0 > $OUT/locust.log 2>&1) || true

kill $VM 2>/dev/null || true
python $W/head/loadtest/summarize.py $OUT/lt $LABEL $OUT || true
psql_ -d $DB_NAME -c "SELECT round(total_exec_time) AS total_ms, calls, round(mean_exec_time::numeric,2) AS mean_ms, left(regexp_replace(query, '\s+', ' ', 'g'), 220) AS query FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 25" > $OUT/pg_top_queries.txt || true
docker logs pg 2>&1 | tail -n +$(( $(cat $W/pg_lines_before) + 1 )) | grep -A40 "duration:" | head -600 > $OUT/pg_slow_plans.txt || true
pkill -f "gunicorn assisto_backend" || true
sleep 3
sudo nginx -c $W/head/loadtest/nginx.conf -s stop 2>/dev/null || true
rm -f $W/tokens.json
