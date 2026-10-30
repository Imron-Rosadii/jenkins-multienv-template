#!/bin/sh
set -eu

: "${TARGET_CONTAINER:?TARGET_CONTAINER is required}"
: "${TARGET_PORT:?TARGET_PORT is required}"
: "${IMAGE_REF:?IMAGE_REF is required}"
: "${BACKUP_NAME:?BACKUP_NAME is required}"
: "${EXPECTED_ENV:?EXPECTED_ENV is required}"
: "${DEPLOYMENT_ID:?DEPLOYMENT_ID is required}"

OLD_CONTAINER_FOUND=0
DEPLOYMENT_OK=0


# Validate Docker container names.
validate_container_name() {
    name=$1

    case "$name" in
        ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9_.-]*)
            echo "ERROR: Invalid Docker container name: $name"
            return 1
            ;;
    esac
}

# Validate target container name.
validate_container_name "$TARGET_CONTAINER"

# Validate backup container name.
validate_container_name "$BACKUP_NAME"

# Target and backup names must be different.
if [ "$TARGET_CONTAINER" = "$BACKUP_NAME" ]; then
    echo "ERROR: TARGET_CONTAINER and BACKUP_NAME must be different."
    exit 1
fi

# Validate target port.
case "$TARGET_PORT" in
    ''|*[!0-9]*)
        echo "ERROR: TARGET_PORT must contain only numbers."
        exit 1
        ;;
esac

# Remove leading zeros before numeric comparison.
TARGET_PORT_NUM=$(printf '%s' "$TARGET_PORT" | sed 's/^0*//')
TARGET_PORT_NUM=${TARGET_PORT_NUM:-0}

# Avoid excessively large numeric input.
if [ "${#TARGET_PORT_NUM}" -gt 5 ]; then
    echo "ERROR: TARGET_PORT must be between 1 and 65535."
    exit 1
fi

if [ "$TARGET_PORT_NUM" -lt 1 ] || [ "$TARGET_PORT_NUM" -gt 65535 ]; then
    echo "ERROR: TARGET_PORT must be between 1 and 65535."
    exit 1
fi

# Use normalized port value for Docker port mapping.
TARGET_PORT=$TARGET_PORT_NUM

# Validate expected environment.
case "$EXPECTED_ENV" in
    Development|Staging|Production)
        ;;
    *)
        echo "ERROR: Invalid EXPECTED_ENV: $EXPECTED_ENV"
        exit 1
        ;;
esac

# Validate deployment ID.
case "$DEPLOYMENT_ID" in
    ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9_.-]*)
        echo "ERROR: Invalid DEPLOYMENT_ID."
        exit 1
        ;;
esac

# Validate image reference.
case "$IMAGE_REF" in
    '')
        echo "ERROR: IMAGE_REF is required."
        exit 1
        ;;
    *[[:space:]]*)
        echo "ERROR: IMAGE_REF must not contain whitespace."
        exit 1
        ;;
esac

echo "Deployment input validation passed."


rollback() {
    rc=$?
    trap - EXIT

    if [ "$DEPLOYMENT_OK" -eq 1 ]; then
        exit "$rc"
    fi

    echo "ERROR: Deployment failed. Starting rollback..."

    # Remove only a container created by this deployment attempt.
    if docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
        FOUND_DEPLOYMENT_ID=$(docker inspect \
            -f '{{ index .Config.Labels "deployment-id" }}' \
            "$TARGET_CONTAINER" 2>/dev/null || true)

        if [ "$FOUND_DEPLOYMENT_ID" = "$DEPLOYMENT_ID" ]; then
            echo "Removing failed deployment container..."
            docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
        else
            echo "Target container does not belong to this deployment."
            echo "Preserving it."
        fi
    fi

    if [ "$OLD_CONTAINER_FOUND" -eq 1 ]; then
        # The old container was renamed to the backup name.
        if docker inspect "$BACKUP_NAME" >/dev/null 2>&1; then
            if docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
                echo "CRITICAL: Target name is occupied."
                echo "Previous release remains at: $BACKUP_NAME"
                exit "$rc"
            fi

            if docker rename "$BACKUP_NAME" "$TARGET_CONTAINER"; then
                docker update --restart=unless-stopped \
                    "$TARGET_CONTAINER" || true

                RUNNING=$(docker inspect \
                    -f '{{.State.Running}}' \
                    "$TARGET_CONTAINER" 2>/dev/null || echo false)

                if [ "$RUNNING" != "true" ]; then
                    if ! docker start "$TARGET_CONTAINER"; then
                        echo "CRITICAL: Previous release could not start."
                        echo "Inspect container: $TARGET_CONTAINER"
                        exit "$rc"
                    fi
                fi

                echo "Previous release restored."
            else
                echo "CRITICAL: Could not restore previous container name."
                echo "Previous release remains at: $BACKUP_NAME"
            fi

        # Rename did not happen; the old container still has its target name.
        elif docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
            docker update --restart=unless-stopped \
                "$TARGET_CONTAINER" || true

            RUNNING=$(docker inspect \
                -f '{{.State.Running}}' \
                "$TARGET_CONTAINER" 2>/dev/null || echo false)

            if [ "$RUNNING" = "true" ]; then
                echo "Previous release is already running."
            elif docker start "$TARGET_CONTAINER"; then
                echo "Previous release restarted."
            else
                echo "CRITICAL: Previous release could not be restarted."
            fi
        else
            echo "CRITICAL: Previous release was not found by either name."
            echo "Manual recovery is required."
        fi
    fi

    exit "$rc"
}

trap rollback EXIT

# Never overwrite a backup left by an earlier deployment.
if docker inspect "$BACKUP_NAME" >/dev/null 2>&1; then
    echo "ERROR: Backup already exists: $BACKUP_NAME"
    echo "Resolve the existing backup before deploying."
    exit 1
fi

# Preserve the currently deployed release.
if docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
    OLD_CONTAINER_FOUND=1

    docker update --restart=no "$TARGET_CONTAINER"
    docker stop "$TARGET_CONTAINER"

    if ! docker rename "$TARGET_CONTAINER" "$BACKUP_NAME"; then
        echo "ERROR: Could not rename previous container."
        exit 1
    fi

    echo "Previous release saved as $BACKUP_NAME"
else
    echo "No previous release exists."
fi

echo "Starting new release: $IMAGE_REF"

# The unique deployment ID lets rollback identify this attempt,
# even if docker run fails after creating the container.
if ! docker run -d \
    --name "$TARGET_CONTAINER" \
    --label "managed-by=jenkins-deploy" \
    --label "deployment-target=$TARGET_CONTAINER" \
    --label "deployment-id=$DEPLOYMENT_ID" \
    --restart unless-stopped \
    -p "$TARGET_PORT:80" \
    "$IMAGE_REF"; then
    echo "ERROR: Failed to create the new container."
    exit 1
fi

# Wait for HTTP to respond inside the container.
OK=0
for i in $(seq 1 15); do
    if docker exec "$TARGET_CONTAINER" \
        wget -q -O /dev/null http://127.0.0.1/; then
        OK=1
        break
    fi
    sleep 2
done

if [ "$OK" -ne 1 ]; then
    echo "ERROR: HTTP health check failed."
    docker logs "$TARGET_CONTAINER" || true
    exit 1
fi

# Verify that the image serves the expected environment.
HTML=$(docker exec "$TARGET_CONTAINER" \
    wget -q -O - http://127.0.0.1/) || HTML=""

if ! printf '%s\n' "$HTML" |
    grep -Fq "Environment: $EXPECTED_ENV"; then
    echo "ERROR: Environment content mismatch."
    echo "Expected: Environment: $EXPECTED_ENV"
    printf '%s\n' "$HTML"
    docker logs "$TARGET_CONTAINER" || true
    exit 1
fi

echo "HTTP health check PASSED"
echo "Environment content check PASSED"
echo "DEPLOYMENT VERIFIED"
echo "Container: $TARGET_CONTAINER"
echo "Image: $IMAGE_REF"
echo "Port: $TARGET_PORT"
echo "Environment: $EXPECTED_ENV"
echo "Deployment ID: $DEPLOYMENT_ID"

DEPLOYMENT_OK=1
trap - EXIT

echo "Deployment completed successfully."
