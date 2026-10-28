#!/usr/bin/env bash
# The runner: takes one just-in-time config from the minter, runs one job
# with it, cleans up, and waits for the next config. It never exits, so
# Kubernetes never backs off restarting it, and the next job starts as soon
# as the minter has a config. This container never has the GitHub App's key.
set -uo pipefail

handoff=/handoff/jitconfig
cd /home/runner

# Stopping the pod stops the runner, which ends its job.
child=0
trap '(( child )) && kill -TERM "${child}" 2>/dev/null; wait; exit 0' TERM INT

while true; do
  until [[ -s "${handoff}" ]]; do
    sleep 2 &
    wait $!
  done
  jitconfig=$(<"${handoff}")
  rm -f "${handoff}"

  # The work directory is a volume, and it outlives the job before.
  rm -rf _work/* _work/.[!.]* 2>/dev/null || true

  ./run.sh --jitconfig "${jitconfig}" &
  child=$!
  wait "${child}" || echo "The runner exited with $?" >&2
  child=0
  unset jitconfig

  # The minter waits for this runner to leave GitHub, then a few seconds
  # more, before it mints the next config. Anything the job left running
  # dies here first.
  for proc in /proc/[0-9]*; do
    pid=${proc#/proc/}
    [[ "${pid}" == 1 || "${pid}" == "$$" ]] && continue
    kill -KILL "${pid}" 2>/dev/null || true
  done
done
