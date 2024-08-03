#!/bin/bash

# Handling the system functions

update_system() {
    print_message "$YELLOW" "Updating system and WireGuard..."
    apt update && apt upgrade -y
    print_message "$GREEN" "System updated successfuly."
}

rotate_server_keys() {
    print_message "$YELLOW" "Rotating server keys..."
    NEW_PRIVATE_KEY=$(wg genkey)
    NEW_PUBLIC_KEY=$(echo $NEW_PRIVATE_KEY | wg pubkey)

    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak_$(date +%Y%m%d_%H%M%S)

    sed -i "s|PrivateKey = .*|PrivateKey = $NEW_PRIVATE_KEY|" /etc/wireguard/wg0.conf

    if ! wg-quick strip wg0 > /dev/null 2>&1; then
        print_message "$RED" "New configuration is invalid. Reverting changes."
        mv /etc/wireguard/wg0.conf.bak /etc/wireguard/wg0.conf
        return 1
    fi

    print_message "$GREEN" "Server keys rotated. New public key: $NEW_PUBLIC_KEY"

    jq -r 'keys[]' $USER_DB | while read username; do
        sed -i "s|PublicKey = .*|PublicKey = $NEW_PUBLIC_KEY|" "/etc/wireguard/clients/$username.conf"
    done

    systemctl restart wg-quick@wg0
    print_message "$GREEN" "WireGuard service restarted with new keys."
}

change_wireguard_port() {
    local old_port=$(grep ListenPort /etc/wireguard/wg0.conf | awk '{print $3}')
    read -p "Enter new WireGuard port: " new_port

    sed -i "s|ListenPort = .*|ListenPort = $new_port|" /etc/wireguard/wg0.conf

    if command -v ufw &> /dev/null; then
        ufw delete allow $old_port/udp
        ufw allow $new_port/udp
        ufw reload
    fi

    wg-quick down wg0
    sleep 2
    wg-quick up wg0
    sleep 2

    local current_port=$(wg show wg0 listen-port)
    if [ "$current_port" != "$new_port" ]; then
        print_message "$RED" "Failed to change WireGuard port. Current port is still $current_port"
        print_message "$YELLOW" "Attempting to force port change..."

        wg set wg0 listen-port $new_port
        sleep 2

        current_port=$(wg show wg0 listen-port)
        if [ "$current_port" != "$new_port" ]; then
            print_message "$RED" "Failed to force port change. Please check your Wireguard configuration manually."
            return 1
        fi
    fi

    if [ -f /etc/fail2ban/jail.d/wireguard.conf ]; then
        sed -i "s|port = .*|port = $new_port|" /etc/fail2ban/jail.d/wireguard.conf
        systemctl restart fail2ban
    fi

    print_message "$GREEN" "WireGuard port successfully changed from $old_port to $new_port"
    print_message "$YELLOW" "Please ensure your router/firewall is configured to forward the new port."

    local server_public_ip=$(curl -s https://api.ipify.org)
    for client_conf in /etc/wireguard/clients/*.conf; do
        sed -i "s|Endpoint = .*|Endpoint = $server_public_ip:$new_port|" "$client_conf"
    done
    print_message "$GREEN" "Updated all client configurations with the new port."

    print_message "$YELLOW" "It's recommended to run the WireGuard Accessibility Check to verify the new configuration."
}

uninstall_wireguard() {
    print_message "$YELLOW" "Uninstalling Wireguard..."
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    ip link delete dev wg0 2>/dev/null
    rm -rf /etc/wireguard
    apt remove -y wireguard wireguard-dkms
    apt autoremove -y
    print_message "$GREEN" "WireGuard uninstalled successfully."
}