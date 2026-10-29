#!/bin/sh
set -eu

: "${TARGET_CONTAINER:?TARGET_CONTAINER is required}"

KEEP_BACKUPS=2
CLEANUP_MODE=${CLEANUP_MODE:-dry-run}

case "$TARGET_CONTAINER" in
    multienv-web-development|multienv-web-staging|multienv-web-production)
        ;;
    *)
        echo "ERROR: Invalid target container: $TARGET_CONTAINER" >&2
        exit 1
        ;;
esac

case "$CLEANUP_MODE" in
    dry-run|delete) ;;
    *)
        echo "ERROR: CLEANUP_MODE must be dry-run or delete." >&2
        exit 1
        ;;
esac

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ALL_FILE="$TMP_DIR/all"
MANAGED_FILE="$TMP_DIR/managed"
SORTED_FILE="$TMP_DIR/sorted"
OLD_FILE="$TMP_DIR/old"

echo "Target: $TARGET_CONTAINER"
echo "Retention: $KEEP_BACKUPS verified backups"
echo "Mode: $CLEANUP_MODE"

if ! docker ps -a \
    --filter "name=^/${TARGET_CONTAINER}-previous-[0-9][0-9]*$" \
    --format '{{.Names}}' > "$ALL_FILE"; then
    echo "ERROR: Cannot list Docker containers." >&2
    exit 1
fi

: > "$MANAGED_FILE"

while IFS= read -r name; do
    [ -n "$name" ] || continue

    prefix="${TARGET_CONTAINER}-previous-"
    case "$name" in
        "$prefix"[0-9]*)
            suffix=${name#"$prefix"}
            case "$suffix" in
                ''|*[!0-9]*)
                    echo "SKIP: Invalid backup suffix: $name"
                    continue
                    ;;
            esac
            ;;
        *)
            echo "SKIP: Unexpected backup name: $name"
            continue
            ;;
    esac

    if ! metadata=$(docker inspect -f \
        '{{index .Config.Labels "managed-by"}}|{{index .Config.Labels "deployment-target"}}|{{.State.Running}}|{{.Created}}' \
        "$name"); then
        echo "ERROR: Cannot inspect $name; aborting." >&2
        exit 1
    fi

    managed_by=${metadata%%|*}
    metadata=${metadata#*|}
    deployment_target=${metadata%%|*}
    metadata=${metadata#*|}
    running=${metadata%%|*}
    created=${metadata#*|}

    case "$managed_by|$deployment_target|$running" in
        "jenkins-deploy|$TARGET_CONTAINER|false")
            case "$created" in
                ''|*[!0-9TZ:.-]*)
                    echo "ERROR: Invalid creation timestamp for $name; aborting." >&2
                    exit 1
                    ;;
            esac

            printf '%s %s\n' "$created" "$name" >> "$MANAGED_FILE"
            ;;
        *"|true")
            echo "SKIP: Running container: $name"
            ;;
        *)
            echo "SKIP: Legacy or unverified backup: $name"
            ;;
    esac
done < "$ALL_FILE"

if ! sort -r "$MANAGED_FILE" > "$SORTED_FILE"; then
    echo "ERROR: Cannot sort verified backups." >&2
    exit 1
fi

if ! awk -v keep="$KEEP_BACKUPS" \
    'NR > keep { print $2 }' "$SORTED_FILE" > "$OLD_FILE"; then
    echo "ERROR: Cannot select old backups." >&2
    exit 1
fi

if [ ! -s "$OLD_FILE" ]; then
    echo "No verified backups exceed retention."
    exit 0
fi

while IFS= read -r name; do
    [ -n "$name" ] || continue

    # Revalidate immediately before any potential deletion.
    if ! labels=$(docker inspect -f \
        '{{index .Config.Labels "managed-by"}}|{{index .Config.Labels "deployment-target"}}|{{.State.Running}}' \
        "$name"); then
        echo "ERROR: Cannot revalidate $name; aborting." >&2
        exit 1
    fi

    if [ "$labels" != "jenkins-deploy|$TARGET_CONTAINER|false" ]; then
        echo "ERROR: Safety validation failed for $name; aborting." >&2
        exit 1
    fi

    if [ "$CLEANUP_MODE" = "dry-run" ]; then
        echo "DRY-RUN: would remove $name"
    else
        echo "Removing verified backup: $name"
        docker rm "$name"
    fi
done < "$OLD_FILE"

echo "Cleanup finished."
