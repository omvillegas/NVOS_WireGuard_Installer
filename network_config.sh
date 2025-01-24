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

    # Ensure that /etc/wireguard exists
    if [[ ! -d /etc/wireguard ]]; then
        print_message "$YELLOW" "The /etc/wireguard directory does not exist. Creating it..."
        mkdir -p /etc/wireguard
        chmod 700 /etc/wireguard
        if [[ $? -ne 0 ]]; then
            print_message "$RED" "Error: Could not create the /etc/wireguard directory."
            exit 1
        fi
        print_message "$GREEN" "/etc/wireguard directory created successfully."
    else
        print_message "$GREEN" "The /etc/wireguard directory already exists."
    fi

    # Detect network configuration
    detect_network_config

    # Check if wg0.conf already exists
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        print_message "$YELLOW" "wg0.conf already exists. Loading existing configuration."

        # Extract necessary variables from wg0.conf
        SERVER_PRIVATE_KEY=$(grep -i '^PrivateKey' /etc/wireguard/wg0.conf | awk '{print $3}')
        if [[ -z "$SERVER_PRIVATE_KEY" ]]; then
            print_message "$RED" "Error: SERVER_PRIVATE_KEY not found in wg0.conf."
            exit 1
        fi
        SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
        WG_PORT=$(grep -i '^ListenPort' /etc/wireguard/wg0.conf | awk '{print $3}')

        # Get SERVER_IP from existing configuration
        SERVER_IP=$(grep -i '^Endpoint' /etc/wireguard/wg0.conf | awk -F':' '{print $1}' | head -n1)
        if [[ -z "$SERVER_IP" ]]; then
            # If Endpoint is not defined, use the detected public IP
            SERVER_IP=$(curl -s https://api.ipify.org)
            if [[ -z "$SERVER_IP" ]]; then
                print_message "$RED" "Error: Failed to retrieve public IP."
                exit 1
            fi
        fi

        # Debugging: Log variable values
        print_message "$YELLOW" "SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY"
        print_message "$YELLOW" "SERVER_IP=$SERVER_IP"
        print_message "$YELLOW" "WG_PORT=$WG_PORT"
        print_message "$YELLOW" "INTERFACE=$INTERFACE"

        # Save configuration variables to wg_manager.conf
        cat > /etc/wireguard/wg_manager.conf << EOF
SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
SERVER_IP=$SERVER_IP
WG_PORT=$WG_PORT
INTERFACE=$INTERFACE
EOF

        print_message "$GREEN" "WireGuard configuration loaded from existing wg0.conf."
        return
    fi

    # If wg0.conf does not exist, proceed with configuration
    SERVER_PRIVATE_KEY=$(wg genkey)
    if [[ -z "$SERVER_PRIVATE_KEY" ]]; then
        print_message "$RED" "Error: Failed to generate SERVER_PRIVATE_KEY."
        exit 1
    fi
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
        print_message "$RED" "Error: Failed to generate SERVER_PUBLIC_KEY."
        exit 1
    fi

    # Generate a random port and verify it's not in use
    while true; do
        WG_PORT=$(shuf -i 10000-60000 -n 1)
        if ! ss -tunlp | grep -q ":$WG_PORT "; then
            break
        fi
    done

    print_message "$GREEN" "Generated WireGuard port: $WG_PORT"

    # Enable IP forwarding
    print_message "$YELLOW" "Enabling IP forwarding..."
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if ! sysctl -p; then
        print_message "$RED" "Error: Failed to enable IP forwarding."
        exit 1
    fi
    print_message "$GREEN" "IP forwarding enabled."

    # Create wg0.conf with secure permissions
    umask 077
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
SaveConfig = true
PrivateKey = $SERVER_PRIVATE_KEY
ListenPort = $WG_PORT
PostUp = nft add table inet wireguard; \
         nft add chain inet wireguard FORWARD { type filter hook forward priority 0 \; }; \
         nft add rule inet wireguard FORWARD iif $INTERFACE oif %i accept; \
         if ! nft list tables | grep -q 'ip nat'; then \
             nft add table ip nat; \
             nft add chain ip nat POSTROUTING { type nat hook postrouting priority 100 \; }; \
         fi; \
         nft add rule ip nat POSTROUTING oif $INTERFACE masquerade
PostDown = nft delete rule ip nat POSTROUTING oif $INTERFACE masquerade; \
           nft delete chain inet wireguard FORWARD; \
           nft delete table inet wireguard
EOF

    # Debugging: Show wg0.conf content
    print_message "$YELLOW" "wg0.conf content:"
    cat /etc/wireguard/wg0.conf

    # Validate wg0.conf syntax
    if ! wg-quick strip wg0 > /dev/null; then
        print_message "$RED" "Error: wg0.conf has syntax errors."
        exit 1
    fi

    # Activate the WireGuard interface
    if ! wg-quick up wg0; then
        print_message "$RED" "Error: Could not activate the WireGuard interface. Check system logs for more details."
        return 1
    fi

    # Save configuration variables to wg_manager.conf
    cat > /etc/wireguard/wg_manager.conf << EOF
SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
SERVER_IP=$SERVER_IP
WG_PORT=$WG_PORT
INTERFACE=$INTERFACE
EOF

    # Debugging: Show wg_manager.conf content
    print_message "$YELLOW" "wg_manager.conf content:"
    cat /etc/wireguard/wg_manager.conf

    # Enable the WireGuard service to start on boot
    if ! systemctl enable wg-quick@wg0; then
        print_message "$RED" "Error: Failed to enable wg-quick@wg0 service."
        exit 1
    fi

    print_message "$GREEN" "WireGuard interface wg0 is up and running successfully."
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
