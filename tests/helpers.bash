#!/bin/bash

assert_success() {
  if [[ "$status" != 0 ]]; then
    echo "expected: 0"
    echo "actual: $status"
    echo "output: $output"
    return 1
  fi
}

assert_failure() {
  if [[ "$status" == 0 ]]; then
    echo "expected: non-zero exit code"
    echo "actual: $status"
    echo "output: $output"
    return 1
  fi
}

assert_equal() {
  if [[ "$1" != "$2" ]]; then
    echo "expected: $1"
    echo "actual: $2"
    return 1
  fi
}

assert_not_equal() {
  if [[ "$1" == "$2" ]]; then
    echo "unexpected: $1"
    echo "actual: $2"
    return 1
  fi
}

assert_match() {
  if [[ ! "$2" =~ $1 ]]; then
    echo "expected: $1"
    echo "actual: $2"
    return 1
  fi
}

assert_not_match() {
  if [[ "$2" =~ $1 ]]; then
    echo "expected: $1"
    echo "actual: $2"
    return 1
  fi
}

# Polls $3 until it succeeds or $1 seconds of wall clock elapse, sleeping $2
# between attempts. Bounded on wall clock, not on attempt count, so a command
# that blocks cannot exceed the stated budget.
wait_for_process(){
  local deadline=$((SECONDS+$1))
  local sleep_time="$2"
  local cmd="$3"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if eval "$cmd"; then
      return 0
    fi
    sleep "$sleep_time"
  done
  return 1
}

compare_owner_count() {
  secret="$1"
  namespace="$2"
  ownercount="$3"

  [[ "$(kubectl get secret ${secret} -n ${namespace} -o json | jq '.metadata.ownerReferences | length')" -eq $ownercount ]]
}

check_secret_deleted() {
  secret="$1"
  namespace="$2"
  kubeconfig_file="$3"

  if [[ -z "$kubeconfig_file" ]]; then
    result=$(kubectl get secret -n ${namespace} | grep "^${secret}$" | wc -l)
  else
    result=$(kubectl --kubeconfig="$kubeconfig_file" get secret -n ${namespace} | grep "^${secret}$" | wc -l)
  fi

  [[ "$result" -eq 0 ]]
}
