FROM nginx:alpine

RUN apk add --no-cache certbot bash tini

RUN install -d -o nginx -g nginx -m 0755 /var/lib/nginx/vhosts.d \
    && install -d -o nginx -g nginx -m 0755 /var/www/certbot

COPY docker-entrypoint-lecert.sh /docker-entrypoint-lecert.sh
RUN chmod +x /docker-entrypoint-lecert.sh

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ /etc/nginx/snippets/
COPY conf.d/00-defaults.conf /etc/nginx/conf.d/00-defaults.conf

STOPSIGNAL SIGQUIT
ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint-lecert.sh"]
CMD ["nginx", "-g", "daemon off;"]
