#!/usr/bin/env bash
#
# Checks that VERSION can be released, before anything is built:
#   0. the run is on main
#   1. VERSION is X.Y.Z
#   2. Makefile, Chart.yaml and values.yaml all say VERSION
#   3. no git tag VERSION exists yet
#   4. VERSION is not on ECR Public yet
#   5. VERSION is higher than the newest version on ECR Public
#
# Every check runs and prints one line (✔, ✘ or – skipped). If any check failed, it prints the number of
# problems and exits 1. It uses no AWS credentials: the registry calls are anonymous.
#
# A practice run (PRACTICE=true) uses the version already on main, so it runs checks 0-2 and skips 3-5, with no
# network calls. A missing or bad PRACTICE is a wiring error: the script prints why and exits 2 before any check.
#
# Inputs (environment): VERSION, PRACTICE (true or false), GITHUB_REF, GITHUB_REPOSITORY.
# Test-only settings: REPO_ROOT, RELEASE_CHECK_ECR_URL, RELEASE_CHECK_RETRY_SCALE, RELEASE_CHECK_DEADLINE_SECONDS.
#
# Bash 3.2 compatible (macOS /bin/bash). Bash turns off `set -e` inside functions called from `if`, `||` or `&&`,
# so every command's exit status is tested by hand. Helpers never count problems; only the checks do.

set -euo pipefail

readonly PUBLIC_REPO="public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws"
readonly ECR_REPO_PATH="aws-secrets-manager/secrets-store-csi-driver-provider-aws"
readonly ACCEPT_MANIFEST="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly MAX_VERSION_LENGTH=32
readonly MAX_PAGES=5
readonly CURL_MAX_TIME=15
readonly GIT_MAX_TIME=60
readonly TIME_FLOOR=5      # never start a network call with less than this many seconds left
readonly OUT_OF_TIME=75    # helper exit status for "deadline reached"

VERSION="${VERSION:-}"
PRACTICE="${PRACTICE:-}"
GITHUB_REF="${GITHUB_REF:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
ECR_URL="${RELEASE_CHECK_ECR_URL:-https://public.ecr.aws}"
RETRY_SCALE="${RELEASE_CHECK_RETRY_SCALE:-1}"
DEADLINE="${RELEASE_CHECK_DEADLINE_SECONDS:-360}"

for setting in "RETRY_SCALE=$RETRY_SCALE" "DEADLINE=$DEADLINE"; do
	if [[ ! "${setting#*=}" =~ ^[0-9]+$ ]]; then
		echo "✘ ${setting%%=*} must be a whole number of seconds" >&2
		exit 1
	fi
done
# No ✘ here: this is a setting, not a check, and must not look like one of the result lines.
if [[ "$PRACTICE" != true && "$PRACTICE" != false ]]; then
	echo "PRACTICE must be true or false" >&2
	exit 2
fi

problems=0
version_ok=0
out_of_time=0
token=""
token_failed=0

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	problems=$((problems + 1))
}
skip() { echo "– skipped: $*"; }

seconds_left() { echo $((DEADLINE - SECONDS)); }

# --- temp files --------------------------------------------------------------------------------------------------
# The token reply holds a bearer token, so all response files live in one private directory that is always removed.

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/release-check.XXXXXX") || {
	echo "✘ could not create a temp directory"
	exit 1
}
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

headers_file="$work_dir/headers"
body_file="$work_dir/body"

# --- repo root ---------------------------------------------------------------------------------------------------

if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fi

# --- HTTP --------------------------------------------------------------------------------------------------------

# http_request [--head] [--header H]... URL
# Sets http_status and fills $headers_file and $body_file. Retries 429 and 5xx up to 4 times.
# Returns 0 when any other status arrived (the caller judges it), 1 on a network error or when retries ran out,
# and $OUT_OF_TIME when the deadline is too close to try. Diagnostics go to stderr; never the token or the body.
http_request() {
	local url="${*: -1}"
	local attempt=1 pause=2 left max_time rc
	http_status=""
	while :; do
		left=$(seconds_left)
		if ((left < TIME_FLOOR)); then
			return "$OUT_OF_TIME"
		fi
		max_time=$CURL_MAX_TIME
		if ((left < max_time)); then
			max_time=$left
		fi
		rm -f "$headers_file" "$body_file"
		rc=0
		http_status=$(curl --silent --show-error --max-time "$max_time" --dump-header "$headers_file" \
			--output "$body_file" --write-out '%{http_code}' "$@") || rc=$?
		if ((rc != 0)); then
			echo "  curl failed (exit $rc) for $url" >&2
			return 1
		fi
		case "$http_status" in
		429 | 5[0-9][0-9]) ;;
		[1-5][0-9][0-9]) return 0 ;;
		*)
			echo "  unexpected HTTP status '$http_status' for $url" >&2
			return 1
			;;
		esac
		if ((attempt >= 5)); then
			echo "  HTTP $http_status after $attempt attempts for $url" >&2
			return 1
		fi
		left=$(seconds_left)
		if ((left < pause * RETRY_SCALE + TIME_FLOOR)); then
			return "$OUT_OF_TIME"
		fi
		echo "  HTTP $http_status for $url, retrying in $((pause * RETRY_SCALE)) s" >&2
		sleep $((pause * RETRY_SCALE))
		attempt=$((attempt + 1))
		pause=$((pause * 2))
	done
}

# Prints the value of the one `link:` header in $headers_file (any letter case), or nothing if there is none.
# Returns 1 if there is more than one.
link_header() {
	local line name lower value="" count=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line=${line%$'\r'}
		name=${line%%:*}
		if [[ "$name" == "$line" ]]; then
			continue # not a header line (status line or blank)
		fi
		lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower" == "link" ]]; then
			count=$((count + 1))
			value=${line#*:}
			value=${value#"${value%%[![:space:]]*}"}
			value=${value%"${value##*[![:space:]]}"}
		fi
	done <"$headers_file"
	if ((count > 1)); then
		return 1
	fi
	printf '%s' "$value"
}

# Gets an anonymous pull token into $token, once. Same return codes as http_request. After a failure, later calls
# fail at once instead of asking again.
get_token() {
	local rc=0 value
	if [[ -n "$token" ]]; then
		return 0
	fi
	if ((token_failed != 0)); then
		return "$token_failed"
	fi
	token_failed=1
	http_request "$ECR_URL/token/?scope=repository:$ECR_REPO_PATH:pull" || rc=$?
	if ((rc != 0)); then
		token_failed=$rc
		return "$rc"
	fi
	if [[ "$http_status" != 200 ]]; then
		echo "  token request returned HTTP $http_status" >&2
		return 1
	fi
	value=$(python3 -I -c '
import json, sys
try:
    token = json.load(open(sys.argv[1])).get("token")
except Exception:
    sys.exit(1)
if not isinstance(token, str) or not token or any(c.isspace() for c in token):
    sys.exit(1)
print(token)
' "$body_file") || {
		echo "  token reply is not JSON with a non-empty token" >&2
		return 1
	}
	token=$value
	token_failed=0
}

# Reports a helper's failure for the current check. Marks the deadline as reached when that was the reason.
fail_request() {
	local rc=$1 what=$2
	if ((rc == OUT_OF_TIME)); then
		out_of_time=1
		fail "ran out of time while checking $what"
	else
		fail "could not check $what (see the error above)"
	fi
}

# --- checks ------------------------------------------------------------------------------------------------------

check_on_main() {
	if [[ -z "$GITHUB_REF" ]]; then
		fail "GITHUB_REF is not set"
	elif [[ "$GITHUB_REF" != "refs/heads/main" ]]; then
		fail "not on main (running on $GITHUB_REF); releases run from main only"
	else
		ok "on main"
	fi
}

check_format() {
	local version_re=$VERSION_RE
	if [[ -z "$VERSION" ]]; then
		fail "VERSION is not set"
	elif ((${#VERSION} > MAX_VERSION_LENGTH)); then
		fail "version is longer than $MAX_VERSION_LENGTH characters"
	elif [[ ! "$VERSION" =~ $version_re ]]; then
		fail "$(printf '%q' "$VERSION") is not a valid version: use X.Y.Z, e.g. 3.1.5 (no \"v\", no suffix, no leading zeros)"
	else
		version_ok=1
		ok "$VERSION is a valid version"
	fi
}

# Removes one pair of matching surrounding quotes, as YAML does.
unquote() {
	local value=$1
	local double_re='^"(.*)"$' single_re="^'(.*)'$"
	if [[ "$value" =~ $double_re ]] || [[ "$value" =~ $single_re ]]; then
		value=${BASH_REMATCH[1]}
	fi
	printf '%s' "$value"
}

# Prints the value of the single line matching "^<prefix>" in a file. Fails if there are 0 or 2+ such lines.
# Trailing spaces and \r are removed.
single_value() {
	local file=$1 prefix=$2 lines count
	lines=$(grep -E "^$prefix" "$file" || true)
	count=0
	if [[ -n "$lines" ]]; then
		count=$(printf '%s\n' "$lines" | wc -l | tr -d ' ')
	fi
	if [[ "$count" != 1 ]]; then
		echo "found $count times"
		return 1
	fi
	lines=${lines#*:}
	if [[ "$prefix" == *= ]]; then
		lines=${lines#*=}
	fi
	lines=${lines%$'\r'}
	lines=${lines#"${lines%%[![:space:]]*}"}
	lines=${lines%"${lines##*[![:space:]]}"}
	printf '%s' "$lines"
}

# deployment/aws-provider-installer.yaml is not checked on purpose: it is served straight from main, so it is bumped
# only after the image is public.
check_repo_files() {
	local makefile="$REPO_ROOT/Makefile"
	local chart="$REPO_ROOT/charts/secrets-store-csi-driver-provider-aws/Chart.yaml"
	local values="$REPO_ROOT/charts/secrets-store-csi-driver-provider-aws/values.yaml"
	local reasons="" value key make_version="" part image_block image_count
	local digits_re='^[0-9]+$' three_part_re='^[0-9]+\.[0-9]+\.[0-9]+$'

	if ((version_ok == 0)); then
		skip "repo files check needs a valid version"
		return
	fi
	for file in "$makefile" "$chart" "$values"; do
		if [[ ! -r "$file" ]]; then
			fail "cannot read ${file#"$REPO_ROOT"/}"
			return
		fi
	done

	# Makefile: Make keeps quotes as part of a value, so only bare digits are accepted.
	for key in MAJOR_REV MINOR_REV PATCH_REV; do
		if ! value=$(single_value "$makefile" "$key="); then
			reasons="$reasons; Makefile $key $value"
			continue
		fi
		if [[ ! "$value" =~ $digits_re ]]; then
			reasons="$reasons; Makefile $key must be bare digits, found $(printf '%q' "$value")"
			continue
		fi
		make_version="$make_version${make_version:+.}$value"
	done
	if [[ "$make_version" =~ $three_part_re && "$make_version" != "$VERSION" ]]; then
		reasons="$reasons; Makefile says $make_version"
	fi

	if ! value=$(single_value "$chart" "version:"); then
		reasons="$reasons; Chart.yaml version $value"
	else
		value=$(unquote "$value")
		if [[ "$value" != "$VERSION" ]]; then
			reasons="$reasons; Chart.yaml says $(printf '%q' "$value")"
		fi
	fi

	# values.yaml: the top-level image: block, then its 2-space-indented repository: and tag:.
	image_count=$(grep -cE '^image:[[:space:]]*$' "$values" || true)
	if [[ "$image_count" != 1 ]]; then
		reasons="$reasons; values.yaml image: block found $image_count times"
	else
		image_block="$work_dir/image-block"
		if ! awk '/^image:[[:space:]]*$/ { inside = 1; next } inside && /^[^[:space:]#]/ { inside = 0 } inside' \
			"$values" >"$image_block"; then
			fail "could not read the image: block in values.yaml"
			return
		fi
		for part in repository tag; do
			if ! value=$(single_value "$image_block" "  $part:"); then
				reasons="$reasons; values.yaml image.$part $value"
				continue
			fi
			value=$(unquote "$value")
			if [[ "$part" == repository && "$value" != "$PUBLIC_REPO" ]]; then
				reasons="$reasons; values.yaml image.repository is $(printf '%q' "$value"), not $PUBLIC_REPO"
			elif [[ "$part" == tag && "$value" != "$VERSION" ]]; then
				reasons="$reasons; values.yaml image.tag says $(printf '%q' "$value")"
			fi
		done
	fi

	if [[ -n "$reasons" ]]; then
		fail "repo files don't match $VERSION: ${reasons#; }"
	else
		ok "Makefile, Chart.yaml and values.yaml all say $VERSION"
	fi
}

check_git_tag() {
	local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' left limit rc=0 out
	local -a git_args

	if ((version_ok == 0)); then
		skip "git tag check needs a valid version"
		return
	fi
	if [[ "$PRACTICE" == true ]]; then
		skip "practice run"
		return
	fi
	if ((out_of_time == 1)); then
		skip "ran out of time"
		return
	fi
	if [[ -z "$GITHUB_REPOSITORY" ]]; then
		fail "GITHUB_REPOSITORY is not set"
		return
	fi
	if [[ ! "$GITHUB_REPOSITORY" =~ $repo_re ]]; then
		fail "GITHUB_REPOSITORY $(printf '%q' "$GITHUB_REPOSITORY") is not owner/name"
		return
	fi
	left=$(seconds_left)
	if ((left < TIME_FLOOR)); then
		out_of_time=1
		fail "ran out of time while checking git tags"
		return
	fi

	# The low-speed settings stop a stalled transfer; `timeout` (on the CI runner, not on macOS) also bounds
	# connect, DNS and TLS. GIT_TERMINAL_PROMPT=0 makes git fail instead of asking for a password.
	git_args=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --exit-code --tags
		"https://github.com/$GITHUB_REPOSITORY"
		"refs/tags/$VERSION" "refs/tags/secrets-store-csi-driver-provider-aws-$VERSION")
	if command -v timeout >/dev/null 2>&1; then
		limit=$GIT_MAX_TIME
		if ((left < limit)); then
			limit=$left
		fi
		out=$(GIT_TERMINAL_PROMPT=0 timeout "$limit" git "${git_args[@]}" 2>&1) || rc=$?
	else
		out=$(GIT_TERMINAL_PROMPT=0 git "${git_args[@]}" 2>&1) || rc=$?
	fi

	case "$rc" in
	2) ok "no git tag $VERSION yet" ;;
	0)
		if [[ "$out" == *"refs/tags/secrets-store-csi-driver-provider-aws-$VERSION"* ]]; then
			fail "git tag secrets-store-csi-driver-provider-aws-$VERSION already exists"
		else
			fail "git tag $VERSION already exists"
		fi
		;;
	124) fail "git ls-remote timed out" ;;
	*)
		echo "$out" | head -5 >&2 || true # head may close the pipe early; that must not stop the script
		fail "git ls-remote failed (exit $rc)"
		;;
	esac
}

check_not_published() {
	local rc=0

	if ((version_ok == 0)); then
		skip "ECR Public check needs a valid version"
		return
	fi
	if [[ "$PRACTICE" == true ]]; then
		skip "practice run"
		return
	fi
	if ((out_of_time == 1)); then
		skip "ran out of time"
		return
	fi
	get_token || rc=$?
	if ((rc != 0)); then
		fail_request "$rc" "ECR Public"
		return
	fi
	http_request --head --header "Authorization: Bearer $token" --header "Accept: $ACCEPT_MANIFEST" \
		"$ECR_URL/v2/$ECR_REPO_PATH/manifests/$VERSION" || rc=$?
	if ((rc != 0)); then
		fail_request "$rc" "ECR Public"
		return
	fi
	case "$http_status" in
	404) ok "$VERSION is not on ECR Public yet" ;;
	200) fail "$VERSION is already on ECR Public" ;;
	*)
		echo "  manifest request returned HTTP $http_status" >&2
		fail "could not check ECR Public (HTTP $http_status)"
		;;
	esac
}

check_higher() {
	local rc=0 path="/v2/$ECR_REPO_PATH/tags/list?n=1000" link pages=0 newest
	local seen=$path
	local link_re="^<(/v2/$ECR_REPO_PATH/tags/list\\?[A-Za-z0-9._~%&=+/-]*)>;[[:space:]]*rel=\"next\"$"
	local all_tags="$work_dir/tags"

	if ((version_ok == 0)); then
		skip "version order check needs a valid version"
		return
	fi
	if [[ "$PRACTICE" == true ]]; then
		skip "practice run"
		return
	fi
	if ((out_of_time == 1)); then
		skip "ran out of time"
		return
	fi
	get_token || rc=$?
	if ((rc != 0)); then
		fail_request "$rc" "the current release"
		return
	fi
	: >"$all_tags"
	while :; do
		pages=$((pages + 1))
		if ((pages > MAX_PAGES)); then
			fail "tag list has more than $MAX_PAGES pages"
			return
		fi
		http_request --header "Authorization: Bearer $token" "$ECR_URL$path" || rc=$?
		if ((rc != 0)); then
			fail_request "$rc" "the current release"
			return
		fi
		if [[ "$http_status" != 200 ]]; then
			echo "  tag list returned HTTP $http_status" >&2
			fail "could not check the current release (HTTP $http_status)"
			return
		fi
		if ! python3 -I -c '
import json, sys
try:
    tags = json.load(open(sys.argv[1])).get("tags")
except Exception:
    sys.exit(1)
if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
    sys.exit(1)
for t in tags:
    print(t)
' "$body_file" >>"$all_tags"; then
			fail "could not check the current release (tag list is not valid JSON)"
			return
		fi
		if ! link=$(link_header); then
			fail "could not check the current release (more than one link header)"
			return
		fi
		if [[ -z "$link" ]]; then
			break # no link header: last page
		fi
		if [[ ! "$link" =~ $link_re ]]; then
			fail "could not check the current release (unexpected page link)"
			return
		fi
		path=${BASH_REMATCH[1]}
		if printf '%s\n' "$seen" | grep -qxF -- "$path"; then
			fail "could not check the current release (page link loop)"
			return
		fi
		seen="$seen"$'\n'"$path"
	done

	newest=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "$all_tags" | sort -V | tail -n 1 || true)
	if [[ -z "$newest" ]]; then
		fail "could not check the current release (no X.Y.Z tags on ECR Public)"
	elif [[ "$newest" == "$VERSION" ]]; then
		fail "$VERSION is not higher than the current release ($newest)"
	elif [[ "$(printf '%s\n%s\n' "$newest" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
		fail "$VERSION is not higher than the current release ($newest)"
	else
		ok "$VERSION is higher than the current release ($newest)"
	fi
}

# --- main --------------------------------------------------------------------------------------------------------

echo "Checking release version $(printf '%q' "$VERSION") (curl: $(command -v curl || echo 'not found'))"
check_on_main
check_format
check_repo_files
check_git_tag
check_not_published
check_higher

suffix=""
if [[ "$PRACTICE" == true ]]; then
	suffix=" (practice)"
fi
if ((problems > 0)); then
	if ((problems == 1)); then
		echo "→ 1 problem${suffix}"
	else
		echo "→ $problems problems${suffix}"
	fi
	exit 1
fi
echo "→ all checks passed${suffix}"
