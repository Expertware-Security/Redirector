#!/usr/bin/env bash
# redirector-setup.sh
# Interactive setup for an Apache2 or Nginx reverse-proxy redirector.
# Listens on HTTP + HTTPS (self-signed). Two modes:
#   catchall  - every URI is proxied to the backend
#   targeted  - only requests matching the allowed path prefixes (and the
#               optional User-Agent allowlist) are proxied; everything else 404.

set -euo pipefail

C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
ask()  { printf '%s[?]%s %s' "$C_C" "$C_0" "$*"; }

prompt_str() {
    local __v="$1" __t="$2" __d="${3:-}" __i
    if [[ -n "$__d" ]]; then ask "$__t [$__d]: "; else ask "$__t: "; fi
    read -r __i || __i=""
    [[ -z "$__i" && -n "$__d" ]] && __i="$__d"
    printf -v "$__v" '%s' "$__i"
}

prompt_choice() {
    local __v="$1" __t="$2" __d="$3"; shift 3
    local __opts=("$@") __i __ok
    while true; do
        prompt_str "$__v" "$__t (${__opts[*]})" "$__d"
        __i="${!__v}"; __ok=0
        for o in "${__opts[@]}"; do [[ "$__i" == "$o" ]] && { __ok=1; break; }; done
        ((__ok)) && return
        err "Choose one of: ${__opts[*]}"
    done
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }

printf '\n%s== Redirector setup ==%s\n\n' "$C_C" "$C_0"

prompt_choice WEBSERVER "Web server" "nginx" "apache2" "nginx"

while true; do
    prompt_str BACKEND_URL "Backend URL (http://host[:port] or https://host[:port])" ""
    if [[ "$BACKEND_URL" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?/?$ ]]; then
        BACKEND_URL="${BACKEND_URL%/}"
        break
    fi
    err "Invalid URL (must be scheme://host[:port], no path)."
done
BACKEND_SCHEME="${BACKEND_URL%%://*}"
# Hostname (no scheme, no port, no path) for the upstream Host header and SNI.
# Without this, the client's Host header is forwarded and CDN-fronted backends
# (Cloudflare, etc.) answer 421 Misdirected Request because Host != SNI.
BACKEND_HOST="${BACKEND_URL#*://}"
BACKEND_HOST="${BACKEND_HOST%%/*}"
BACKEND_HOST="${BACKEND_HOST%%:*}"

prompt_str SERVER_NAME "ServerName / cert CN" "redirector.local"
prompt_str HTTP_PORT   "HTTP listen port"  "80"
prompt_str HTTPS_PORT  "HTTPS listen port" "443"
prompt_choice MODE     "Mode" "targeted" "catchall" "targeted"

ALLOWED_PATHS=""; UA_ALLOWLIST=""
if [[ "$MODE" == "targeted" ]]; then
    prompt_str ALLOWED_PATHS "Allowed path prefixes (comma-separated, e.g. /api,/health)" "/api"
    prompt_str UA_ALLOWLIST  "User-Agent allowlist substrings (comma-separated, empty = no filter)" ""
fi

NORMALIZED_PATHS=()
IFS=',' read -ra _paths <<< "$ALLOWED_PATHS"
for p in "${_paths[@]}"; do
    p="${p// /}"; [[ -z "$p" ]] && continue
    [[ "$p" == /* ]] || p="/$p"
    p="${p%/}"; [[ -z "$p" ]] && continue
    NORMALIZED_PATHS+=("$p")
done

NORMALIZED_UAS=()
IFS=',' read -ra _uas <<< "$UA_ALLOWLIST"
for u in "${_uas[@]}"; do
    u="${u## }"; u="${u%% }"
    [[ -z "$u" ]] && continue
    NORMALIZED_UAS+=("$u")
done

if [[ "$MODE" == "targeted" && ${#NORMALIZED_PATHS[@]} -eq 0 ]]; then
    err "Targeted mode requires at least one allowed path."
    exit 1
fi

apt_install() {
    log "Installing: $*"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}
command -v openssl >/dev/null 2>&1 || apt_install openssl
case "$WEBSERVER" in
    apache2) command -v apache2 >/dev/null 2>&1 || apt_install apache2 ;;
    nginx)   command -v nginx   >/dev/null 2>&1 || apt_install nginx   ;;
esac

CERT_DIR="/etc/ssl/redirector"
CERT_CRT="$CERT_DIR/redirector.crt"
CERT_KEY="$CERT_DIR/redirector.key"
mkdir -p "$CERT_DIR"
if [[ ! -s "$CERT_CRT" || ! -s "$CERT_KEY" ]]; then
    log "Generating self-signed cert for $SERVER_NAME"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$CERT_KEY" -out "$CERT_CRT" -days 3650 \
        -subj "/CN=$SERVER_NAME" 2>/dev/null
    chmod 600 "$CERT_KEY"
    chmod 644 "$CERT_CRT"
fi

regex_escape_alt() {
    local out="" first=1
    for v in "$@"; do
        local esc; esc=$(printf '%s' "$v" | sed -e 's/[]$*.^|[(){}+?\\]/\\&/g')
        if ((first)); then out="$esc"; first=0; else out="$out|$esc"; fi
    done
    printf '%s' "$out"
}

write_apache_config() {
    local conf="/etc/apache2/sites-available/redirector.conf"
    local proxy_ssl=""
    if [[ "$BACKEND_SCHEME" == "https" ]]; then
        proxy_ssl="    SSLProxyEngine on
    SSLProxyVerify none
    SSLProxyCheckPeerCN off
    SSLProxyCheckPeerName off
    SSLProxyCheckPeerExpire off
"
    fi

    local body
    if [[ "$MODE" == "catchall" ]]; then
        body="    ProxyRequests Off
    # Off: Apache rewrites Host to the backend hostname from ProxyPass.
    # Required for CDN-fronted backends (Cloudflare etc.) where Host must match SNI.
    ProxyPreserveHost Off
$proxy_ssl    ProxyPass        / ${BACKEND_URL}/
    ProxyPassReverse / ${BACKEND_URL}/
"
    else
        local stripped=()
        for p in "${NORMALIZED_PATHS[@]}"; do stripped+=("${p#/}"); done
        local path_alt; path_alt=$(regex_escape_alt "${stripped[@]}")
        local ua_block=""
        if ((${#NORMALIZED_UAS[@]} > 0)); then
            local ua_alt; ua_alt=$(regex_escape_alt "${NORMALIZED_UAS[@]}")
            ua_block="    # User-Agent allowlist
    RewriteCond %{HTTP_USER_AGENT} !($ua_alt) [NC]
    RewriteRule .* - [R=404,L]
"
        fi
        body="    ProxyRequests Off
    # Off: Apache rewrites Host to the backend hostname from ProxyPass.
    # Required for CDN-fronted backends (Cloudflare etc.) where Host must match SNI.
    ProxyPreserveHost Off
$proxy_ssl    RewriteEngine On
$ua_block    # Proxy allowed paths to backend, preserving the original path
    RewriteRule ^/($path_alt)(/.*)?\$ ${BACKEND_URL}/\$1\$2 [P,L]

    # Everything else -> 404
    RewriteRule .* - [R=404,L]
"
    fi

    cat >"$conf" <<EOF
# Generated by redirector-setup.sh

<VirtualHost *:${HTTP_PORT}>
    ServerName ${SERVER_NAME}
    DocumentRoot /var/www/html
${body}
    ErrorLog \${APACHE_LOG_DIR}/redirector_error.log
    CustomLog \${APACHE_LOG_DIR}/redirector_access.log combined
</VirtualHost>

<VirtualHost *:${HTTPS_PORT}>
    ServerName ${SERVER_NAME}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile ${CERT_CRT}
    SSLCertificateKeyFile ${CERT_KEY}

${body}
    ErrorLog \${APACHE_LOG_DIR}/redirector_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/redirector_ssl_access.log combined
</VirtualHost>
EOF

    cat >/etc/apache2/ports.conf <<EOF
Listen ${HTTP_PORT}
<IfModule ssl_module>
    Listen ${HTTPS_PORT}
</IfModule>
<IfModule mod_gnutls.c>
    Listen ${HTTPS_PORT}
</IfModule>
EOF

    a2enmod -q proxy proxy_http rewrite ssl headers >/dev/null
    a2dissite -q 000-default 2>/dev/null || true
    a2dissite -q default-ssl 2>/dev/null || true
    a2ensite -q redirector >/dev/null
}

write_nginx_config() {
    local conf="/etc/nginx/sites-available/redirector"
    local link="/etc/nginx/sites-enabled/redirector"

    # Host header and SNI must point at the backend hostname, not at the
    # client's Host, otherwise CDN-fronted backends (Cloudflare etc.) reply
    # 421 Misdirected Request when Host and SNI disagree.
    local proxy_common="        proxy_http_version 1.1;
        proxy_set_header Host ${BACKEND_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name ${BACKEND_HOST};"

    local ua_map="" ua_check=""
    if ((${#NORMALIZED_UAS[@]} > 0)); then
        local ua_alt; ua_alt=$(regex_escape_alt "${NORMALIZED_UAS[@]}")
        ua_map="map \$http_user_agent \$redir_ua_ok {
    default 0;
    \"~*($ua_alt)\" 1;
}
"
        ua_check='        if ($redir_ua_ok = 0) { return 404; }
'
    fi

    local body
    if [[ "$MODE" == "catchall" ]]; then
        body="    location / {
$ua_check        proxy_pass ${BACKEND_URL};
$proxy_common
    }"
    else
        local stripped=()
        for p in "${NORMALIZED_PATHS[@]}"; do stripped+=("${p#/}"); done
        local path_alt; path_alt=$(regex_escape_alt "${stripped[@]}")
        body="    location ~ ^/($path_alt)(/|\$) {
$ua_check        proxy_pass ${BACKEND_URL};
$proxy_common
    }

    location / {
        return 404;
    }"
    fi

    cat >"$conf" <<EOF
# Generated by redirector-setup.sh

${ua_map}
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${SERVER_NAME};

${body}
}

server {
    listen ${HTTPS_PORT} ssl;
    listen [::]:${HTTPS_PORT} ssl;
    server_name ${SERVER_NAME};

    ssl_certificate     ${CERT_CRT};
    ssl_certificate_key ${CERT_KEY};

${body}
}
EOF

    ln -sf "$conf" "$link"
    rm -f /etc/nginx/sites-enabled/default
}

restart_server() {
    local svc="$1"
    if [[ -d /run/systemd/system ]]; then
        systemctl restart "$svc"
    else
        case "$svc" in
            apache2)
                pkill -x apache2 2>/dev/null || true
                sleep 1
                apache2ctl start
                ;;
            nginx)
                if pgrep -x nginx >/dev/null 2>&1; then nginx -s reload
                else nginx; fi
                ;;
        esac
    fi
}

case "$WEBSERVER" in
    apache2)
        write_apache_config
        log "Validating Apache config..."
        apache2ctl -t
        log "Restarting Apache..."
        restart_server apache2
        ;;
    nginx)
        write_nginx_config
        log "Validating Nginx config..."
        nginx -t
        log "Restarting Nginx..."
        restart_server nginx
        ;;
esac

printf '\n%s== Redirector active ==%s\n' "$C_G" "$C_0"
printf '  Web server : %s\n' "$WEBSERVER"
printf '  Listening  : :%s (HTTP), :%s (HTTPS, self-signed)\n' "$HTTP_PORT" "$HTTPS_PORT"
printf '  Backend    : %s\n' "$BACKEND_URL"
printf '  Mode       : %s\n' "$MODE"
if [[ "$MODE" == "targeted" ]]; then
    printf '  Allowed    : %s\n' "${NORMALIZED_PATHS[*]}"
    if ((${#NORMALIZED_UAS[@]} > 0)); then
        printf '  UA filter  : %s\n' "${NORMALIZED_UAS[*]}"
    else
        printf '  UA filter  : (none)\n'
    fi
fi
printf '  Cert       : %s\n\n' "$CERT_CRT"
