#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

export MOCK_DOCKER_CONTAINERS="$TMP/containers"
export MOCK_DOCKER_RM_LOG="$TMP/rm.log"
export PATH="$TMP/bin:$PATH"

: > "$MOCK_DOCKER_RM_LOG"

cat > "$MOCK_DOCKER_CONTAINERS" <<'NAMES'
multienv-web-production-previous-7
multienv-web-production-previous-6
multienv-web-production-previous-5
multienv-web-production-previous-4
multienv-web-production-previous-3
multienv-web-production-previous-2
NAMES

cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu

cmd=$1
shift

case "$cmd" in
    ps)
        cat "$MOCK_DOCKER_CONTAINERS"
        ;;

    inspect)
        name="${@: -1}"

        if [[ "${MOCK_FAIL_INSPECT:-0}" = 1 &&
              "$name" = "multienv-web-production-previous-5" ]]; then
            echo "Mock inspect failure" >&2
            exit 42
        fi

        case "$name" in
            multienv-web-production-previous-7)
                echo 'jenkins-deploy|multienv-web-production|true'
                ;;
            multienv-web-production-previous-6|\
            multienv-web-production-previous-5|\
            multienv-web-production-previous-4)
                echo 'jenkins-deploy|multienv-web-production|false'
                ;;
            multienv-web-production-previous-3|\
            multienv-web-production-previous-2)
                echo 'legacy|legacy|false'
                ;;
            *)
                echo "Unknown mock container: $name" >&2
                exit 1
                ;;
        esac
        ;;

    rm)
        printf '%s\n' "$*" >> "$MOCK_DOCKER_RM_LOG"
        ;;

    *)
        echo "Unexpected mock Docker command: $cmd" >&2
        exit 1
        ;;
esac
MOCK

chmod +x "$TMP/bin/docker"

SCRIPT="$ROOT/deploy/cleanup-backups.sh"

assert_contains() {
    if ! grep -Fq "$2" <<< "$1"; then
        echo "FAIL: Expected output not found: $2" >&2
        echo "$1" >&2
        exit 1
    fi
}

echo "=== TEST 1: DRY-RUN ==="
OUTPUT=$(TARGET_CONTAINER=multienv-web-production \
    sh "$SCRIPT")

assert_contains "$OUTPUT" "Mode: dry-run"
assert_contains "$OUTPUT" "SKIP: Running container: multienv-web-production-previous-7"
assert_contains "$OUTPUT" "SKIP: Legacy or unverified backup: multienv-web-production-previous-3"
assert_contains "$OUTPUT" "DRY-RUN: would remove multienv-web-production-previous-4"

if [ -s "$MOCK_DOCKER_RM_LOG" ]; then
    echo "FAIL: dry-run attempted removal" >&2
    exit 1
fi
echo "PASS: dry-run did not remove anything"

echo
echo "=== TEST 2: DELETE MODE WITH MOCK ==="
OUTPUT=$(TARGET_CONTAINER=multienv-web-production \
    CLEANUP_MODE=delete sh "$SCRIPT")

assert_contains "$OUTPUT" "Removing verified backup: multienv-web-production-previous-4"

EXPECTED="multienv-web-production-previous-4"
ACTUAL=$(cat "$MOCK_DOCKER_RM_LOG")
[ "$ACTUAL" = "$EXPECTED" ] || {
    echo "FAIL: unexpected removal log: $ACTUAL" >&2
    exit 1
}
echo "PASS: only the oldest verified backup was selected"

echo
echo "=== TEST 3: INSPECT FAILURE ==="
: > "$MOCK_DOCKER_RM_LOG"

if MOCK_FAIL_INSPECT=1 TARGET_CONTAINER=multienv-web-production \
    sh "$SCRIPT" > "$TMP/failure.out" 2>&1; then
    echo "FAIL: inspect failure should abort cleanup" >&2
    exit 1
fi

if [ -s "$MOCK_DOCKER_RM_LOG" ]; then
    echo "FAIL: removal occurred after inspect failure" >&2
    exit 1
fi
echo "PASS: inspect failure aborted without removal"

echo
echo "=== TEST 4: INVALID MODE ==="
if TARGET_CONTAINER=multienv-web-production \
    CLEANUP_MODE=invalid sh "$SCRIPT" > /dev/null 2>&1; then
    echo "FAIL: invalid mode was accepted" >&2
    exit 1
fi
echo "PASS: invalid mode rejected"

echo
echo "ALL TESTS PASSED"
