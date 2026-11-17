# shellcheck shell=bash
#
# The two checks every public-registry release step shares. This file is sourced, never run. It only defines
# functions and REGISTRY_* names: it sets no shell options and no traps, and loading it runs nothing.
#
#   check_target      PUBLIC_REPO is a public.ecr.aws repo and the right one for PRACTICE (no network)
#   check_platforms   an image index lists exactly linux/amd64 and linux/arm64
#
# The caller provides ok and fail, which print a ✔ or ✘ line. Both checks call them and return 1 after a fail, so a
# fail that exits and a fail that only counts a problem both work.
#
# Bash 3.2 compatible. Bash turns off `set -e` inside functions called from `if`, `||` or `&&`, so every command's
# exit status is tested by hand.

# The production public repo. A literal here, not only in GitHub settings, so a wrong variable can't point a
# practice run at it (or a real run away from it).
REGISTRY_PRODUCTION_REPO="public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws"
# A path part, by Docker's rule (the same as resolve-integ-image.sh): lowercase letters and digits, joined by ".",
# "_", "__" or one or more "-".
REGISTRY_PART='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
REGISTRY_MAX_REPO_LENGTH=255

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
