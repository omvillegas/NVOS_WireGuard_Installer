#!/bin/bash

# Fucntions to backup and recover WireGuard configurations

backup_wireguard_config() {
    backup_dir="/root/wireguard_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -r /etc/wireguard "$backup_dir"
    print_message "$GREEN" "WireGuard configuration backed up to $backup_dir"
}

restore_wireguard_config() {
    print_message "$YELLOW" "Available backups:"
    backups=($(ls -d /root/wireguard_backup_* 2>/dev/null))
    if [[ ${#backups[@]} -eq 0 ]]; then
        print_message "$RED" "No backups found."
        return
    fi
    for i in "${!backups[@]}"; do
        echo "$((i+1)). ${backups[$i]}"
    done
    read -p "Enter the number of the backup to restore: " backup_choice
    if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || (( backup_choice < 1 || backup_choice > ${#backups[@]} )); then
        print_message "$RED" "Invalid selection."
        return
    fi
    selected_backup="${backups[$((backup_choice-1))]}"
    cp -r "$selected_backup/wireguard" /etc/
    print_message "$GREEN" "WireGuard configuration restored from $selected_backup"
    
    # Obtener el nombre de la interfaz desde la configuración
    wg_interface=$(grep -E '^\[Interface\]' -A 10 /etc/wireguard/wg0.conf | grep 'ListenPort' | awk '{print $1}')
    if [[ -z "$wg_interface" ]]; then
        wg_interface="wg0" # Valor por defecto si no se encuentra
    fi

    systemctl restart "wg-quick@$wg_interface"
}