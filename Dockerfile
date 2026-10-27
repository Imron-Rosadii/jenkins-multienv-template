
FROM nginx:1.28-alpine

COPY src/ /usr/share/nginx/html/

EXPOSE 80
