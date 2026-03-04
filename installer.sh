#!/bin/bash
# Quanta (Wings Node) Standalone Installation Script
set -e

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}"
echo "    ██████                                     █████                              "
echo "  ███░░░░███                                  ░░███                               "
echo " ███    ░░███ █████ ████  ██████   ████████   ███████   █████ ████ █████████████  "
echo "░███     ░███░░███ ░███  ░░░░░███ ░░███░░███ ░░░███░   ░░███ ░███ ░░███░░███░░███ "
echo "░███   ██░███ ░███ ░███   ███████  ░███ ░███   ░███     ░███ ░███  ░███ ░███ ░███ "
echo "░░███ ░░████  ░███ ░███  ███░░███  ░███ ░███   ░███ ███ ░███ ░███  ░███ ░███ ░███ "
echo " ░░░██████░██ ░░████████░░████████ ████ █████  ░░█████  ░░████████ █████░███ █████"
echo "   ░░░░░░ ░░   ░░░░░░░░  ░░░░░░░░ ░░░░ ░░░░░    ░░░░░    ░░░░░░░░ ░░░░░ ░░░ ░░░░░ "
echo -e "${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}                  Quanta Node Installation Script               ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root. Please use sudo or log in as root.${NC}" 
   exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}Unsupported Operating System. This script requires Ubuntu, Debian, CentOS, AlmaLinux, or Rocky Linux.${NC}"
    exit 1
fi

echo -e "${YELLOW}Installing Docker and dependencies...${NC}"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -y
    apt-get install -y curl git unzip tar
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
    dnf install -y curl git unzip tar
fi

# Install Docker if not present or service missing
if ! systemctl list-unit-files | grep -q "docker.service"; then
    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
fi

# Enable and start Docker unconditionally
echo -e "${YELLOW}Enabling and starting Docker service...${NC}"
systemctl enable --now docker || {
    echo -e "${RED}Failed to enable/start docker service. Please check your Docker installation.${NC}"
    exit 1
}

echo -e "${YELLOW}Migrating old data directories if present...${NC}"
systemctl stop quanta 2>/dev/null || true
docker stop $(docker ps -a -q --filter "label=quanta=true" 2>/dev/null) 2>/dev/null || true

mkdir -p /etc/quantum /var/lib/quantum/volumes /var/log/quantum /etc/quantum/certs

if [ -d /var/lib/quanta/volumes ]; then
    mv /var/lib/quanta/volumes/* /var/lib/quantum/volumes/ 2>/dev/null || true
fi
if [ -d /home/quantum/quanta_data/volumes ]; then
    mv /home/quantum/quanta_data/volumes/* /var/lib/quantum/volumes/ 2>/dev/null || true
fi
if [ -d /etc/quanta ]; then
    mv /etc/quanta/* /etc/quantum/ 2>/dev/null || true
fi

rm -rf /var/lib/quanta /home/quantum/quanta_data /etc/quanta

echo -e "${YELLOW}Setting up Quanta...${NC}"

# Detect Architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    LOCAL_BINARY="quanta_linux_amd64"
    DOWNLOAD_URL="https://github.com/MrWho1720/quanta/releases/latest/download/quanta_linux_amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    LOCAL_BINARY="quanta_linux_arm64"
    DOWNLOAD_URL="https://github.com/MrWho1720/quanta/releases/latest/download/quanta_linux_arm64"
else
    echo -e "${RED}Unsupported Architecture: $ARCH${NC}"
    exit 1
fi

# Optional: You can change DOWNLOAD_URL here to match your preferred hosting provider 
# if you do not want to use GitHub. Example: DOWNLOAD_URL="https://example.com/$LOCAL_BINARY"

echo -e "${CYAN}How do you want to install the Quanta binary?${NC}"
echo "  1) Download automatically from GitHub (Recommended)"
echo "  2) Copy from a local file ($LOCAL_BINARY) in this directory"
echo "  3) Compile from source using Go (Requires 'quanta' folder here)"
read -p "Select method (1/2/3): " INSTALL_METHOD

if [[ "$INSTALL_METHOD" == "1" ]]; then
    echo -e "${YELLOW}Downloading Quanta from: $DOWNLOAD_URL${NC}"
    # Download binary with failure detection (-f flag for curl)
    if curl -L -f -o /usr/local/bin/quanta "$DOWNLOAD_URL"; then
        chmod +x /usr/local/bin/quanta
        echo -e "${GREEN}Quanta downloaded and installed successfully to /usr/local/bin/quanta${NC}"
    else
        echo -e "${RED}Failed to download Quanta binary! Are you sure the GitHub repository exists and the release is public?${NC}"
        exit 1
    fi

elif [[ "$INSTALL_METHOD" == "2" ]]; then
    if [ -f "./$LOCAL_BINARY" ]; then
        echo -e "${YELLOW}Found local binary: ./$LOCAL_BINARY. Installing...${NC}"
        cp "./$LOCAL_BINARY" /usr/local/bin/quanta
        chmod +x /usr/local/bin/quanta
        echo -e "${GREEN}Quanta installed successfully to /usr/local/bin/quanta${NC}"
    else
        echo -e "${RED}Could not find ./$LOCAL_BINARY in the current directory. Please upload it and try again.${NC}"
        exit 1
    fi

elif [[ "$INSTALL_METHOD" == "3" ]]; then
    # Install Go
    echo -e "${YELLOW}Installing Go (if not present)...${NC}"
    if ! command -v go &> /dev/null; then
        GO_VERSION="1.21.6"
        curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -o go${GO_VERSION}.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
        rm go${GO_VERSION}.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.profile
    fi

    if command -v go &> /dev/null && [ -d "./quanta" ] && [ -f "./quanta/quanta.go" ]; then
        echo -e "${YELLOW}Building Quanta from source...${NC}"
        cd ./quanta
        go build -v -o quanta quanta.go
        mv quanta /usr/local/bin/quanta
        chmod +x /usr/local/bin/quanta
        cd - > /dev/null
        echo -e "${GREEN}Quanta compiled and installed successfully to /usr/local/bin/quanta${NC}"
    else
        echo -e "${RED}Failed to build Quanta! Please ensure the 'quanta' folder exists in this directory and contains 'quanta.go'.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Invalid selection. Aborting.${NC}"
    exit 1
fi

read -p "Create systemd service for Quanta? (y/n) [y]: " CREATE_SVC
CREATE_SVC=${CREATE_SVC:-y}

if [[ "$CREATE_SVC" =~ ^[Yy]$ ]]; then
    cat <<EOF > /etc/systemd/system/quanta.service
[Unit]
Description=Quanta Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/quantum
LimitNOFILE=4096
PIDFile=/var/run/quantum/daemon.pid
ExecStart=/usr/local/bin/quanta
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable quanta
    echo -e "${GREEN}Systemd service 'quanta' created and enabled.${NC}"
    echo -e "${CYAN}Reminder: Quanta is not started yet. You must configure it first (e.g. place config in /etc/quantum/config.yml)${NC}"
fi

echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}Quanta Node Installation script completed successfully!${NC}"
echo -e "${BLUE}================================================================${NC}"
