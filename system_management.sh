#!/bin/bash

# Handling the system functions

update_system() {
    print_message "$YELLOW" "Updating system and WireGuard..."
    apt update && apt upgrade -y
    print_message "$GREEN" "System updated successfully."
}

rotate_server_keys() {
    print_message "$YELLOW" "Rotating server keys..."
    NEW_PRIVATE_KEY=$(wg genkey)
    NEW_PUBLIC_KEY=$(echo "$NEW_PRIVATE_KEY" | wg pubkey)

    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak_$(date +%Y%m%d_%H%M%S)

    sed -i "s|PrivateKey = .*|PrivateKey = $NEW_PRIVATE_KEY|" /etc/wireguard/wg0.conf

    if ! wg-quick down wg0; then
        print_message "$RED" "Failed to bring down WireGuard interface. Reverting changes."
        mv /etc/wireguard/wg0.conf.bak_$(date +%Y%m%d_%H%M%S) /etc/wireguard/wg0.conf
        return 1
    fi

    if ! wg-quick up wg0; then
        print_message "$RED" "Failed to bring up WireGuard interface. Reverting changes."
        mv /etc/wireguard/wg0.conf.bak_$(date +%Y%m%d_%H%M%S) /etc/wireguard/wg0.conf
        wg-quick up wg0
        return 1
    fi

    # Actualizar la clave pública del servidor en las configuraciones de los clientes
    SERVER_PUBLIC_KEY="$NEW_PUBLIC_KEY"
    for client_conf in /etc/wireguard/clients/*.conf; do
        if [[ -f "$client_conf" ]]; then
            sed -i "s|PublicKey = .*|PublicKey = $SERVER_PUBLIC_KEY|" "$client_conf"
        fi
    done

    systemctl restart wg-quick@wg0
    print_message "$GREEN" "Server keys rotated. New public key: $NEW_PUBLIC_KEY"
}

change_wireguard_port() {
    local old_port=$(grep -i '^ListenPort' /etc/wireguard/wg0.conf | awk '{print $3}')
    read -p "Enter new WireGuard port: " new_port

    # Validar que el nuevo puerto es un número y está en el rango permitido
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        print_message "$RED" "Invalid port number."
        return 1
    fi

    # Verificar que el puerto no esté en uso
    if ss -tunlp | grep -q ":$new_port "; then
        print_message "$RED" "Port $new_port is already in use."
        return 1
    fi

    sed -i "s|ListenPort = .*|ListenPort = $new_port|" /etc/wireguard/wg0.conf

    if command -v ufw &> /dev/null; then
        ufw delete allow "$old_port"/udp
        ufw allow "$new_port"/udp
        ufw reload
    fi

    wg-quick down wg0
    sleep 2
    wg-quick up wg0
    sleep 2

    # Verificar que el puerto se haya cambiado correctamente
    current_port=$(grep -i '^ListenPort' /etc/wireguard/wg0.conf | awk '{print $3}')
    if [[ "$current_port" != "$new_port" ]]; then
        print_message "$RED" "Failed to change WireGuard port. Current port is still $current_port"
        print_message "$YELLOW" "Attempting to force port change..."
        sed -i "s|ListenPort = .*|ListenPort = $new_port|" /etc/wireguard/wg0.conf
        wg-quick up wg0
        current_port=$(grep -i '^ListenPort' /etc/wireguard/wg0.conf | awk '{print $3}')
        if [[ "$current_port" != "$new_port" ]]; then
            print_message "$RED" "Failed to force port change. Please check your WireGuard configuration manually."
            return 1
        fi
    fi

    if [[ -f /etc/fail2ban/jail.d/wireguard.conf ]]; then
        sed -i "s|port = .*|port = $new_port|" /etc/fail2ban/jail.d/wireguard.conf
        systemctl restart fail2ban
    fi

    print_message "$GREEN" "WireGuard port successfully changed from $old_port to $new_port"
    print_message "$YELLOW" "Please ensure your router/firewall is configured to forward the new port."

    SERVER_PUBLIC_IP=$(grep -i '^Endpoint' /etc/wireguard/clients/*.conf | awk -F':' '{print $1}' | head -n1)
    for client_conf in /etc/wireguard/clients/*.conf; do
        sed -i "s|Endpoint = .*|Endpoint = $SERVER_PUBLIC_IP:$new_port|" "$client_conf"
    done
    print_message "$GREEN" "Updated all client configurations with the new port."

    print_message "$YELLOW" "It's recommended to run the WireGuard Accessibility Check to verify the new configuration."
}

uninstall_wireguard() {
    print_message "$YELLOW" "Uninstalling WireGuard..."
    wg-quick down wg0 || true
    systemctl disable wg-quick@wg0
    ip link delete dev wg0 2>/dev/null || true
    rm -rf /etc/wireguard
    apt remove -y wireguard wireguard-dkms
    apt autoremove -y
    print_message "$GREEN" "WireGuard uninstalled successfully."
}
