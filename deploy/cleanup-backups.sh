#!/bin/sh
set -eu

: "${TARGET_CONTAINER:?TARGET_CONTAINER is required}"

KEEP_BACKUPS=2

case "$TARGET_CONTAINER" in
    multienv-web-development|multienv-web-staging|multienv-web-production)
        ;;
    *)
        echo "ERROR: Invalid target container: $TARGET_CONTAINER" >&2
        exit 1
        ;;
esac

echo "Backup retention target: $TARGET_CONTAINER"
echo "Keeping the newest $KEEP_BACKUPS backups."
echo "DRY-RUN: no containers will be removed."

# Create an isolated temporary directory for intermediate results.
TMP_DIR=$(mktemp -d) || {
    echo "ERROR: Cannot create temporary directory." >&2
    exit 1
}

trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

BACKUPS_FILE="$TMP_DIR/backups"
NUMERIC_FILE="$TMP_DIR/numeric"
SORTED_FILE="$TMP_DIR/sorted"
OLD_BACKUPS_FILE="$TMP_DIR/old-backups"

# Stage 1: list matching containers.
if ! docker ps -a \
    --filter "name=^/${TARGET_CONTAINER}-previous-[0-9][0-9]*$" \
    --format '{{.Names}}' > "$BACKUPS_FILE"; then
    echo "ERROR: Cannot list Docker containers." >&2
    exit 1
fi

# Stage 2: retain only backup names with numeric build suffixes.
if ! awk -v prefix="${TARGET_CONTAINER}-previous-" '
    $0 != "" && index($0, prefix) == 1 {
        suffix = substr($0, length(prefix) + 1)
        if (suffix ~ /^[0-9]+$/) {
            print suffix, $0
        }
    }
' "$BACKUPS_FILE" > "$NUMERIC_FILE"; then
    echo "ERROR: Cannot validate backup names." >&2
    exit 1
fi

# Stage 3: sort numerically by build number, newest first.
if ! sort -rn "$NUMERIC_FILE" > "$SORTED_FILE"; then
    echo "ERROR: Cannot sort backup names." >&2
    exit 1
fi

# Stage 4: select backups beyond the retention limit.
if ! awk -v keep="$KEEP_BACKUPS" \
    'NR > keep { print $2 }' \
    "$SORTED_FILE" > "$OLD_BACKUPS_FILE"; then
    echo "ERROR: Cannot select old backups." >&2
    exit 1
fi

if [ ! -s "$OLD_BACKUPS_FILE" ]; then
    echo "No old backups to remove."
    exit 0
fi

# DRY-RUN: validate each selected container and print the action.
while IFS= read -r name; do
    [ -n "$name" ] || continue

    case "$name" in
        "${TARGET_CONTAINER}-previous-"[0-9]*)
            suffix=${name#"${TARGET_CONTAINER}-previous-"}
            case "$suffix" in
                ''|*[!0-9]*)
                    echo "ERROR: Invalid backup suffix: $name" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "ERROR: Unexpected backup name: $name" >&2
            exit 1
            ;;
    esac

    if ! RUNNING=$(docker inspect -f '{{.State.Running}}' "$name"); then
        echo "ERROR: Cannot inspect backup: $name" >&2
        exit 1
    fi

    if [ "$RUNNING" = "true" ]; then
        echo "ERROR: Backup is running; refusing cleanup: $name" >&2
        exit 1
    fi

    echo "Would remove: $name"
done < "$OLD_BACKUPS_FILE"
