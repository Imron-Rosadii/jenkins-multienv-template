#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export MOCK_DOCKER_STATE="$TMP/state"
export MOCK_DOCKER_LOG="$TMP/docker.log"
export MOCK_DOCKER_FAIL_HEALTH="${MOCK_DOCKER_FAIL_HEALTH:-0}"
export MOCK_DOCKER_BAD_CONTENT="${MOCK_DOCKER_BAD_CONTENT:-0}"
export MOCK_DOCKER_FAIL_RENAME="${MOCK_DOCKER_FAIL_RENAME:-0}"
export MOCK_DOCKER_FAIL_START="${MOCK_DOCKER_FAIL_START:-0}"
export MOCK_DOCKER_FAIL_RUN="${MOCK_DOCKER_FAIL_RUN:-0}"

mkdir -p "$MOCK_DOCKER_STATE" "$TMP/bin"
: > "$MOCK_DOCKER_LOG"

# Mock sleep agar health-check failure tidak menunggu 30 detik.
cat > "$TMP/bin/sleep" <<'MOCK'
#!/bin/sh
exit 0
MOCK

cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu

cmd=${1:-}
shift || true

printf '%s' "$cmd" >> "$MOCK_DOCKER_LOG"
printf ' %s' "$@" >> "$MOCK_DOCKER_LOG"
printf '\n' >> "$MOCK_DOCKER_LOG"

state_file() {
    printf '%s/%s' "$MOCK_DOCKER_STATE" "$1"
}

case "$cmd" in
    inspect)
        format=
        name=

        if [[ "${1:-}" == "-f" ]]; then
            format=$2
            name=$3
        else
            name=$1
        fi

        file=$(state_file "$name")
        [[ -f "$file" ]] || exit 1

        if [[ -z "$format" ]]; then
            exit 0
        fi

        IFS='|' read -r running deployment_id html < "$file"

        case "$format" in
            '{{ index .Config.Labels "deployment-id" }}')
                printf '%s\n' "$deployment_id"
                ;;
            '{{.State.Running}}')
                printf '%s\n' "$running"
                ;;
            *)
                echo "Unexpected inspect format: $format" >&2
                exit 64
                ;;
        esac
        ;;

    update)
        # Restart-policy update does not change mock state.
        exit 0
        ;;

    stop)
        name=$1
        file=$(state_file "$name")
        [[ -f "$file" ]] || exit 1
        IFS='|' read -r running deployment_id html < "$file"
        printf 'false|%s|%s\n' "$deployment_id" "$html" > "$file"
        ;;

    rename)
        old=$1
        new=$2
        old_file=$(state_file "$old")
        new_file=$(state_file "$new")

        [[ -f "$old_file" ]] || exit 1
        [[ ! -e "$new_file" ]] || exit 1

        if [[ "$MOCK_DOCKER_FAIL_RENAME" == "all" ||
              "$MOCK_DOCKER_FAIL_RENAME" == "$old->$new" ]]; then
            echo "Mock rename failure: $old -> $new" >&2
            exit 42
        fi

        mv "$old_file" "$new_file"
        ;;

    run)
        [[ "$MOCK_DOCKER_FAIL_RUN" != 1 ]] || exit 42

        name=
        deployment_id=
        image=

        while (($#)); do
            case "$1" in
                --name)
                    name=$2
                    shift 2
                    ;;
                --label)
                    case "$2" in
                        deployment-id=*)
                            deployment_id=${2#deployment-id=}
                            ;;
                    esac
                    shift 2
                    ;;
                -d|--restart|-p)
                    if [[ "$1" == "-d" ]]; then
                        shift
                    else
                        shift 2
                    fi
                    ;;
                *)
                    image=$1
                    shift
                    ;;
            esac
        done

        [[ -n "$name" && -n "$image" ]] || exit 64

        if [[ "$MOCK_DOCKER_BAD_CONTENT" == 1 ]]; then
            html='Environment: WRONG'
        else
            html='Environment: Development'
        fi

        printf 'true|%s|%s\n' "$deployment_id" "$html" \
            > "$(state_file "$name")"
        ;;

    exec)
        name=$1
        shift
        file=$(state_file "$name")
        [[ -f "$file" ]] || exit 1

        IFS='|' read -r running deployment_id html < "$file"
        [[ "$running" == true ]] || exit 1

        if [[ "$MOCK_DOCKER_FAIL_HEALTH" == 1 ]]; then
            exit 1
        fi

        if [[ "${1:-}" == "wget" ]]; then
            case "${*: -1}" in
                http://127.0.0.1/)
                    printf '%s\n' "$html"
                    ;;
                *)
                    exit 0
                    ;;
            esac
        fi
        ;;

    logs)
        echo "Mock container logs"
        ;;

    rm)
        if [[ "${1:-}" == "-f" ]]; then
            shift
        fi
        rm -f "$(state_file "$1")"
        ;;

    start)
        name=$1
        file=$(state_file "$name")
        [[ -f "$file" ]] || exit 1
        [[ "$MOCK_DOCKER_FAIL_START" != 1 ]] || exit 42
        IFS='|' read -r running deployment_id html < "$file"
        printf 'true|%s|%s\n' "$deployment_id" "$html" > "$file"
        ;;

    *)
        echo "Unexpected mock Docker command: $cmd" >&2
        exit 64
        ;;
esac
MOCK

chmod +x "$TMP/bin/docker" "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"

SCRIPT="$ROOT/deploy/deploy-container.sh"
TARGET_CONTAINER=multienv-web-development
BACKUP_NAME="${TARGET_CONTAINER}-previous-99"

run_deploy() {
    TARGET_CONTAINER="$TARGET_CONTAINER" \
    TARGET_PORT=18083 \
    IMAGE_REF=multienv-web:test \
    BACKUP_NAME="$BACKUP_NAME" \
    EXPECTED_ENV=Development \
    DEPLOYMENT_ID=test-deployment-99 \
        sh "$SCRIPT"
}

assert_contains() {
    if ! grep -Fq "$2" <<< "$1"; then
        echo "FAIL: expected output not found: $2" >&2
        echo "$1" >&2
        exit 1
    fi
}

seed_old_container() {
    printf 'true|old-deployment|Environment: Development\n' \
        > "$(state_file "$TARGET_CONTAINER")"
}

state_file() {
    printf '%s/%s' "$MOCK_DOCKER_STATE" "$1"
}

echo "=== TEST 1: FIRST DEPLOYMENT ==="
OUTPUT=$(run_deploy)
assert_contains "$OUTPUT" "DEPLOYMENT VERIFIED"
assert_contains "$OUTPUT" "Deployment completed successfully."
[[ -f "$(state_file "$TARGET_CONTAINER")" ]]
[[ ! -e "$(state_file "$BACKUP_NAME")" ]]
echo "PASS: first deployment succeeded"

echo
echo "=== TEST 2: PRESERVE OLD CONTAINER ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container
OUTPUT=$(run_deploy)
assert_contains "$OUTPUT" "Previous release saved as $BACKUP_NAME"
assert_contains "$OUTPUT" "DEPLOYMENT VERIFIED"
[[ -f "$(state_file "$BACKUP_NAME")" ]]
[[ -f "$(state_file "$TARGET_CONTAINER")" ]]
echo "PASS: old container preserved as backup"

echo
echo "=== TEST 3: HEALTH CHECK FAILURE ROLLBACK ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container

if MOCK_DOCKER_FAIL_HEALTH=1 run_deploy > "$TMP/rollback.out" 2>&1; then
    echo "FAIL: deployment should fail when health check fails" >&2
    cat "$TMP/rollback.out" >&2
    exit 1
fi

OUTPUT=$(cat "$TMP/rollback.out")
assert_contains "$OUTPUT" "HTTP health check failed."
assert_contains "$OUTPUT" "Previous release restored."

[[ -f "$(state_file "$TARGET_CONTAINER")" ]]
[[ ! -e "$(state_file "$BACKUP_NAME")" ]]

IFS='|' read -r RUNNING DEPLOYMENT_ID HTML \
    < "$(state_file "$TARGET_CONTAINER")"

[[ "$RUNNING" == true ]]
[[ "$DEPLOYMENT_ID" == old-deployment ]]
assert_contains "$HTML" "Environment: Development"
echo "PASS: failed deployment restored old container"

echo
echo "=== TEST 4: EXISTING BACKUP PROTECTION ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container
printf 'false|previous-backup|Environment: Development\n' \
    > "$(state_file "$BACKUP_NAME")"

if run_deploy > "$TMP/backup.out" 2>&1; then
    echo "FAIL: deployment should reject an existing backup" >&2
    exit 1
fi

assert_contains "$(cat "$TMP/backup.out")" \
    "Resolve the existing backup before deploying."

IFS='|' read -r RUNNING DEPLOYMENT_ID HTML \
    < "$(state_file "$TARGET_CONTAINER")"
[[ "$RUNNING" == true ]]
[[ "$DEPLOYMENT_ID" == old-deployment ]]
echo "PASS: existing backup protected; old container untouched"

echo
echo "=== TEST 5: INVALID REQUIRED INPUT ==="
if env -u TARGET_CONTAINER sh "$SCRIPT" > "$TMP/input.out" 2>&1; then
    echo "FAIL: missing TARGET_CONTAINER should fail" >&2
    exit 1
fi
assert_contains "$(cat "$TMP/input.out")" "TARGET_CONTAINER is required"
echo "PASS: missing required input rejected"

echo
echo
echo "=== TEST 6: DOCKER RUN FAILURE ROLLBACK ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container
if MOCK_DOCKER_FAIL_RUN=1 run_deploy > "$TMP/run-failure.out" 2>&1; then
    echo "FAIL: docker run failure should fail deployment" >&2
    exit 1
fi
OUTPUT=$(cat "$TMP/run-failure.out")
assert_contains "$OUTPUT" "Failed to create the new container."
assert_contains "$OUTPUT" "Previous release restored."
IFS="|" read -r RUNNING DEPLOYMENT_ID HTML < "$(state_file "$TARGET_CONTAINER")"
[[ "$RUNNING" == true && "$DEPLOYMENT_ID" == old-deployment ]]
[[ ! -e "$(state_file "$BACKUP_NAME")" ]]
echo "PASS: Docker run failure restored old container"

echo
echo "=== TEST 7: WRONG ENVIRONMENT CONTENT ROLLBACK ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container
if MOCK_DOCKER_BAD_CONTENT=1 run_deploy > "$TMP/content-failure.out" 2>&1; then
    echo "FAIL: wrong environment content should fail deployment" >&2
    exit 1
fi
OUTPUT=$(cat "$TMP/content-failure.out")
assert_contains "$OUTPUT" "Environment content mismatch."
assert_contains "$OUTPUT" "Previous release restored."
IFS="|" read -r RUNNING DEPLOYMENT_ID HTML < "$(state_file "$TARGET_CONTAINER")"
[[ "$RUNNING" == true && "$DEPLOYMENT_ID" == old-deployment ]]
[[ ! -e "$(state_file "$BACKUP_NAME")" ]]
echo "PASS: wrong content restored old container"

echo
echo "=== TEST 8: OLD CONTAINER RESTART FAILURE ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container
if MOCK_DOCKER_FAIL_HEALTH=1 MOCK_DOCKER_FAIL_START=1 run_deploy > "$TMP/start-failure.out" 2>&1; then
    echo "FAIL: failed rollback restart should fail deployment" >&2
    exit 1
fi
OUTPUT=$(cat "$TMP/start-failure.out")
assert_contains "$OUTPUT" "Previous release could not start."
assert_contains "$OUTPUT" "Inspect container: $TARGET_CONTAINER"
IFS="|" read -r RUNNING DEPLOYMENT_ID HTML < "$(state_file "$TARGET_CONTAINER")"
[[ "$RUNNING" == false && "$DEPLOYMENT_ID" == old-deployment ]]
echo "PASS: failed restart reported and old container preserved"

echo
echo "=== TEST 9: ROLLBACK RENAME FAILURE ==="
rm -f "$MOCK_DOCKER_STATE"/*
seed_old_container
if MOCK_DOCKER_FAIL_HEALTH=1 \
   MOCK_DOCKER_FAIL_RENAME="$BACKUP_NAME->$TARGET_CONTAINER" \
   run_deploy > "$TMP/rename-failure.out" 2>&1; then
    echo "FAIL: deployment should fail when rollback rename fails" >&2
    exit 1
fi
OUTPUT=$(cat "$TMP/rename-failure.out")
assert_contains "$OUTPUT" "HTTP health check failed."
assert_contains "$OUTPUT" "Could not restore previous container name."
assert_contains "$OUTPUT" "Previous release remains at: $BACKUP_NAME"
[[ ! -e "$(state_file "$TARGET_CONTAINER")" ]]
[[ -f "$(state_file "$BACKUP_NAME")" ]]
IFS="|" read -r RUNNING DEPLOYMENT_ID HTML < "$(state_file "$BACKUP_NAME")"
[[ "$RUNNING" == false && "$DEPLOYMENT_ID" == old-deployment ]]
echo "PASS: failed rollback rename preserved old release under backup name"

echo
echo "=== TEST 10: INPUT VALIDATION ==="

run_invalid_input() {
    local description=$1
    local expected_error=$2
    shift 2

    : > "$MOCK_DOCKER_LOG"

    if env \
        TARGET_CONTAINER=multienv-web-development \
        TARGET_PORT=18083 \
        IMAGE_REF=multienv-web:test \
        BACKUP_NAME=multienv-web-development-previous-99 \
        EXPECTED_ENV=Development \
        DEPLOYMENT_ID=test-deployment-99 \
        "$@" \
        sh "$SCRIPT" > "$TMP/invalid-input.out" 2>&1; then

        echo "FAIL: $description should be rejected" >&2
        cat "$TMP/invalid-input.out" >&2
        exit 1
    fi

    assert_contains "$(cat "$TMP/invalid-input.out")" "$expected_error"

    if [[ -s "$MOCK_DOCKER_LOG" ]]; then
        echo "FAIL: Docker should not run for invalid input: $description" >&2
        cat "$MOCK_DOCKER_LOG" >&2
        exit 1
    fi

    echo "PASS: $description rejected before Docker execution"
}

run_invalid_input \
    "invalid target container" \
    "Invalid Docker container name" \
    TARGET_CONTAINER=invalid/name

run_invalid_input \
    "same target and backup name" \
    "must be different" \
    BACKUP_NAME=multienv-web-development

run_invalid_input \
    "invalid target port" \
    "TARGET_PORT must contain only numbers" \
    TARGET_PORT=abc

run_invalid_input \
    "port out of range" \
    "between 1 and 65535" \
    TARGET_PORT=70000

run_invalid_input \
    "invalid environment" \
    "Invalid EXPECTED_ENV" \
    EXPECTED_ENV=testing

run_invalid_input \
    "invalid deployment ID" \
    "Invalid DEPLOYMENT_ID" \
    DEPLOYMENT_ID=invalid/id

run_invalid_input \
    "empty image reference" \
    "IMAGE_REF is required" \
    IMAGE_REF=

run_invalid_input \
    "image reference containing whitespace" \
    "must not contain whitespace" \
    IMAGE_REF="invalid image"

echo "ALL DEPLOYMENT TESTS PASSED"
