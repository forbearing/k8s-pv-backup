#!/usr/bin/env bash

kill -INT $(ps aux | grep "[b]ackup-script-restic.sh" | awk '{print $2}')

local count=1
while true; do
    if [[ $(pgrep restic) -ne 0 ]]; then
        break; fi
    kill -INT $(pgrep restic) &> /dev/null
    restic unlock
    if [[ ${count} -ge 3 ]]; then
        break; fi
    (( count++ ))
    sleep 1
done

kill -KILL $(pgrep restic) &> /dev/null
restic unlock
exit 0
