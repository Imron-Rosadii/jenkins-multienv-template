
FROM nginx:1.28-alpine

ARG APP_ENV=DEVELOPMENT
ENV APP_ENV=${APP_ENV}

COPY src/index.html.template /usr/share/nginx/html/index.html.template
COPY --chmod=755 deploy/10-render-template.sh /docker-entrypoint.d/10-render-template.sh

EXPOSE 80
