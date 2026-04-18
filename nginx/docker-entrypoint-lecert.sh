#!/usr/bin/env bash
set -euo pipefail

VHOST_DIR="${VHOST_DIR:-/data/vhosts}"
GEN_DIR="/var/lib/nginx/vhosts.d"
WEBROOT="/var/www/certbot"
LE_LIVE="/etc/letsencrypt/live"
BASE_DOMAIN="${BASE_DOMAIN:-example.ru}"
LE_EMAIL="${LETSENCRYPT_EMAIL:-}"
LE_STAGING_FLAG=()
if [ "${LETSENCRYPT_STAGING:-0}" = "1" ]; then
    LE_STAGING_FLAG=(--staging)
fi

log() { echo "[lecert] $*"; }

require_email() {
    if [ -z "$LE_EMAIL" ]; then
        log "FATAL: set LETSENCRYPT_EMAIL in docker-compose (or .env)."
        exit 1
    fi
}

upsafe() {
    echo "$1" | tr '.-' '_' | tr -cd 'a-zA-Z0-9_'
}

cert_exists() {
    [ -f "$LE_LIVE/$1/fullchain.pem" ]
}

render_vhosts() {
    mkdir -p "$GEN_DIR"
    local out="$GEN_DIR/generated-vhosts.conf"
    local tmp
    tmp="$(mktemp)"

    shopt -s nullglob
    local files=( "$VHOST_DIR"/*.vhost )
    shopt -u nullglob

    if [ "${#files[@]}" -eq 0 ]; then
        log "no .vhost files in $VHOST_DIR (only defaults on 80/443)"
        echo "# no vhosts" >"$tmp"
        mv -f "$tmp" "$out"
        return 0
    fi

    : >"$tmp"

    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"

        local fqdn=""
        if [ -n "${SERVER_NAME:-}" ]; then
            fqdn="$SERVER_NAME"
        elif [ -n "${SUBDOMAIN:-}" ]; then
            fqdn="${SUBDOMAIN}.${BASE_DOMAIN}"
        else
            log "skip $f: set SUBDOMAIN= or SERVER_NAME="
            continue
        fi

        if [ -z "${PORT:-}" ]; then
            log "skip $f: PORT= required"
            continue
        fi

        local uphost="${UPSTREAM_HOST:-host.docker.internal}"
        local u
        u="$(upsafe "$fqdn")"

        cat >>"$tmp" <<NGX
upstream backend_${u} {
    server ${uphost}:${PORT};
}

NGX

        if cert_exists "$fqdn"; then
            cat >>"$tmp" <<NGX
server {
    listen 80;
    server_name ${fqdn};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
    }

    location /ws {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${fqdn};

    ssl_certificate     ${LE_LIVE}/${fqdn}/fullchain.pem;
    ssl_certificate_key ${LE_LIVE}/${fqdn}/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    location = / {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /api/ {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /ws {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    # SPA (Vite/Vue/React): бандлы и иконки; иначе location / отдаёт 403
    location /assets/ {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location = /favicon.ico {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location = /robots.txt {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location = /index.html {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location = /healthz {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    # Один сегмент пути + расширение: /logo.png, /styles.css, /app.js, manifest.webmanifest
    location ~* ^/[^/]+\.(png|jpg|jpeg|gif|svg|webp|ico|woff2?|ttf|eot|map|webmanifest|json|css|js)\$ {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

NGX
            if [ "${FULL_PROXY:-0}" = "1" ]; then
                cat >>"$tmp" <<NGX
    location / {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }
}

NGX
            else
                cat >>"$tmp" <<NGX
    location / {
        return 403;
    }
}

NGX
            fi
        else
            log "no cert yet for $fqdn — HTTP only until certbot succeeds"
            cat >>"$tmp" <<NGX
server {
    listen 80;
    server_name ${fqdn};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
    }

    location /ws {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location = / {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /api/ {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location / {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }
}

NGX
        fi

        unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
    done

    mv -f "$tmp" "$out"
}

issue_missing_certs() {
    shopt -s nullglob
    local files=( "$VHOST_DIR"/*.vhost )
    shopt -u nullglob
    [ "${#files[@]}" -eq 0 ] && return 0

    local need_issue=0
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        local fqdn=""
        if [ -n "${SERVER_NAME:-}" ]; then
            fqdn="$SERVER_NAME"
        elif [ -n "${SUBDOMAIN:-}" ]; then
            fqdn="${SUBDOMAIN}.${BASE_DOMAIN}"
        fi
        if [ -n "${PORT:-}" ] && [ -n "$fqdn" ] && ! cert_exists "$fqdn"; then
            need_issue=1
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
            break
        fi
        unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
    done

    [ "$need_issue" -eq 0 ] && return 0
    require_email

    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        local fqdn=""
        if [ -n "${SERVER_NAME:-}" ]; then
            fqdn="$SERVER_NAME"
        elif [ -n "${SUBDOMAIN:-}" ]; then
            fqdn="${SUBDOMAIN}.${BASE_DOMAIN}"
        else
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
            continue
        fi
        if [ -z "${PORT:-}" ]; then
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
            continue
        fi
        if cert_exists "$fqdn"; then
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
            continue
        fi
        log "requesting certificate for $fqdn"
        if certbot certonly \
            --webroot -w "$WEBROOT" \
            -d "$fqdn" \
            --email "$LE_EMAIL" \
            --agree-tos \
            --non-interactive \
            --keep-until-expiring \
            "${LE_STAGING_FLAG[@]}"; then
            log "certificate obtained for $fqdn"
        else
            log "certbot failed for $fqdn (HTTP-only until fixed)"
        fi
        unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY
    done
}

install_cron_renew() {
    mkdir -p /etc/crontabs
    printf '%s\n' \
        "0 */12 * * * certbot renew --webroot -w ${WEBROOT} -q && nginx -s reload 2>/dev/null || true" \
        >/etc/crontabs/root
    chmod 600 /etc/crontabs/root
}

bootstrap() {
    mkdir -p "$WEBROOT" "$GEN_DIR"
    render_vhosts
    nginx -t

    /usr/sbin/nginx
    sleep 1

    issue_missing_certs
    render_vhosts
    nginx -t
    nginx -s reload

    certbot renew --webroot -w "$WEBROOT" --quiet || true

    nginx -s quit
    sleep 0.5
}

trap 'nginx -s quit 2>/dev/null || true' EXIT

bootstrap
trap - EXIT

install_cron_renew
crond

log "crond: certbot renew every 12h + nginx reload"

exec "$@"
