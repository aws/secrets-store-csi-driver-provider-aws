#!/bin/bash
# Self-check for helpers.bash. Needs no cluster and no AWS credentials.
set -euo pipefail

cd "$(dirname "$0")"
source helpers.bash

fail() {
	echo "FAIL: $1"
	exit 1
}

# wait_for_process must bound on wall clock, including time spent inside the
# polled command. A 5s budget polling a 3s command must not run for 20s.
start=$SECONDS
if wait_for_process 5 1 "sleep 3; false"; then
	fail "wait_for_process returned success for a command that never succeeds"
fi
elapsed=$((SECONDS - start))
[[ "$elapsed" -lt 10 ]] || fail "wait_for_process ran ${elapsed}s against a 5s budget"

# Returns as soon as the command succeeds.
start=$SECONDS
wait_for_process 30 5 "true" || fail "wait_for_process did not return success for 'true'"
elapsed=$((SECONDS - start))
[[ "$elapsed" -lt 3 ]] || fail "wait_for_process slept ${elapsed}s before its first attempt"

echo "helpers.bash self-check passed"
