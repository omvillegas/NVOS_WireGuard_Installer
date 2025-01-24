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
    print_message "$YELLOW" "Starting WireGuard uninstallation process..."

    # Prompt for user confirmation
    read -rp "Are you sure you want to uninstall WireGuard and remove all configurations? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_message "$GREEN" "Uninstallation aborted by user."
        return 0
    fi

    # Extract WG_PORT and INTERFACE from wg_manager.conf before removal
    if [[ -f /etc/wireguard/wg_manager.conf ]]; then
        source /etc/wireguard/wg_manager.conf
    else
        print_message "$YELLOW" "wg_manager.conf not found. Proceeding without port and interface information."
        WG_PORT=""
        INTERFACE=""
    fi

    # Stop and disable the WireGuard interface
    if systemctl is-active --quiet wg-quick@wg0; then
        print_message "$YELLOW" "Stopping WireGuard interface wg0..."
        if ! wg-quick down wg0; then
            print_message "$RED" "Warning: Failed to stop wg0 interface."
        else
            print_message "$GREEN" "WireGuard interface wg0 stopped."
        fi
    fi

    print_message "$YELLOW" "Disabling WireGuard service..."
    if systemctl is-enabled --quiet wg-quick@wg0; then
        if ! systemctl disable wg-quick@wg0; then
            print_message "$RED" "Warning: Failed to disable wg-quick@wg0 service."
        else
            print_message "$GREEN" "WireGuard service disabled."
        fi
    fi

    # Remove WireGuard network interface if it exists
    if ip link show wg0 &> /dev/null; then
        print_message "$YELLOW" "Deleting WireGuard network interface wg0..."
        if ! ip link delete dev wg0; then
            print_message "$RED" "Warning: Failed to delete wg0 interface."
        else
            print_message "$GREEN" "WireGuard network interface wg0 deleted."
        fi
    else
        print_message "$GREEN" "WireGuard network interface wg0 does not exist. Skipping."
    fi

    # Revert UFW rules related to WireGuard
    if command -v ufw &> /dev/null && [[ -n "$WG_PORT" ]]; then
        print_message "$YELLOW" "Reverting UFW rules related to WireGuard..."

        # Remove WireGuard UDP port allowance
        if ufw status | grep -q "$WG_PORT/udp"; then
            ufw delete allow "$WG_PORT"/udp
            print_message "$GREEN" "Removed UFW rule to allow port $WG_PORT/udp."
        else
            print_message "$GREEN" "No UFW rule found for port $WG_PORT/udp. Skipping."
        fi
    else
        print_message "$YELLOW" "UFW is not installed or WG_PORT is undefined. Skipping UFW rules reversion."
    fi

    # Revert nftables rules related to WireGuard
    if command -v nft &> /dev/null && [[ -n "$INTERFACE" ]]; then
        print_message "$YELLOW" "Reverting nftables rules related to WireGuard..."

        # Remove NAT masquerade rule
        if nft list ruleset | grep -q "oif $INTERFACE masquerade"; then
            nft delete rule ip nat POSTROUTING oif "$INTERFACE" masquerade
            print_message "$GREEN" "Removed NAT masquerade rule for interface $INTERFACE."
        else
            print_message "$GREEN" "No NAT masquerade rule found for interface $INTERFACE. Skipping."
        fi

        # Remove WireGuard filter rules
        if nft list tables | grep -q "inet wireguard"; then
            nft delete chain inet wireguard FORWARD
            nft delete table inet wireguard
            print_message "$GREEN" "Removed inet wireguard table and FORWARD chain."
        else
            print_message "$GREEN" "No inet wireguard table found. Skipping."
        fi
    else
        print_message "$YELLOW" "nftables is not installed or INTERFACE is undefined. Skipping nftables rules reversion."
    fi

    # Backup and remove WireGuard configuration files
    if [[ -d /etc/wireguard ]]; then
        print_message "$YELLOW" "Backing up existing WireGuard configurations..."
        tar czf /etc/wireguard_backup_$(date +%F_%T).tar.gz /etc/wireguard
        print_message "$GREEN" "WireGuard configurations backed up to /etc/wireguard_backup_$(date +%F_%T).tar.gz"

        print_message "$YELLOW" "Removing WireGuard configuration files..."
        if rm -rf /etc/wireguard; then
            print_message "$GREEN" "WireGuard configuration files removed."
        else
            print_message "$RED" "Error: Failed to remove WireGuard configuration files."
        fi
    else
        print_message "$GREEN" "/etc/wireguard directory does not exist. Skipping."
    fi

    # Purge WireGuard packages completely
    print_message "$YELLOW" "Purging WireGuard packages..."
    PACKAGES=("wireguard" "wireguard-tools")
    for pkg in "${PACKAGES[@]}"; do
        if dpkg -l | grep -qw "$pkg"; then
            if apt purge -y "$pkg"; then
                print_message "$GREEN" "Purged package: $pkg"
            else
                print_message "$RED" "Error: Failed to purge package: $pkg"
            fi
        else
            print_message "$GREEN" "Package $pkg is not installed. Skipping."
        fi
    done

    # Optionally, remove dependencies installed exclusively for WireGuard
    # Caution: Ensure that these dependencies are not used by other services
    print_message "$YELLOW" "Removing unused dependencies..."
    apt autoremove -y
    print_message "$GREEN" "Unused dependencies removed."

    # Remove WireGuard logs if any
    LOG_FILES=("/var/log/wireguard.log" "/var/log/wg-access.log")
    for log in "${LOG_FILES[@]}"; do
        if [[ -f "$log" ]]; then
            print_message "$YELLOW" "Removing log file: $log"
            rm -f "$log"
            print_message "$GREEN" "Log file $log removed."
        else
            print_message "$GREEN" "Log file $log does not exist. Skipping."
        fi
    done

    # Remove any residual systemd service files
    SERVICE_FILE="/etc/systemd/system/wg-quick@wg0.service"
    if [[ -f "$SERVICE_FILE" ]]; then
        print_message "$YELLOW" "Removing residual systemd service file..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        print_message "$GREEN" "Residual systemd service file removed and daemon reloaded."
    else
        print_message "$GREEN" "No residual systemd service file found. Skipping."
    fi

    # Remove WireGuard user database if exists
    if [[ -f "$USER_DB" ]]; then
        print_message "$YELLOW" "Removing WireGuard user database..."
        rm -f "$USER_DB"
        print_message "$GREEN" "WireGuard user database removed."
    else
        print_message "$GREEN" "WireGuard user database does not exist. Skipping."
    fi

    print_message "$GREEN" "WireGuard has been completely uninstalled and purged from the system."
}
