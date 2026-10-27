
#!/bin/sh
set -eu

envsubst '${APP_ENV}' \
  < /usr/share/nginx/html/index.html.template \
  > /usr/share/nginx/html/index.html

echo "Rendered HTML for environment: ${APP_ENV}"
