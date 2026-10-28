#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

export MOCK_DOCKER_CONTAINERS="$TMP/containers"
export MOCK_DOCKER_RM_LOG="$TMP/rm.log"
export MOCK_DOCKER_CALL_LOG="$TMP/calls.log"
export MOCK_DOCKER_FAIL_INSPECT="${MOCK_DOCKER_FAIL_INSPECT:-0}"
export MOCK_DOCKER_FAIL_RM="${MOCK_DOCKER_FAIL_RM:-0}"
export MOCK_DOCKER_BAD_PS="${MOCK_DOCKER_BAD_PS:-0}"
export PATH="$TMP/bin:$PATH"

: > "$MOCK_DOCKER_RM_LOG"
: > "$MOCK_DOCKER_CALL_LOG"

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

cmd=${1:-}
shift || true

printf '%s' "$cmd" >> "$MOCK_DOCKER_CALL_LOG"
printf ' %s' "$@" >> "$MOCK_DOCKER_CALL_LOG"
printf '\n' >> "$MOCK_DOCKER_CALL_LOG"

case "$cmd" in
    ps)
        if [[ "$*" != *"--filter name=^/multienv-web-production-previous-[0-9][0-9]*$"* ||
              "$*" != *"--format {{.Names}}"* ]]; then
            echo "ERROR: unexpected docker ps arguments: $*" >&2
            exit 64
        fi

        if [[ "$MOCK_DOCKER_BAD_PS" = 1 ]]; then
            echo "Mock docker ps failure" >&2
            exit 42
        fi

        cat "$MOCK_DOCKER_CONTAINERS"
        ;;

    inspect)
        if [[ "$#" -ne 3 ||
              "$1" != "-f" ||
              "$2" != '{{index .Config.Labels "managed-by"}}|{{index .Config.Labels "deployment-target"}}|{{.State.Running}}' ]]; then
            echo "ERROR: unexpected docker inspect arguments: $*" >&2
            exit 64
        fi

        name=$3

        if [[ "$MOCK_DOCKER_FAIL_INSPECT" = 1 &&
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
        if [[ "$#" -ne 1 ]]; then
            echo "ERROR: unexpected docker rm arguments: $*" >&2
            exit 64
        fi

        if [[ "$MOCK_DOCKER_FAIL_RM" = 1 ]]; then
            echo "Mock docker rm failure" >&2
            exit 42
        fi

        printf '%s\n' "$1" >> "$MOCK_DOCKER_RM_LOG"
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

assert_no_removal() {
    if [[ -s "$MOCK_DOCKER_RM_LOG" ]]; then
        echo "FAIL: unexpected removal: $(cat "$MOCK_DOCKER_RM_LOG")" >&2
        exit 1
    fi
}

echo "=== TEST 1: DRY-RUN ==="
OUTPUT=$(TARGET_CONTAINER=multienv-web-production sh "$SCRIPT")

assert_contains "$OUTPUT" "Mode: dry-run"
assert_contains "$OUTPUT" "SKIP: Running container: multienv-web-production-previous-7"
assert_contains "$OUTPUT" "SKIP: Legacy or unverified backup: multienv-web-production-previous-3"
assert_contains "$OUTPUT" "DRY-RUN: would remove multienv-web-production-previous-4"
assert_no_removal
grep -Fq -- '--filter name=^/multienv-web-production-previous-[0-9][0-9]*$' "$MOCK_DOCKER_CALL_LOG"
grep -Fq -- '--format {{.Names}}' "$MOCK_DOCKER_CALL_LOG"
echo "PASS: dry-run and docker ps arguments verified"

echo
echo "=== TEST 2: DELETE MODE WITH MOCK ==="
OUTPUT=$(TARGET_CONTAINER=multienv-web-production CLEANUP_MODE=delete sh "$SCRIPT")
assert_contains "$OUTPUT" "Removing verified backup: multienv-web-production-previous-4"

EXPECTED="multienv-web-production-previous-4"
ACTUAL=$(cat "$MOCK_DOCKER_RM_LOG")
[[ "$ACTUAL" = "$EXPECTED" ]] || {
    echo "FAIL: unexpected removal log: $ACTUAL" >&2
    exit 1
}
echo "PASS: only the oldest verified backup was selected"

echo
echo "=== TEST 3: INSPECT FAILURE ==="
: > "$MOCK_DOCKER_RM_LOG"

if MOCK_DOCKER_FAIL_INSPECT=1 TARGET_CONTAINER=multienv-web-production \
    sh "$SCRIPT" > "$TMP/failure.out" 2>&1; then
    echo "FAIL: inspect failure should abort cleanup" >&2
    exit 1
fi
assert_no_removal
echo "PASS: inspect failure aborted without removal"

echo
echo "=== TEST 4: INVALID MODE ==="
if TARGET_CONTAINER=multienv-web-production CLEANUP_MODE=invalid \
    sh "$SCRIPT" > /dev/null 2>&1; then
    echo "FAIL: invalid mode was accepted" >&2
    exit 1
fi
assert_no_removal
echo "PASS: invalid mode rejected"

echo
echo "=== TEST 5: INVALID TARGET ==="
: > "$MOCK_DOCKER_CALL_LOG"

if TARGET_CONTAINER=untrusted-container sh "$SCRIPT" > /dev/null 2>&1; then
    echo "FAIL: invalid target was accepted" >&2
    exit 1
fi

if [[ -s "$MOCK_DOCKER_CALL_LOG" ]]; then
    echo "FAIL: Docker was called for an invalid target" >&2
    exit 1
fi
echo "PASS: invalid target rejected before Docker invocation"

echo
echo "=== TEST 6: DOCKER PS FAILURE ==="
if MOCK_DOCKER_BAD_PS=1 TARGET_CONTAINER=multienv-web-production \
    sh "$SCRIPT" > "$TMP/ps-failure.out" 2>&1; then
    echo "FAIL: docker ps failure should abort cleanup" >&2
    exit 1
fi
assert_no_removal
echo "PASS: docker ps failure aborted without removal"

echo
echo "=== TEST 7: DOCKER RM FAILURE ==="
: > "$MOCK_DOCKER_RM_LOG"

if MOCK_DOCKER_FAIL_RM=1 TARGET_CONTAINER=multienv-web-production \
    CLEANUP_MODE=delete sh "$SCRIPT" > "$TMP/rm-failure.out" 2>&1; then
    echo "FAIL: docker rm failure should fail cleanup" >&2
    exit 1
fi
echo "PASS: docker rm failure returned non-zero"

echo
echo "ALL TESTS PASSED"
