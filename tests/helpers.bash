# bats test helpers.
#
# bats provides $status and $output after `run` commands, but doesn't ship
# assert_success by default. This file provides it for use in test assertions.

# Assert that the most recent `run` command exited with status 0.
assert_success() {
  if [[ "$status" != 0 ]]; then
    echo "expected: 0"
    echo "actual: $status"
    echo "output: $output"
    return 1
  fi
}

# Assert that the most recent `run` command exited with non-zero status.
assert_failure() {
  if [[ "$status" == 0 ]]; then
    echo "expected: non-zero"
    echo "actual: $status"
    echo "output: $output"
    return 1
  fi
}

# Assert that the most recent `run` output contains the given string.
assert_output_contains() {
  if [[ "$output" != *"$1"* ]]; then
    echo "expected output to contain: $1"
    echo "actual: $output"
    return 1
  fi
}
