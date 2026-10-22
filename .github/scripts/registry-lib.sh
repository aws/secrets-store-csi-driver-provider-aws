# shellcheck shell=bash
#
# Shared helpers for the release scripts that read a public registry anonymously over HTTP, plus the two checks
# every public-registry release step shares. This file is sourced, never run. It only defines functions and
# REGISTRY_* names: it sets no shell options and no traps, and loading it runs nothing.
#
# The HTTP helpers are copied on purpose from validate-release-version.sh and adapted: the repo path is a parameter
# here, not a constant, every request is paced, and the retry budget is longer. validate-release-version.sh still
# has its own copies.
#
#   seconds_left      seconds until REGISTRY_DEADLINE
#   http_request      one curl request, retrying 429, 5xx and network errors (and, on request, 404)
#   header_value      the one header of the last reply with a given name
#   link_header       the one `link:` header of the last reply
#   get_token         an anonymous pull token for REGISTRY_REPO_PATH, into REGISTRY_TOKEN
#   list_tags         every tag of REGISTRY_REPO_PATH, following page links
#   check_target      PUBLIC_REPO is a public.ecr.aws repo and the right one for PRACTICE (no network)
#   check_platforms   an image index lists exactly linux/amd64 and linux/arm64
#
# The caller provides:
#   ok, fail             print a ✔ or ✘ line. check_target and check_platforms call them and return 1 after a fail,
#                        so a fail that exits and a fail that only counts a problem both work.
#   REGISTRY_WORK_DIR    a private temp directory that the caller removes (reply files hold the bearer token)
#   REGISTRY_REPO_PATH   <namespace>/<name>, the repo that get_token and list_tags are for
#   REGISTRY_DEADLINE    no request starts after this many seconds of the script's run time
# Test-only settings: REGISTRY_URL (default https://public.ecr.aws), REGISTRY_RETRY_SCALE (multiplies every retry
# pause, default 1), REGISTRY_PACE_SECONDS (pause before every request after the first, default 1.2).
#
# Bash 3.2 compatible. Bash turns off `set -e` inside functions called from `if`, `||` or `&&`, so every command's
# exit status is tested by hand.

# The production public repo. A literal here, not only in GitHub settings, so a wrong variable can't point a
# practice run at it (or a real run away from it).
REGISTRY_PRODUCTION_REPO="public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws"
# Used by the scripts that source this file.
# shellcheck disable=SC2034
REGISTRY_ACCEPT_MANIFEST="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
# A path part, by Docker's rule (the same as resolve-integ-image.sh): lowercase letters and digits, joined by ".",
# "_", "__" or one or more "-".
REGISTRY_PART='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
REGISTRY_MAX_REPO_LENGTH=255
REGISTRY_MAX_PAGES=5
REGISTRY_CURL_MAX_TIME=15
REGISTRY_TIME_FLOOR=5   # never start a request with less than this many seconds left
REGISTRY_OUT_OF_TIME=75 # helper exit status for "deadline reached"
# Up to 8 attempts per request, pausing 2, 4, 8, 16, 30, 30, 30 s between them.
REGISTRY_MAX_ATTEMPTS=8
REGISTRY_MAX_PAUSE=30

# --- time and pacing ---------------------------------------------------------------------------------------------

seconds_left() { echo $((${REGISTRY_DEADLINE:-0} - SECONDS)); }

# Checks the numeric settings. Returns 1 with a message on stderr if one is not a number.
registry_check_settings() {
	if [[ ! "${REGISTRY_RETRY_SCALE:-1}" =~ ^[0-9]+$ ]]; then
		echo "  REGISTRY_RETRY_SCALE must be a whole number" >&2
		return 1
	fi
	if [[ ! "${REGISTRY_PACE_SECONDS:-1.2}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "  REGISTRY_PACE_SECONDS must be a number of seconds" >&2
		return 1
	fi
	if [[ ! "${REGISTRY_DEADLINE:-}" =~ ^[0-9]+$ ]]; then
		echo "  REGISTRY_DEADLINE must be a whole number of seconds" >&2
		return 1
	fi
}

# ECR Public allows one unauthenticated request per second, and it can't be raised. Sleeps the pacing interval
# before every request except the first one this script sends, whether the last one worked or not.
registry_pace() {
	local pace=${REGISTRY_PACE_SECONDS:-1.2}
	if [[ -n "${REGISTRY_REQUESTS_SENT:-}" && "$pace" != 0 ]]; then
		sleep "$pace"
	fi
	REGISTRY_REQUESTS_SENT=1
}

# --- HTTP --------------------------------------------------------------------------------------------------------

# http_request [--retry-404] [--want-header NAME] [--head] [--header H]... URL
# Sets REGISTRY_HTTP_STATUS and fills $REGISTRY_WORK_DIR/headers and $REGISTRY_WORK_DIR/body. Retries a network
# error, 429 and 5xx; with --retry-404 also a 404, and with --want-header also a 200 that lacks exactly one NAME
# header. All retries share one budget of REGISTRY_MAX_ATTEMPTS attempts.
# Returns 0 when any other status arrived (the caller judges it), 1 on a bad setting or when the retries ran out,
# and $REGISTRY_OUT_OF_TIME when the deadline is too close to try. Diagnostics go to stderr; never the token or the
# body.
http_request() {
	local retry_404=0 want_header="" url attempt=1 pause=2 left max_time rc reason value
	local scale=${REGISTRY_RETRY_SCALE:-1}
	local headers_file="${REGISTRY_WORK_DIR:?}/headers" body_file="$REGISTRY_WORK_DIR/body"
	while :; do
		case "${1:-}" in
		--retry-404) retry_404=1 ;;
		--want-header)
			want_header=$2
			shift
			;;
		*) break ;;
		esac
		shift
	done
	url="${*: -1}"
	REGISTRY_HTTP_STATUS=""
	if ! registry_check_settings; then
		return 1
	fi
	while :; do
		left=$(seconds_left)
		if ((left < REGISTRY_TIME_FLOOR)); then
			return "$REGISTRY_OUT_OF_TIME"
		fi
		max_time=$REGISTRY_CURL_MAX_TIME
		if ((left < max_time)); then
			max_time=$left
		fi
		registry_pace
		rm -f "$headers_file" "$body_file"
		rc=0
		REGISTRY_HTTP_STATUS=$(curl --silent --show-error --max-time "$max_time" --dump-header "$headers_file" \
			--output "$body_file" --write-out '%{http_code}' "$@") || rc=$?
		if ((rc != 0)); then
			reason="curl failed (exit $rc)"
		else
			case "$REGISTRY_HTTP_STATUS" in
			429 | 5[0-9][0-9]) reason="HTTP $REGISTRY_HTTP_STATUS" ;;
			404)
				if ((retry_404 == 0)); then
					return 0
				fi
				reason="HTTP 404"
				;;
			200)
				if [[ -z "$want_header" ]] || { value=$(header_value "$want_header") && [[ -n "$value" ]]; }; then
					return 0
				fi
				reason="no single $want_header header"
				;;
			[1-5][0-9][0-9]) return 0 ;;
			*)
				echo "  unexpected HTTP status '$REGISTRY_HTTP_STATUS' for $url" >&2
				return 1
				;;
			esac
		fi
		if ((attempt >= REGISTRY_MAX_ATTEMPTS)); then
			echo "  $reason after $attempt attempts for $url" >&2
			return 1
		fi
		left=$(seconds_left)
		if ((left < pause * scale + REGISTRY_TIME_FLOOR)); then
			echo "  $reason for $url; no time left to retry" >&2
			return "$REGISTRY_OUT_OF_TIME"
		fi
		echo "  $reason for $url, retrying in $((pause * scale)) s" >&2
		sleep $((pause * scale))
		attempt=$((attempt + 1))
		pause=$((pause * 2))
		if ((pause > REGISTRY_MAX_PAUSE)); then
			pause=$REGISTRY_MAX_PAUSE
		fi
	done
}

# header_value <name> : prints the value of the one header of the last reply with this name (any letter case), or
# nothing if there is none. Returns 1 if there is more than one.
header_value() {
	local want line name lower value="" count=0
	want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r line || [[ -n "$line" ]]; do
		line=${line%$'\r'}
		name=${line%%:*}
		if [[ "$name" == "$line" ]]; then
			continue # not a header line (status line or blank)
		fi
		lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower" == "$want" ]]; then
			count=$((count + 1))
			value=${line#*:}
			value=${value#"${value%%[![:space:]]*}"}
			value=${value%"${value##*[![:space:]]}"}
		fi
	done <"${REGISTRY_WORK_DIR:?}/headers"
	if ((count > 1)); then
		return 1
	fi
	printf '%s' "$value"
}

# Prints the value of the one `link:` header of the last reply, or nothing if there is none. Returns 1 if there is
# more than one.
link_header() { header_value link; }

# Returns 0 if REGISTRY_REPO_PATH is <namespace>/<name>; otherwise prints why to stderr and returns 1.
registry_check_repo_path() {
	local path_re="^$REGISTRY_PART/$REGISTRY_PART\$"
	if [[ ! "${REGISTRY_REPO_PATH:-}" =~ $path_re ]]; then
		echo "  REGISTRY_REPO_PATH $(printf '%q' "${REGISTRY_REPO_PATH:-}") is not <namespace>/<name>" >&2
		return 1
	fi
}

# Gets an anonymous pull token for REGISTRY_REPO_PATH into REGISTRY_TOKEN, once. Same return codes as http_request.
# After a failure, later calls fail at once instead of asking again. The token (or the failure) is kept for the
# whole process and is not tied to the path, so use one REGISTRY_REPO_PATH per process.
get_token() {
	local rc=0 value
	if [[ -n "${REGISTRY_TOKEN:-}" ]]; then
		return 0
	fi
	if [[ -n "${REGISTRY_TOKEN_FAILED:-}" ]]; then
		return "$REGISTRY_TOKEN_FAILED"
	fi
	REGISTRY_TOKEN_FAILED=1
	if ! registry_check_repo_path; then
		return 1
	fi
	http_request "${REGISTRY_URL:-https://public.ecr.aws}/token/?scope=repository:$REGISTRY_REPO_PATH:pull" || rc=$?
	if ((rc != 0)); then
		REGISTRY_TOKEN_FAILED=$rc
		return "$rc"
	fi
	if [[ "$REGISTRY_HTTP_STATUS" != 200 ]]; then
		echo "  token request returned HTTP $REGISTRY_HTTP_STATUS" >&2
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
' "$REGISTRY_WORK_DIR/body") || {
		echo "  token reply is not JSON with a non-empty token" >&2
		return 1
	}
	REGISTRY_TOKEN=$value
	REGISTRY_TOKEN_FAILED=""
}

# list_tags <file> : writes every tag of REGISTRY_REPO_PATH to <file>, one per line, following the registry's page
# links (at most REGISTRY_MAX_PAGES pages, no loops, only links back into the same tag list). Same return codes as
# http_request; every failure prints why to stderr.
list_tags() {
	local out=$1 rc=0 path link pages=0 seen link_re
	if ! registry_check_repo_path; then
		return 1
	fi
	path="/v2/$REGISTRY_REPO_PATH/tags/list?n=1000"
	seen=$path
	# The repo path is compared as plain text below, not put in the pattern, where a "." would match anything.
	link_re='^<(/v2/[^?]+/tags/list\?[A-Za-z0-9._~%&=+/-]*)>;[[:space:]]*rel="next"$'
	get_token || rc=$?
	if ((rc != 0)); then
		return "$rc"
	fi
	: >"$out"
	while :; do
		pages=$((pages + 1))
		if ((pages > REGISTRY_MAX_PAGES)); then
			echo "  tag list has more than $REGISTRY_MAX_PAGES pages" >&2
			return 1
		fi
		http_request --header "Authorization: Bearer $REGISTRY_TOKEN" "${REGISTRY_URL:-https://public.ecr.aws}$path" ||
			rc=$?
		if ((rc != 0)); then
			return "$rc"
		fi
		if [[ "$REGISTRY_HTTP_STATUS" != 200 ]]; then
			echo "  tag list returned HTTP $REGISTRY_HTTP_STATUS" >&2
			return 1
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
' "$REGISTRY_WORK_DIR/body" >>"$out"; then
			echo "  tag list is not valid JSON" >&2
			return 1
		fi
		if ! link=$(link_header); then
			echo "  tag list has more than one link header" >&2
			return 1
		fi
		if [[ -z "$link" ]]; then
			return 0 # no link header: last page
		fi
		if [[ ! "$link" =~ $link_re || "${BASH_REMATCH[1]}" != "/v2/$REGISTRY_REPO_PATH/tags/list?"* ]]; then
			echo "  tag list has an unexpected page link" >&2
			return 1
		fi
		path=${BASH_REMATCH[1]}
		if printf '%s\n' "$seen" | grep -qxF -- "$path"; then
			echo "  tag list page links loop" >&2
			return 1
		fi
		seen="$seen"$'\n'"$path"
	done
}

# --- shared checks -----------------------------------------------------------------------------------------------

# The target repo is public.ecr.aws/<namespace>/<name>, and the production repo exactly when PRACTICE is false.
# Reads only PUBLIC_REPO and PRACTICE: no network, no credentials.
check_target() {
	local repo_re="^public\\.ecr\\.aws/$REGISTRY_PART/$REGISTRY_PART\$"
	if [[ "${PRACTICE:-}" != true && "${PRACTICE:-}" != false ]]; then
		fail "PRACTICE must be true or false, not $(printf '%q' "${PRACTICE:-}")"
		return 1
	fi
	if [[ -z "${PUBLIC_REPO:-}" ]]; then
		fail "PUBLIC_REPO is not set"
		return 1
	fi
	if ((${#PUBLIC_REPO} > REGISTRY_MAX_REPO_LENGTH)) || [[ ! "$PUBLIC_REPO" =~ $repo_re ]]; then
		fail "PUBLIC_REPO $(printf '%q' "$PUBLIC_REPO") is not public.ecr.aws/<namespace>/<name>"
		return 1
	fi
	if [[ "$PRACTICE" == true && "$PUBLIC_REPO" == "$REGISTRY_PRODUCTION_REPO" ]]; then
		fail "a practice run must not publish to the production repo $REGISTRY_PRODUCTION_REPO"
		return 1
	fi
	if [[ "$PRACTICE" == false && "$PUBLIC_REPO" != "$REGISTRY_PRODUCTION_REPO" ]]; then
		fail "a real run must publish to $REGISTRY_PRODUCTION_REPO, not $PUBLIC_REPO"
		return 1
	fi
	if [[ "$PRACTICE" == true ]]; then
		ok "target $PUBLIC_REPO (practice run, not the production repo)"
	else
		ok "target $PUBLIC_REPO (real run, the production repo)"
	fi
}

# check_platforms <index file> <name for messages> : the index lists exactly linux/amd64 and linux/arm64 (arm64
# may carry variant v8). Parsed with python3 -I, so a script without jq can use it.
check_platforms() {
	local file=$1 what=$2 entries
	# The same reading as jq's `.manifests | map("\(.os)/\(.architecture)" + "/\(.variant)" if set) | sort`:
	# a missing manifests list or platform is an error; a non-string value prints as JSON, as jq does. A name with
	# whitespace in it is an error too.
	if ! entries=$(python3 -I -c '
import json, sys

def text(value):
    return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))

try:
    with open(sys.argv[1], "rb") as f:
        index = json.loads(f.read())
    manifests = index.get("manifests") if isinstance(index, dict) else None
    if manifests is None or manifests is False:
        sys.exit(1)
    if isinstance(manifests, dict):
        manifests = list(manifests.values())
    if not isinstance(manifests, list):
        sys.exit(1)
    entries = []
    for entry in manifests:
        platform = entry.get("platform") if isinstance(entry, dict) else None
        if platform is None or platform is False or not isinstance(platform, dict):
            sys.exit(1)
        name = text(platform.get("os")) + "/" + text(platform.get("architecture"))
        variant = platform.get("variant")
        if variant is not None and variant is not False:
            if not isinstance(variant, str):
                sys.exit(1)
            name += "/" + variant
        # The names are joined with spaces below, so a space inside one could fake a second platform.
        if any(ch.isspace() for ch in name):
            sys.exit(1)
        entries.append(name)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
print(" ".join(sorted(entries)))
' "$file"); then
		fail "could not read the platforms of $what"
		return 1
	fi
	case "$entries" in
	"linux/amd64 linux/arm64" | "linux/amd64 linux/arm64/v8") ok "platforms: $entries" ;;
	*)
		fail "expected exactly linux/amd64 and linux/arm64, found: ${entries:-nothing}"
		return 1
		;;
	esac
}
