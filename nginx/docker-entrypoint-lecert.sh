#!/usr/bin/env bash
set -euo pipefail

VHOST_DIR="${VHOST_DIR:-/data/vhosts}"
GEN_DIR="${GEN_DIR:-/var/lib/nginx/vhosts.d}"
WEBROOT="${WEBROOT:-/var/www/certbot}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"
LE_ETC="${LE_LIVE%/live}"
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

cert_is_usable() {
    local cert="$LE_LIVE/$1/fullchain.pem"
    [ -f "$cert" ] || return 1
    openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1
}

render_vhosts_to() {
    local out="$1"
    mkdir -p "$GEN_DIR"
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
        local port="${PORT}"
        # UPSTREAM_HOST — только IP/hostname; порт задаётся через PORT=
        if [[ "$uphost" == *:* ]]; then
            log "WARN $f: UPSTREAM_HOST must not include :port (use PORT=); using ${uphost%%:*}"
            uphost="${uphost%%:*}"
        fi
        uphost="${uphost#http://}"
        uphost="${uphost#https://}"
        uphost="${uphost%%/*}"
        port="${port#:}"
        if [ -z "$uphost" ]; then
            log "skip $f: UPSTREAM_HOST is empty (host only, no :port)"
            continue
        fi
        local u
        u="$(upsafe "$fqdn")"
        local client_max_body_size_directive=""
        if [ -n "${CLIENT_MAX_BODY_SIZE:-}" ]; then
            client_max_body_size_directive="    client_max_body_size ${CLIENT_MAX_BODY_SIZE};"
        fi

        cat >>"$tmp" <<NGX
upstream backend_${u} {
    server ${uphost}:${port};
}

NGX

        if cert_is_usable "$fqdn"; then
            cat >>"$tmp" <<NGX
server {
    listen 80;
    server_name ${fqdn};
${client_max_body_size_directive}

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

    location = /livekit {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        proxy_buffering off;
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /livekit/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        proxy_buffering off;
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
${client_max_body_size_directive}

    client_header_buffer_size 16k;
    large_client_header_buffers 8 32k;

    ssl_certificate     ${LE_LIVE}/${fqdn}/fullchain.pem;
    ssl_certificate_key ${LE_LIVE}/${fqdn}/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    location = / {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
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

    location = /livekit {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        proxy_buffering off;
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /livekit/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        proxy_buffering off;
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
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }
}

NGX
            elif [ "${FULL_PROXY:-0}" = "2" ]; then
                cat >>"$tmp" <<NGX
    location / {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params-streaming.conf;
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
            log "no usable cert for $fqdn — HTTP only until certbot succeeds"
            cat >>"$tmp" <<NGX
server {
    listen 80;
    server_name ${fqdn};
${client_max_body_size_directive}

    client_header_buffer_size 16k;
    large_client_header_buffers 8 32k;

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

    location = /livekit {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        proxy_buffering off;
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /livekit/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        proxy_buffering off;
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location = / {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location /api/ {
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }

    location / {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://backend_${u};
        include /etc/nginx/snippets/proxy-params.conf;
    }
}

NGX
        fi

        unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
    done

    mv -f "$tmp" "$out"
}

render_vhosts() {
    render_vhosts_to "$GEN_DIR/generated-vhosts.conf"
}

apply_vhosts_config() {
    local out="$GEN_DIR/generated-vhosts.conf"
    local candidate="$GEN_DIR/generated-vhosts.conf.candidate"
    local backup="$GEN_DIR/generated-vhosts.conf.backup"

    render_vhosts_to "$candidate"

    if [ -f "$out" ]; then
        cp -f "$out" "$backup"
    else
        rm -f "$backup"
    fi

    mv -f "$candidate" "$out"

    if nginx -t; then
        rm -f "$backup"
        return 0
    fi

    log "nginx -t failed after vhost update; restoring previous generated config"
    if [ -f "$backup" ]; then
        mv -f "$backup" "$out"
    else
        rm -f "$out"
    fi
    rm -f "$candidate"
    return 1
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
        if [ -n "${PORT:-}" ] && [ -n "$fqdn" ] && ! cert_is_usable "$fqdn"; then
            need_issue=1
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
            break
        fi
        unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
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
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
            continue
        fi
        if [ -z "${PORT:-}" ]; then
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
            continue
        fi
        if cert_is_usable "$fqdn"; then
            unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
            continue
        fi
        log "requesting or renewing certificate for $fqdn"
        if certbot certonly \
            --webroot -w "$WEBROOT" \
            --cert-name "$fqdn" \
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
        unset SUBDOMAIN SERVER_NAME PORT UPSTREAM_HOST FULL_PROXY CLIENT_MAX_BODY_SIZE
    done
}

repair_imported_letsencrypt_layout() {
    [ -d "$LE_LIVE" ] || return 0

    local live_dir
    shopt -s nullglob
    for live_dir in "$LE_LIVE"/*; do
        [ -d "$live_dir" ] || continue
        local domain
        domain="$(basename "$live_dir")"
        local needs_repair=0
        local name
        for name in cert chain fullchain privkey; do
            local pem="$live_dir/$name.pem"
            if [ -f "$pem" ] && [ ! -L "$pem" ]; then
                needs_repair=1
            fi
        done

        [ "$needs_repair" -eq 1 ] || continue

        local archive_dir="$LE_ETC/archive/$domain"
        mkdir -p "$archive_dir"

        local version=1
        if ls "$archive_dir"/cert*.pem >/dev/null 2>&1; then
            version="$(
                find "$archive_dir" -maxdepth 1 -type f -name 'cert*.pem' \
                    | sed -E 's|.*/cert([0-9]+)\.pem$|\1|' \
                    | sort -n \
                    | tail -n 1
            )"
            version=$((version + 1))
        fi

        log "repairing imported Let's Encrypt layout for $domain"

        for name in cert chain fullchain privkey; do
            local live_pem="$live_dir/$name.pem"
            [ -f "$live_pem" ] || continue

            local archive_pem="$archive_dir/${name}${version}.pem"
            if [ ! -f "$archive_pem" ]; then
                cp -f "$live_pem" "$archive_pem"
            fi

            rm -f "$live_pem"
            ln -s "../../archive/$domain/${name}${version}.pem" "$live_pem"
        done
    done
    shopt -u nullglob
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
    repair_imported_letsencrypt_layout
    apply_vhosts_config

    /usr/sbin/nginx
    sleep 1

    issue_missing_certs
    apply_vhosts_config
    nginx -s reload

    certbot renew --webroot -w "$WEBROOT" --quiet || true

    nginx -s quit
    sleep 0.5
}

if [ "${LECERT_SOURCE_ONLY:-0}" != "1" ]; then
    trap 'nginx -s quit 2>/dev/null || true' EXIT

    bootstrap
    trap - EXIT

    install_cron_renew
    crond

    log "crond: certbot renew every 12h + nginx reload"

    exec "$@"
fi
