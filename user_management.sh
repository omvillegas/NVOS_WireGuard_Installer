#!/bin/bash

# Users manager script

# Función para inicializar la base de datos de usuarios
init_user_db() {
    if [[ ! -f "$USER_DB" ]]; then
        echo '{}' > "$USER_DB"
    fi
    chmod 600 "$USER_DB"
}

# Función para agregar un usuario a la base de datos
add_user_to_db() {
    local username=$1
    local email=$2
    local ip=$3
    local pubkey=$4
    jq --arg u "$username" --arg e "$email" --arg i "$ip" --arg k "$pubkey" \
       '.[$u] = {email: $e, ip: $i, pubkey: $k}' "$USER_DB" > tmp.json && mv tmp.json "$USER_DB"
}

# Función para eliminar un usuario de la base de datos
remove_user_from_db() {
    local username=$1
    jq "del(.[\"$username\"])" "$USER_DB" > tmp.json && mv tmp.json "$USER_DB"
}

# Función para generar certificados de usuario
generate_user_certificates() {
    init_user_db
    print_message "$YELLOW" "Leyendo usuarios desde el archivo CSV (users.csv) y generando certificados..."
    INPUT_FILE="users.csv"
    
    if [[ ! -f "$INPUT_FILE" ]]; then
        print_message "$RED" "Error: $INPUT_FILE no encontrado!"
        return 1
    fi

    # Omitir la línea de encabezado
    mapfile -t users < <(tail -n +2 "$INPUT_FILE")

    if [[ ${#users[@]} -eq 0 ]]; then
        print_message "$RED" "No se encontraron usuarios en el archivo CSV."
        return 1
    fi

    print_message "$YELLOW" "Selecciona los usuarios para generar certificados:"
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    read -p "Ingresa los números de los usuarios (separados por comas) o 'all' para todos: " selection

    if [[ "$selection" == "all" ]]; then
        selected_indices=($(seq 0 $((${#users[@]}-1))))
    else
        IFS=',' read -ra selected_indices <<< "$selection"
        selected_indices=(${selected_indices[@]})
        for i in "${!selected_indices[@]}"; do
            selected_indices[$i]=$((${selected_indices[$i]}-1))
            # Validar que el índice esté dentro del rango
            if (( selected_indices[$i] < 0 || selected_indices[$i] >= ${#users[@]} )); then
                print_message "$RED" "Selección inválida: ${selected_indices[$i]}."
                return 1
            fi
        done
    fi

    mkdir -p /etc/wireguard/clients
    chmod 700 /etc/wireguard/clients

    # Sourcear el archivo de configuración para obtener variables del servidor
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        print_message "$RED" "Configuration file $CONFIG_FILE not found."
        return 1
    fi

    if [[ -z "$SERVER_PUBLIC_KEY" || -z "$SERVER_IP" || -z "$WG_PORT" ]]; then
        print_message "$RED" "Server configuration variables are not properly set."
        return 1
    fi

    for index in "${selected_indices[@]}"; do
        IFS=',' read -r username email <<< "${users[$index]}"
        username=$(echo "$username" | xargs) # Eliminar espacios
        email=$(echo "$email" | xargs)

        # Verificar si el usuario ya existe
        if jq -e ".\"$username\"" "$USER_DB" > /dev/null; then
            print_message "$YELLOW" "El usuario $username ya existe. Saltando..."
            continue
        fi

        # Generar claves privadas y públicas del cliente
        CLIENT_PRIVATE_KEY=$(wg genkey)
        CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

        # Asignar una IP única al cliente
        existing_ips=$(jq -r '.[].ip' "$USER_DB")
        while true; do
            CLIENT_IP="10.0.0.$((RANDOM % 254 + 2))"
            if ! echo "$existing_ips" | grep -qw "$CLIENT_IP"; then
                break
            fi
        done

        # Crear el archivo de configuración del cliente con permisos restrictivos
        umask 077
        cat > "/etc/wireguard/clients/$username.conf" << EOF
[Interface]
Address = $CLIENT_IP/24
PrivateKey = $CLIENT_PRIVATE_KEY
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
EOF

        # Añadir el peer al servidor WireGuard
        if ! wg set wg0 peer "$CLIENT_PUBLIC_KEY" allowed-ips "$CLIENT_IP/32"; then
            print_message "$RED" "No se pudo modificar la interfaz WireGuard para el usuario $username. Eliminando configuración."
            rm "/etc/wireguard/clients/$username.conf"
            continue
        fi

        # Agregar el usuario a la base de datos
        add_user_to_db "$username" "$email" "$CLIENT_IP" "$CLIENT_PUBLIC_KEY"
        print_message "$GREEN" "Certificado generado para $username ($email)"
    done

    # Guardar la configuración actual de WireGuard
    wg-quick save wg0
}

# Función para eliminar certificados de usuarios
remove_user_certificates() {
    print_message "$YELLOW" "Eliminando certificados de usuarios..."

    # Obtener la lista de usuarios desde la base de datos
    users=($(jq -r 'keys[]' "$USER_DB"))

    if [[ ${#users[@]} -eq 0 ]]; then
        print_message "$RED" "No se encontraron certificados de usuarios."
        return
    fi

    print_message "$YELLOW" "Selecciona los usuarios para eliminar sus certificados:"
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    read -p "Ingresa los números de los usuarios (separados por comas) o 'all' para todos: " selection

    if [[ "$selection" == "all" ]]; then
        selected_indices=($(seq 0 $((${#users[@]}-1))))
    else
        IFS=',' read -ra selected_indices <<< "$selection"
        selected_indices=(${selected_indices[@]})
        for i in "${!selected_indices[@]}"; do
            selected_indices[$i]=$((${selected_indices[$i]}-1))
            # Validar que el índice esté dentro del rango
            if (( selected_indices[$i] < 0 || selected_indices[$i] >= ${#users[@]} )); then
                print_message "$RED" "Selección inválida: ${selected_indices[$i]}."
                return 1
            fi
        done
    fi

    for index in "${selected_indices[@]}"; do
        username="${users[$index]}"
        # Eliminar el archivo de configuración del cliente
        rm "/etc/wireguard/clients/$username.conf" 2>/dev/null
        # Obtener la clave pública del cliente desde la base de datos
        client_pubkey=$(jq -r ".[\"$username\"].pubkey" "$USER_DB")
        # Eliminar el peer del servidor WireGuard
        wg set wg0 peer "$client_pubkey" remove
        # Eliminar el usuario de la base de datos
        remove_user_from_db "$username"
        print_message "$GREEN" "Certificado eliminado para $username"
    done

    # Guardar la configuración actual de WireGuard
    wg-quick save wg0
}

# Función para listar usuarios actuales
list_users() {
    if [[ ! -f "$USER_DB" ]]; then
        print_message "$YELLOW" "No user database found."
        return
    fi
    if [[ $(jq 'length' "$USER_DB") -eq 0 ]]; then
        print_message "$YELLOW" "No users found in the database."
        return
    fi
    print_message "$YELLOW" "Usuarios actuales de WireGuard:"
    jq -r 'to_entries[] | "\(.key) (\(.value.email))"' "$USER_DB"
}

# Función para generar código QR para un usuario
generate_qr_and_show_config() {
    local username=$1
    if [[ ! -f "/etc/wireguard/clients/$username.conf" ]]; then
        print_message "$RED" "No se encontró la configuración para el usuario $username."
        return 1
    fi

    read -p "¿Deseas generar el código QR en la consola (1), como archivo PNG (2), o mostrar la configuración en pantalla (3)? [1/2/3]: " qr_option

    case "$qr_option" in
        1)
            qrencode -t ansiutf8 < "/etc/wireguard/clients/$username.conf"
            ;;
        2)
            qrencode -o "/etc/wireguard/clients/$username.png" < "/etc/wireguard/clients/$username.conf"
            print_message "$GREEN" "Código QR generado como /etc/wireguard/clients/$username.png"
            ;;
        3)
            print_message "$YELLOW" "Configuración del cliente $username:"
            cat "/etc/wireguard/clients/$username.conf"
            ;;
        *)
            print_message "$RED" "Opción inválida. Seleccionando la opción 1 por defecto."
            qrencode -t ansiutf8 < "/etc/wireguard/clients/$username.conf"
            ;;
    esac
}
