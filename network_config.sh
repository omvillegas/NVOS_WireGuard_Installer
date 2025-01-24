#!/bin/bash

# Functions to configure WireGuard and network

install_wireguard() {
    print_message "$YELLOW" "Installing WireGuard..."
    apt update
    apt install -y wireguard
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    print_message "$GREEN" "Directory /etc/wireguard created with proper permissions."
    print_message "$GREEN" "WireGuard installed successfully."
}

detect_network_config() {
    INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    SERVER_IP=$(curl -s https://api.ipify.org)
    if [[ -z "$SERVER_IP" ]]; then
        print_message "$RED" "Failed to retrieve the server's public IP."
        exit 1
    fi

    # Generate a random port and ensure it's not in use
    while true; do
        WG_PORT=$(shuf -i 10000-60000 -n 1)
        if ! ss -tunlp | grep -q ":$WG_PORT "; then
            break
        fi
    done

    print_message "$GREEN" "Detected network interface: $INTERFACE"
    print_message "$GREEN" "Detected server IP: $SERVER_IP"
    print_message "$GREEN" "Generated WireGuard port: $WG_PORT"
}

backup_ufw_rules() {
    print_message "$YELLOW" "Backing up UFW rules..."

    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        print_message "$RED" "Error: UFW is not installed. Skipping backup."
        return
    fi

    # Check if UFW is active
    if ! ufw status | grep -q "Status: active"; then
        print_message "$YELLOW" "UFW is not active. No rules to backup."
        return
    fi

    # Backup UFW rules
    if ufw status verbose > /etc/ufw/ufw.rules.backup; then
        print_message "$GREEN" "UFW rules backed up to /etc/ufw/ufw.rules.backup"
    else
        print_message "$RED" "Error: Failed to backup UFW rules."
        exit 1
    fi
}

configure_wireguard_server() {
    print_message "$YELLOW" "Configuring WireGuard server..."

    if [[ ! -d /etc/wireguard ]]; then
        mkdir -p /etc/wireguard
        chmod 700 /etc/wireguard
        if [[ $? -ne 0 ]]; then
            print_message "$RED" "Error: Could not create /etc/wireguard."
            exit 1
        fi
        print_message "$GREEN" "/etc/wireguard created."
    else
        print_message "$GREEN" "/etc/wireguard already exists."
    fi

    detect_network_config

    if [[ -f /etc/wireguard/wg0.conf ]]; then
        print_message "$YELLOW" "wg0.conf exists. Loading configuration."
        SERVER_PRIVATE_KEY=$(grep -i '^PrivateKey' /etc/wireguard/wg0.conf | awk '{print $3}')
        if [[ -z "$SERVER_PRIVATE_KEY" ]]; then
            print_message "$RED" "Error: SERVER_PRIVATE_KEY not found."
            exit 1
        fi
        SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
        WG_PORT=$(grep -i '^ListenPort' /etc/wireguard/wg0.conf | awk '{print $3}')
        SERVER_IP=$(grep -i '^Endpoint' /etc/wireguard/wg0.conf | awk -F':' '{print $1}' | head -n1)
        if [[ -z "$SERVER_IP" ]]; then
            SERVER_IP=$(curl -s https://api.ipify.org)
            if [[ -z "$SERVER_IP" ]]; then
                print_message "$RED" "Error: Could not retrieve public IP."
                exit 1
            fi
        fi
        cat > /etc/wireguard/wg_manager.conf << EOF
SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
SERVER_IP=$SERVER_IP
WG_PORT=$WG_PORT
INTERFACE=$INTERFACE
EOF
        print_message "$GREEN" "WireGuard configuration loaded."
        return
    fi

    SERVER_PRIVATE_KEY=$(wg genkey)
    if [[ -z "$SERVER_PRIVATE_KEY" ]]; then
        print_message "$RED" "Error: Failed to generate private key."
        exit 1
    fi
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
        print_message "$RED" "Error: Failed to generate public key."
        exit 1
    fi

    while true; do
        WG_PORT=$(shuf -i 10000-60000 -n 1)
        if ! ss -tunlp | grep -q ":$WG_PORT "; then
            break
        fi
    done

    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null
    sysctl -p

    umask 077
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
SaveConfig = true
PrivateKey = $SERVER_PRIVATE_KEY
ListenPort = $WG_PORT
EOF

    if ! wg-quick strip wg0 > /dev/null; then
        print_message "$RED" "Error: wg0.conf syntax invalid."
        exit 1
    fi

    if ! command -v nft &>/dev/null; then
        print_message "$YELLOW" "Installing nftables..."
        apt update && apt install -y nftables
    fi

    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl start nftables >/dev/null 2>&1 || true

    cat > /etc/nftables.conf << EOF
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport 22 accept
        udp dport $WG_PORT accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iifname "wg0" ip daddr 172.16.0.0/16 accept
        iifname "$INTERFACE" ip saddr 172.16.0.0/16 oifname "wg0" accept
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$INTERFACE" masquerade
    }
}
EOF

    nft -f /etc/nftables.conf

    if ! wg-quick up wg0; then
        print_message "$RED" "Error: Could not activate wg0."
        return 1
    fi

    cat > /etc/wireguard/wg_manager.conf << EOF
SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
SERVER_IP=$(curl -s https://api.ipify.org)
WG_PORT=$WG_PORT
INTERFACE=$INTERFACE
EOF

    systemctl enable wg-quick@wg0
    print_message "$GREEN" "WireGuard is up and running."
}

configure_ufw() {
    print_message "$YELLOW" "Configuring UFW..."
    
    # Source wg_manager.conf to access WG_PORT
    if [[ -f /etc/wireguard/wg_manager.conf ]]; then
        source /etc/wireguard/wg_manager.conf
    else
        print_message "$RED" "Error: wg_manager.conf not found. Cannot configure UFW."
        exit 1
    fi

    ufw allow "$WG_PORT"/udp
    ufw reload
    print_message "$GREEN" "UFW configured to allow WireGuard traffic on port $WG_PORT/udp."
}
