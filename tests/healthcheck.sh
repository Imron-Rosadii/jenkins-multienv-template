
#!/bin/sh
set -eu

URL="${1:-http://127.0.0.1/}"

if wget -q -O /dev/null "$URL"; then
    echo "HEALTHCHECK OK: $URL"
else
    echo "HEALTHCHECK FAILED: $URL"
    exit 1
fi
