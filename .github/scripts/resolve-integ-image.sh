#!/usr/bin/env bash
#
# Checks integ.yml's image inputs and writes the image tag for this matrix cell to $GITHUB_ENV as PRIVTAG.
# With a digest, PRIVTAG is "<tag>@<digest>", so the chart renders "<repo>:<tag>@<digest>" and the tests pull
# exactly that image.
#
# Every cell checks every input (repo, both tags, digest), not just its own tag, so a bad run fails in all cells
# before any of them logs in to AWS or creates a cluster.
#
# Inputs (environment): IMAGE_REPO, TAG_AMD64, TAG_ARM64, IMAGE_TAG (this cell's tag), IMAGE_DIGEST (optional),
# GITHUB_ENV. Bash 3.2 compatible.

set -euo pipefail

readonly MAX_REPO_LENGTH=255

IMAGE_REPO="${IMAGE_REPO:-}"
TAG_AMD64="${TAG_AMD64:-}"
TAG_ARM64="${TAG_ARM64:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_DIGEST="${IMAGE_DIGEST:-}"
GITHUB_ENV="${GITHUB_ENV:-}"

# A path part, by Docker's rule: lowercase letters and digits, joined by ".", "_", "__" or one or more "-".
readonly PART='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
# The registries the integ tests pull from. Adding one is a deliberate change here.
REPO_PATTERNS=(
	"^public\\.ecr\\.aws/$PART/$PART\$"                                          # public ECR
	"^ghcr\\.io/$PART/$PART\$"                                                   # PR CI's test build
	"^[0-9]{12}\\.dkr\\.ecr\\.[a-z]{2}(-[a-z]+)+-[0-9]\\.amazonaws\\.com/$PART\$" # private ECR repo
)
readonly TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly UNSAFE_RE='[[:space:][:cntrl:]]'

problems=0
fail() {
	echo "✘ $*"
	problems=$((problems + 1))
}

# 1. No whitespace, line breaks or control characters anywhere.
safe=1
for name in IMAGE_REPO TAG_AMD64 TAG_ARM64 IMAGE_TAG IMAGE_DIGEST; do
	value=${!name}
	if [[ "$value" =~ $UNSAFE_RE ]]; then
		fail "$name contains whitespace or control characters"
		safe=0
	fi
done

if ((safe == 1)); then
	# 2. The repo is on the allowlist.
	repo_ok=0
	if ((${#IMAGE_REPO} <= MAX_REPO_LENGTH)); then
		for pattern in "${REPO_PATTERNS[@]}"; do
			if [[ "$IMAGE_REPO" =~ $pattern ]]; then
				repo_ok=1
			fi
		done
	fi
	if ((repo_ok == 0)); then
		fail "imageRepo '$IMAGE_REPO' is not an allowed registry path (public.ecr.aws/<a>/<b>, ghcr.io/<a>/<b>, or <account>.dkr.ecr.<region>.amazonaws.com/<a>)"
	fi

	# 3. Both tags, and this cell's tag, are valid Docker tags. An empty tag fails.
	for name in TAG_AMD64 TAG_ARM64 IMAGE_TAG; do
		value=${!name}
		if [[ ! "$value" =~ $TAG_RE ]]; then
			fail "$name '$value' is not a valid image tag"
		fi
	done

	# 4. The digest, if given, is sha256 + 64 lowercase hex.
	if [[ -n "$IMAGE_DIGEST" && ! "$IMAGE_DIGEST" =~ $DIGEST_RE ]]; then
		fail "imageDigest '$IMAGE_DIGEST' is not sha256:<64 lowercase hex>"
	fi
fi

if [[ -z "$GITHUB_ENV" ]]; then
	fail "GITHUB_ENV is not set"
fi

if ((problems > 0)); then
	echo "→ image inputs rejected; nothing was written"
	exit 1
fi

if [[ -n "$IMAGE_DIGEST" ]]; then
	privtag="$IMAGE_TAG@$IMAGE_DIGEST"
else
	privtag="$IMAGE_TAG"
fi
printf 'PRIVTAG=%s\n' "$privtag" >>"$GITHUB_ENV"
echo "✔ image: $IMAGE_REPO:$privtag"
