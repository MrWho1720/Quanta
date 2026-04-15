#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

QUANTA_BINARY=/usr/local/bin/quanta
QUANTA_SERVICE=/etc/systemd/system/quanta.service
QUANTA_CONF_DIR=/etc/quantum
QUANTA_DATA_DIR=/var/lib/quantum
QUANTA_LOG_DIR=/var/log/quantum

print_banner() {
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

separator() {
    echo -e "${BLUE}================================================================${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root.${NC}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}Unsupported OS. Requires Ubuntu, Debian, CentOS, AlmaLinux, or Rocky Linux.${NC}"
        exit 1
    fi
}

pkg_install() {
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -y
        apt-get install -y "$@"
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
        dnf install -y "$@"
    fi
}

install_docker() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q "docker.service"; then
        echo -e "${YELLOW}Installing Docker...${NC}"
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    fi
    echo -e "${YELLOW}Enabling and starting Docker...${NC}"
    systemctl enable --now docker || {
        echo -e "${RED}Failed to start Docker.${NC}"
        exit 1
    }
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
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
    fi
}

install_quanta_binary() {
    detect_arch

    echo -e "${CYAN}How do you want to install Quanta?${NC}"
    echo "  1) Download latest release from GitHub  (recommended)"
    echo "  2) Use local binary in current directory"
    echo "  3) Compile from source (requires Go + quanta source)"
    read -rp "Select (1/2/3): " METHOD

    case "$METHOD" in
        1)
            echo -e "${YELLOW}Downloading from: $QUANTA_DOWNLOAD_URL${NC}"
            if ! curl -L -f -o "$QUANTA_BINARY" "$QUANTA_DOWNLOAD_URL"; then
                echo -e "${RED}Download failed.${NC}"
                exit 1
            fi
            chmod +x "$QUANTA_BINARY"
            ;;
        2)
            if [ -f "./$QUANTA_ARCH_BINARY" ]; then
                cp "./$QUANTA_ARCH_BINARY" "$QUANTA_BINARY"
                chmod +x "$QUANTA_BINARY"
            else
                echo -e "${RED}File ./$QUANTA_ARCH_BINARY not found.${NC}"
                exit 1
            fi
            ;;
        3)
            if ! command -v go &>/dev/null; then
                echo -e "${YELLOW}Installing Go...${NC}"
                GO_VERSION="1.22.3"
                curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "/tmp/go.tar.gz"
                rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
                rm /tmp/go.tar.gz
                export PATH=$PATH:/usr/local/go/bin
                echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
            fi
            SOURCE_DIR="../quanta"
            if [ ! -f "$SOURCE_DIR/quanta.go" ]; then
                read -rp "Path to quanta source directory: " SOURCE_DIR
            fi
            if [ ! -f "$SOURCE_DIR/quanta.go" ]; then
                echo -e "${RED}quanta.go not found at $SOURCE_DIR${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Building from source...${NC}"
            (cd "$SOURCE_DIR" && CGO_ENABLED=0 go build -o quanta quanta.go)
            mv "$SOURCE_DIR/quanta" "$QUANTA_BINARY"
            chmod +x "$QUANTA_BINARY"
            ;;
        *)
            echo -e "${RED}Invalid selection.${NC}"
            exit 1
            ;;
    esac

    echo -e "${GREEN}Quanta binary installed to $QUANTA_BINARY${NC}"
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

install_quanta() {
    separator
    echo -e "${GREEN}${BOLD}           Quanta (Wings) Installation           ${NC}"
    separator

    pkg_install curl git unzip tar
    install_docker

    mkdir -p "$QUANTA_CONF_DIR" "$QUANTA_DATA_DIR/volumes" "$QUANTA_LOG_DIR" "$QUANTA_CONF_DIR/certs"

    install_quanta_binary

    if command -v ufw &> /dev/null; then
        echo -e "${YELLOW}Configuring firewall (UFW)...${NC}"
        ufw allow 8080/tcp
        ufw allow 2022/tcp
    fi

    read -rp "Create systemd service for Quanta? (Y/n) [Y]: " CREATE_SVC
    CREATE_SVC=${CREATE_SVC:-Y}
    if [[ "$CREATE_SVC" =~ ^[Yy]$ ]]; then
        write_quanta_service
        systemctl enable quanta
        echo -e "${GREEN}Service 'quanta' created and enabled.${NC}"
        echo -e "${CYAN}Configure Quanta at $QUANTA_CONF_DIR/config.yml then: systemctl start quanta${NC}"
    fi

    separator
    echo -e "${GREEN}Quanta installation complete.${NC}"
    separator
}

upgrade_quanta() {
    separator
    echo -e "${YELLOW}${BOLD}           Quanta (Wings) Upgrade            ${NC}"
    separator

    if [ ! -f "$QUANTA_BINARY" ]; then
        echo -e "${RED}Quanta is not installed. Run Install first.${NC}"
        return
    fi

    RUNNING=false
    if systemctl is-active --quiet quanta; then
        RUNNING=true
        echo -e "${YELLOW}Stopping Quanta service...${NC}"
        systemctl stop quanta
    fi

    echo -e "${YELLOW}Replacing Quanta binary...${NC}"
    install_quanta_binary

    if systemctl is-enabled --quiet quanta 2>/dev/null; then
        write_quanta_service
        if $RUNNING; then
            systemctl start quanta
            echo -e "${GREEN}Quanta restarted.${NC}"
        else
            echo -e "${CYAN}Start with: systemctl start quanta${NC}"
        fi
    fi

    separator
    echo -e "${GREEN}Quanta upgrade complete.${NC}"
    separator
}

uninstall_quanta() {
    separator
    echo -e "${RED}${BOLD}           Quanta (Wings) Uninstallation         ${NC}"
    separator
    echo -e "${RED}WARNING: This will fully remove Quanta from this system.${NC}"
    read -rp "Type 'yes' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted."
        return
    fi

    echo -e "${YELLOW}Stopping and disabling Quanta service...${NC}"
    systemctl stop quanta 2>/dev/null || true
    systemctl disable quanta 2>/dev/null || true
    rm -f "$QUANTA_SERVICE"
    systemctl daemon-reload

    echo -e "${YELLOW}Stopping Quanta-managed containers...${NC}"
    docker stop $(docker ps -a -q --filter "label=quanta=true" 2>/dev/null) 2>/dev/null || true
    docker rm $(docker ps -a -q --filter "label=quanta=true" 2>/dev/null) 2>/dev/null || true

    echo -e "${YELLOW}Removing Quanta binary...${NC}"
    rm -f "$QUANTA_BINARY"

    read -rp "Purge ALL Quanta data (configs, volumes, logs)? ALL SERVER DATA WILL BE LOST. Type 'purge' to confirm: " PURGE
    if [[ "$PURGE" == "purge" ]]; then
        echo -e "${RED}Purging all Quanta data...${NC}"
        rm -rf "$QUANTA_CONF_DIR" "$QUANTA_DATA_DIR" "$QUANTA_LOG_DIR"
        echo -e "${GREEN}All Quanta data purged.${NC}"
    else
        echo -e "${CYAN}Data preserved at $QUANTA_CONF_DIR, $QUANTA_DATA_DIR, $QUANTA_LOG_DIR${NC}"
    fi

    separator
    echo -e "${GREEN}Quanta uninstalled.${NC}"
    separator
}

show_menu() {
    clear
    print_banner
    separator
    echo -e "${GREEN}${BOLD}           Quanta (Wings) Installer              ${NC}"
    separator
    echo ""
    echo "  1) Install   Quanta"
    echo "  2) Upgrade   Quanta"
    echo "  3) Uninstall Quanta"
    echo "  4) Exit"
    echo ""
    read -rp "Option (1-4): " OPTION

    case "$OPTION" in
        1) detect_os; install_quanta ;;
        2) detect_os; upgrade_quanta ;;
        3) uninstall_quanta ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 2; show_menu ;;
    esac
}

check_root
show_menu
