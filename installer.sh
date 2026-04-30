#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

QUANTA_BINARY=/usr/local/bin/quanta
QUANTA_SERVICE=/etc/systemd/system/quanta.service
QUANTA_CONF_DIR=/etc/quantum
QUANTA_DATA_DIR=/var/lib/quantum
QUANTA_LOG_DIR=/var/log/quantum

PANEL_SERVICE=/etc/systemd/system/quantum.service
PANEL_WRAPPER=/usr/local/bin/quantum-panel
PANEL_DEFAULT_DIR="$(dirname "$(readlink -f "$0")")"

# ─── Helpers ─────────────────────────────────────────────────────────────────

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "    ██████                                     █████                              "
    echo "  ███░░░░███                                  ░░███                               "
    echo " ███    ░░███ █████ ████  ██████   ████████   ███████   █████ ████ █████████████  "
    echo "░███     ░███░░███ ░███  ░░░░░███ ░░███░░███ ░░░███░   ░░███ ░███ ░░███░░███░░███ "
    echo "░███   ██░███ ░███ ░███   ███████  ░███ ░███   ░███     ░███ ░███  ░███ ░███ ░███ "
    echo "░░███ ░░████  ░███ ░███  ███░░███  ░███ ░███   ░███ ███ ░███ ░███  ░███ ░███ ░███ "
    echo " ░░░██████░██ ░░████████░░████████ ████ █████  ░░█████  ░░████████ █████░███ █████"
    echo "   ░░░░░░ ░░   ░░░░░░░░  ░░░░░░░░ ░░░░ ░░░░░    ░░░░░    ░░░░░░░░ ░░░░░ ░░░ ░░░░░"
    echo -e "${NC}"
}

sep() { echo -e "${BLUE}────────────────────────────────────────────────────────────────${NC}"; }
sep_bold() { echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"; }

step() { echo -e "\n${CYAN}${BOLD}  ▶  $1${NC}"; }
ok()   { echo -e "${GREEN}  ✔  $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $1${NC}"; }
err()  { echo -e "${RED}  ✘  $1${NC}"; }
info() { echo -e "${DIM}     $1${NC}"; }

pause() {
    echo ""
    read -rp "$(echo -e "${DIM}  Press Enter to continue...${NC}")"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root."
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        err "Unsupported OS."
        exit 1
    fi
}

pkg_install() {
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -y -qq
        apt-get install -y -qq "$@"
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
        dnf install -y "$@"
    fi
}

# ─── Dependency installers ────────────────────────────────────────────────────

install_docker() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q "docker.service"; then
        step "Installing Docker..."
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    fi
    systemctl enable --now docker || { err "Failed to start Docker."; exit 1; }
    ok "Docker ready."
}

install_node() {
    if ! command -v node &>/dev/null; then
        step "Installing Node.js 18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        pkg_install nodejs
    fi
    ok "Node.js ready."
}

install_bun() {
    if ! command -v bun &>/dev/null; then
        step "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
    fi
    ok "Bun ready."
}

get_bun_path() {
    BUN_PATH=$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")
}

detect_arch() {
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        QUANTA_ARCH_BINARY="quanta_linux_amd64"
        QUANTA_DOWNLOAD_URL="https://github.com/MrWho1720/quanta/releases/latest/download/quanta_linux_amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        QUANTA_ARCH_BINARY="quanta_linux_arm64"
        QUANTA_DOWNLOAD_URL="https://github.com/MrWho1720/quanta/releases/latest/download/quanta_linux_arm64"
    else
        err "Unsupported architecture: $ARCH"; exit 1
    fi
}

# ─── Shared steps ─────────────────────────────────────────────────────────────

step_install_dir() {
    echo ""
    read -rp "  Installation directory [$PANEL_DEFAULT_DIR]: " INSTALL_DIR
    INSTALL_DIR=${INSTALL_DIR:-$PANEL_DEFAULT_DIR}
    mkdir -p "$INSTALL_DIR"
    ok "Directory: $INSTALL_DIR"
}

step_clone_repo() {
    echo ""
    read -rp "  Git repository URL (leave blank to skip): " REPO_URL
    if [ -n "$REPO_URL" ]; then
        step "Cloning repository..."
        git clone "$REPO_URL" "$INSTALL_DIR"
        ok "Repository cloned."
    else
        info "Skipping clone — using files already in $INSTALL_DIR"
    fi
}

step_install_deps() {
    if [ -f "$INSTALL_DIR/package.json" ]; then
        step "Installing dependencies..."
        (cd "$INSTALL_DIR" && "$BUN_PATH" install)
        ok "Dependencies installed."
    fi
}

step_build() {
    if [ -f "$INSTALL_DIR/package.json" ] && grep -q '"build"' "$INSTALL_DIR/package.json"; then
        step "Building application..."
        (cd "$INSTALL_DIR" && DATABASE_URL="$DATABASE_URL" "$BUN_PATH" run build)
        ok "Build complete."
    fi
}

step_configure_database() {
    sep
    echo -e "  ${BOLD}Database Configuration${NC}"
    sep
    echo ""
    echo "   How would you like to set up the database?"
    echo ""
    echo "   1)  Auto-create  — installer creates the PostgreSQL user & database"
    echo "   2)  Manual       — I already have a database, let me enter the details"
    echo ""
    read -rp "  Select (1/2): " DB_SETUP_MODE

    case "$DB_SETUP_MODE" in
        1)
            sep
            echo -e "  ${CYAN}${BOLD}Auto-creating PostgreSQL database${NC}"
            sep
            echo ""

            if ! command -v psql &>/dev/null; then
                step "Installing PostgreSQL..."
                if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
                    pkg_install postgresql postgresql-contrib
                else
                    pkg_install postgresql postgresql-server postgresql-contrib
                    postgresql-setup --initdb 2>/dev/null || true
                fi
                systemctl enable --now postgresql
                ok "PostgreSQL installed and started."
            else
                systemctl enable --now postgresql 2>/dev/null || true
                ok "PostgreSQL already installed."
            fi

            step "Configuring PostgreSQL for TCP connections..."
            PG_CONF=$(sudo -u postgres psql -t -c "SHOW config_file;" 2>/dev/null | tr -d ' ')
            PG_HBA=$(sudo -u postgres psql -t -c "SHOW hba_file;" 2>/dev/null | tr -d ' ')

            if [ -n "$PG_CONF" ]; then
                if grep -q "^#listen_addresses\|^listen_addresses" "$PG_CONF" 2>/dev/null; then
                    sed -i "s|^#*listen_addresses.*|listen_addresses = 'localhost'|" "$PG_CONF"
                else
                    echo "listen_addresses = 'localhost'" >> "$PG_CONF"
                fi
            fi

            if [ -n "$PG_HBA" ]; then
                if ! grep -q "^host.*all.*all.*127.0.0.1" "$PG_HBA" 2>/dev/null; then
                    echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"
                    echo "host    all             all             ::1/128                 scram-sha-256" >> "$PG_HBA"
                fi
            fi

            systemctl restart postgresql
            sleep 2

            DB_PORT=$(sudo -u postgres psql -t -c "SHOW port;" 2>/dev/null | tr -d ' \n' || echo "5432")
            DB_PORT=${DB_PORT:-5432}
            DB_HOST="localhost"
            ok "PostgreSQL listening on port $DB_PORT."

            read -rp "  DB Name [quantum_db]: " DB_NAME;  DB_NAME=${DB_NAME:-quantum_db}
            read -rp "  DB User [quantum]: "   DB_USER;   DB_USER=${DB_USER:-quantum}
            read -rsp "  DB Password (leave blank to auto-generate): " DB_PASSWORD; echo ""
            if [ -z "$DB_PASSWORD" ]; then
                DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
                echo ""
                warn "Generated password: ${BOLD}$DB_PASSWORD${NC}"
                warn "Save this — it will be written to your .env file."
                echo ""
            fi

            step "Creating PostgreSQL role and database..."
            sudo -u postgres psql -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null \
                || sudo -u postgres psql -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';"
            sudo -u postgres psql -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";" 2>/dev/null \
                || warn "Database '${DB_NAME}' may already exist — continuing."
            sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"
            ok "Database '${DB_NAME}' ready for user '${DB_USER}'."
            ;;


        2)
            sep
            echo -e "  ${CYAN}${BOLD}Manual Database Details${NC}"
            sep
            echo ""
            read -rp "  DB Host [localhost]: " DB_HOST;   DB_HOST=${DB_HOST:-localhost}
            read -rp "  DB Port [5432]: "      DB_PORT;   DB_PORT=${DB_PORT:-5432}
            read -rp "  DB Name [quantum_db]: " DB_NAME;  DB_NAME=${DB_NAME:-quantum_db}
            read -rp "  DB User [quantum]: "   DB_USER;   DB_USER=${DB_USER:-quantum}
            read -rsp "  DB Password: "        DB_PASSWORD; echo ""
            ;;

        *)
            err "Invalid selection — defaulting to manual."
            read -rp "  DB Host [localhost]: " DB_HOST;   DB_HOST=${DB_HOST:-localhost}
            read -rp "  DB Port [5432]: "      DB_PORT;   DB_PORT=${DB_PORT:-5432}
            read -rp "  DB Name [quantum_db]: " DB_NAME;  DB_NAME=${DB_NAME:-quantum_db}
            read -rp "  DB User [quantum]: "   DB_USER;   DB_USER=${DB_USER:-quantum}
            read -rsp "  DB Password: "        DB_PASSWORD; echo ""
            ;;
    esac

    local ENV_FILE="$INSTALL_DIR/.env"
    if [ ! -f "$ENV_FILE" ] && [ -f "$INSTALL_DIR/example.env" ]; then
        cp "$INSTALL_DIR/example.env" "$ENV_FILE"
    fi
    touch "$ENV_FILE"

    for KEY in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
        local VALUE="${!KEY}"
        if grep -q "^${KEY}=" "$ENV_FILE" 2>/dev/null; then
            sed -i "s|^${KEY}=.*|${KEY}=\"${VALUE}\"|" "$ENV_FILE"
        else
            echo "${KEY}=\"${VALUE}\"" >> "$ENV_FILE"
        fi
    done

    local DB_PASSWORD_ENC
    DB_PASSWORD_ENC=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASSWORD" 2>/dev/null || printf '%s' "$DB_PASSWORD" | sed 's/%/%25/g;s/@/%40/g;s/:/%3A/g;s/+/%2B/g')
    export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD_ENC}@${DB_HOST}:${DB_PORT}/${DB_NAME}?schema=public"
    ok "Credentials saved to $ENV_FILE"
}

step_prisma_push() {
    if [ -d "$INSTALL_DIR/quantum/prisma" ]; then
        step "Pushing database schema..."
        (cd "$INSTALL_DIR/quantum" && DATABASE_URL="$DATABASE_URL" "$BUN_PATH" x prisma db push)
        ok "Schema pushed."
    fi
}

step_write_panel_services() {
    local BUN_DIR
    BUN_DIR=$(dirname "$BUN_PATH")

    cat > "$PANEL_WRAPPER" << 'WRAPPER'
#!/bin/bash
INSTALL_DIR="__INSTALL_DIR__"
BUN="__BUN_PATH__"

cleanup() {
    kill "$PID_BACKEND" "$PID_FRONTEND" 2>/dev/null
    wait "$PID_BACKEND" "$PID_FRONTEND" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

cd "$INSTALL_DIR"
"$BUN" run start:backend &
PID_BACKEND=$!

"$BUN" run start:frontend &
PID_FRONTEND=$!

wait "$PID_BACKEND" "$PID_FRONTEND"
WRAPPER

    sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g; s|__BUN_PATH__|$BUN_PATH|g" "$PANEL_WRAPPER"
    chmod +x "$PANEL_WRAPPER"

    cat > "$PANEL_SERVICE" <<EOF
[Unit]
Description=Quantum Panel (Backend + Frontend)
After=network.target redis-server.service postgresql.service
Wants=redis-server.service postgresql.service

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
Environment=NODE_ENV=production
Environment=PATH=$BUN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$PANEL_WRAPPER
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=5s
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now quantum
    ok "Service 'quantum' created and started."
}

step_configure_nginx() {
    sep
    echo -e "  ${BOLD}Nginx & SSL Configuration${NC}"
    sep
    echo ""
    read -rp "  Domain (e.g. dashboard.example.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then
        warn "No domain entered — skipping Nginx setup."
        return
    fi

    pkg_install certbot python3-certbot-nginx

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > "/etc/nginx/sites-available/quantum.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /ws {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/quantum.conf /etc/nginx/sites-enabled/quantum.conf
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "admin@$DOMAIN_NAME" || \
        warn "Certbot failed — run it manually: certbot --nginx -d $DOMAIN_NAME"

    local SSL_CERT="/etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem"
    local SSL_KEY="/etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem"

    cat > "/etc/nginx/sites-available/quantum.conf" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    return 444;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;
    return 301 https://$DOMAIN_NAME\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;
    client_max_body_size 50M;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /ws {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }
}
EOF

    nginx -t && systemctl reload nginx
    ok "Nginx configured for $DOMAIN_NAME"
}

# ─── Quanta binary ────────────────────────────────────────────────────────────

install_quanta_binary() {
    detect_arch
    sep
    echo -e "  ${BOLD}Quanta Binary Source${NC}"
    sep
    echo "   1) Download latest release from GitHub  (recommended)"
    echo "   2) Use local binary in current directory"
    echo "   3) Compile from source (requires Go)"
    echo ""
    read -rp "  Select (1/2/3): " METHOD

    case "$METHOD" in
        1)
            step "Downloading from GitHub..."
            if ! curl -L -f -o "$QUANTA_BINARY" "$QUANTA_DOWNLOAD_URL"; then
                err "Download failed."; exit 1
            fi
            chmod +x "$QUANTA_BINARY"
            ;;
        2)
            if [ -f "./$QUANTA_ARCH_BINARY" ]; then
                cp "./$QUANTA_ARCH_BINARY" "$QUANTA_BINARY"
                chmod +x "$QUANTA_BINARY"
            else
                err "File ./$QUANTA_ARCH_BINARY not found."; exit 1
            fi
            ;;
        3)
            if ! command -v go &>/dev/null; then
                step "Installing Go 1.22.3..."
                curl -fsSL "https://go.dev/dl/go1.22.3.linux-amd64.tar.gz" -o "/tmp/go.tar.gz"
                rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz
                export PATH=$PATH:/usr/local/go/bin
                echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
            fi
            SOURCE_DIR="."
            if [ ! -f "$SOURCE_DIR/quanta.go" ]; then
                err "Source not found at $SOURCE_DIR/quanta.go"; exit 1
            fi
            step "Compiling from source..."
            (cd "$SOURCE_DIR" && CGO_ENABLED=0 go build -o quanta quanta.go)
            mv "$SOURCE_DIR/quanta" "$QUANTA_BINARY"
            chmod +x "$QUANTA_BINARY"
            ;;
        *)
            err "Invalid selection."; exit 1 ;;
    esac
    ok "Quanta binary installed to $QUANTA_BINARY"
}

write_quanta_service() {
    cat > "$QUANTA_SERVICE" <<EOF
[Unit]
Description=Quanta Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=$QUANTA_CONF_DIR
LimitNOFILE=4096
PIDFile=/var/run/quantum/daemon.pid
ExecStart=$QUANTA_BINARY
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

step_configure_quanta_ssl() {
    sep
    echo -e "  ${BOLD}Quanta SSL Configuration${NC}"
    sep
    echo ""
    read -rp "  Domain (e.g. node.example.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then
        warn "No domain entered — skipping SSL setup."
        return
    fi

    step "Installing Certbot..."
    pkg_install certbot iproute2

    step "Requesting SSL certificate for $DOMAIN_NAME..."
    
    if ss -tulpn | grep -q ":80 "; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            pkg_install python3-certbot-nginx
            certbot certonly --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "admin@$DOMAIN_NAME" || \
                warn "Certbot failed. Try running manually."
        else
            warn "Port 80 is in use by another application. Stopping it temporarily might be required."
            certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "admin@$DOMAIN_NAME" || \
                warn "Certbot failed. Try running manually."
        fi
    else
        certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "admin@$DOMAIN_NAME" || \
            warn "Certbot failed. Try running manually."
    fi

    local SSL_CERT="/etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem"
    local SSL_KEY="/etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem"

    if [ -f "$SSL_CERT" ]; then
        ok "SSL certificate generated successfully!"
        info "Cert Path: $SSL_CERT"
        info "Key Path:  $SSL_KEY"
    fi
}

# ─── Quanta actions ───────────────────────────────────────────────────────────

quanta_install() {
    print_banner
    sep_bold
    echo -e "  ${GREEN}${BOLD}  Quanta (Wings) Installation  —  Step-by-step Wizard${NC}"
    sep_bold

    step "Layer 1 of 4 — System dependencies"
    pkg_install curl git unzip tar
    install_docker
    pause

    step "Layer 2 of 4 — Quanta binary"
    mkdir -p "$QUANTA_CONF_DIR" "$QUANTA_DATA_DIR/volumes" "$QUANTA_LOG_DIR" "$QUANTA_CONF_DIR/certs"
    install_quanta_binary

    if command -v ufw &>/dev/null; then
        ufw allow 8080/tcp
        ufw allow 2022/tcp
        ok "Firewall rules added (8080, 2022)."
    fi
    pause

    step "Layer 3 of 4 — Systemd service"
    echo ""
    read -rp "  Create and enable systemd service for Quanta? (Y/n) [Y]: " yn
    yn=${yn:-Y}
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        write_quanta_service
        systemctl enable quanta
        ok "Service 'quanta' enabled."
        info "Configure at $QUANTA_CONF_DIR/config.yml then: systemctl start quanta"
    fi
    pause

    step "Layer 4 of 4 — SSL Configuration"
    echo ""
    read -rp "  Configure SSL now? (Y/n) [Y]: " yn
    yn=${yn:-Y}
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        step_configure_quanta_ssl
    else
        info "Skipped — run option 4 from the Wings menu later."
    fi

    sep_bold
    ok "Quanta installation complete!"
    sep_bold
    pause
}

quanta_upgrade() {
    print_banner
    sep_bold
    echo -e "  ${YELLOW}${BOLD}  Quanta (Wings) Upgrade${NC}"
    sep_bold

    if ! command -v quanta &>/dev/null && [ ! -f "$QUANTA_BINARY" ]; then
        err "Quanta is not installed. Use Install instead."; pause; return
    fi

    RUNNING=false
    if systemctl is-active --quiet quanta; then
        RUNNING=true
        step "Stopping Quanta service..."
        systemctl stop quanta
    fi

    install_quanta_binary

    if systemctl is-enabled --quiet quanta 2>/dev/null; then
        write_quanta_service
        if $RUNNING; then
            systemctl start quanta
            ok "Quanta restarted."
        else
            info "Start manually: systemctl start quanta"
        fi
    fi

    sep_bold
    ok "Quanta upgrade complete!"
    sep_bold
    pause
}

quanta_uninstall() {
    print_banner
    sep_bold
    echo -e "  ${RED}${BOLD}  Quanta (Wings) Uninstallation${NC}"
    sep_bold
    warn "This will remove Quanta completely."
    echo ""
    read -rp "  Type 'yes' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then echo "Aborted."; return; fi

    step "Stopping and disabling service..."
    systemctl stop quanta 2>/dev/null || true
    systemctl disable quanta 2>/dev/null || true
    rm -f "$QUANTA_SERVICE"
    systemctl daemon-reload

    step "Stopping Quanta-managed containers..."
    docker stop $(docker ps -a -q --filter "label=quanta=true" 2>/dev/null) 2>/dev/null || true
    docker rm   $(docker ps -a -q --filter "label=quanta=true" 2>/dev/null) 2>/dev/null || true

    rm -f "$QUANTA_BINARY"
    ok "Binary removed."

    echo ""
    read -rp "  Purge ALL data (configs, volumes, logs)? Type 'purge' to confirm: " PURGE
    if [[ "$PURGE" == "purge" ]]; then
        rm -rf "$QUANTA_CONF_DIR" "$QUANTA_DATA_DIR" "$QUANTA_LOG_DIR"
        ok "All Quanta data purged."
    else
        info "Data preserved at $QUANTA_CONF_DIR"
    fi

    sep_bold
    ok "Quanta uninstalled."
    sep_bold
    pause
}

# ─── Sub-menus ────────────────────────────────────────────────────────────────

menu_quanta() {
    while true; do
        print_banner
        sep_bold
        echo -e "  ${CYAN}${BOLD}  Wings (Quanta)${NC}"
        sep_bold
        echo ""
        echo "   1)  Install"
        echo "   2)  Upgrade"
        echo "   3)  Uninstall"
        echo "   4)  Configure SSL only"
        echo ""
        echo "   0)  Exit"
        echo ""
        read -rp "  Option: " OPT
        case "$OPT" in
            1) detect_os; quanta_install ;;
            2) detect_os; quanta_upgrade ;;
            3) quanta_uninstall ;;
            4) detect_os; step_configure_quanta_ssl ;;
            0) exit 0 ;;
            *) warn "Invalid option." ; sleep 1 ;;
        esac
    done
}

check_root
menu_quanta
