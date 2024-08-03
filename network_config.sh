#!/bin/bash

# Functions for configure WireGuard and network

install_wireguard() {
    print_message "$YELLOW" "Installing WireGuard..."
    apt update
    apt install -y wireguard
    print_message "$GREEN" "WireGuard installed successfully."
}

detect_network_config() {
    INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    SERVER_IP=$(curl -s https://api.ipify.org)
    WG_PORT=$(shuf -i 10000-60000 -n 1)
    print_message "$GREEN" "Detected network interface: $INTERFACE"
    print_message "$GREEN" "Detected server IP: $SERVER_IP"
    print_message "$GREEN" "Generated WireGuard port: $WG_PORT"
}

backup_ufw_rules() {
    print_message "$YELLOW" "Backing up UFW rules..."
    ufw status numbered > /etc/ufw/ufw.rules.backup
    print_message "$GREEN" "UFW rules backed up to /etc/ufw/ufw.rules.backup"
}

configure_wireguard_server() {
    print_message "$YELLOW" "Configuring WireGuard server..."

    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo $SERVER_PRIVATE_KEY | wg pubkey)

    umask 077
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
SaveConfig = true
PrivateKey = $SERVER_PRIVATE_KEY
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE
EOF

    print_message "$GREEN" "WireGuard server configured. Public key: $SERVER_PUBLIC_KEY"

    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0 || {
        print_message "$RED" "Failed to bring up WireGuard interface. Check system logs for details."
        return 1
    }
    print_message "$GREEN" "WireGuard interface wg0 is up and running."
}

configure_ufw() {
    print_message "$YELLOW" "Configuring UFW..."
    ufw allow $WG_PORT/udp
    ufw reload
    print_message "$GREEN" "UFW configured to allow WireGuard traffic."
}