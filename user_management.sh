#!/bin/bash

# Users manager script

init_user_db() {
    if [[ ! -f $USER_DB ]]; then
        echo '{}' > $USER_DB
    fi
    chmod 600 $USER_DB
}

add_user_to_db() {
    local username=$1
    local email=$2
    local ip=$3
    local pubkey=$4
    jq --arg u "$username" --arg e "$email" --arg i "$ip" --arg k "$pubkey" \
       '.[$u] = {email: $e, ip: $i, pubkey: $k}' $USER_DB > tmp.json && mv tmp.json $USER_DB
}

remove_user_from_db() {
    local username=$1
    jq "del(.[\"$username\"])" $USER_DB > tmp.json && mv tmp.json $USER_DB
}

generate_user_certificates() {
    init_user_db
    print_message "$YELLOW" "Reading users from csv (users.csv) and generating certificates..."
    INPUT_FILE="users.csv"
    if [[ ! -f "$INPUT_FILE" ]]; then
        print_message "$RED" "Error: $INPUT_FILE not found!"
        return 1
    fi

    mapfile -t users < <(tail -n +1 "$INPUT_FILE")

    if [[ ${#users[@]} -eq 0 ]]; then
        print_message "$RED" "No users found in the csv file."
        return 1
    fi

    print_message "$YELLOW" "Select users to generate certificates for:"
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    read -p "Enter numbers of users (comma-separated) or 'all': " selection

    if [[ "$selection" == "all" ]]; then
        selected_indices=$(seq 0 $((${#users[@]}-1)))
    else
        IFS=',' read -ra selected_indices <<< "$selection"
        selected_indices=(${selected_indices[@]})
        for i in "${!selected_indices[@]}"; do
            selected_indices[$i]=$((${selected_indices[$i]}-1))
        done
    fi

    mkdir -p /etc/wireguard/clients

    for index in "${selected_indices[@]}"; do
        IFS=',' read -r username email <<< "${users[$index]}"

        if jq -e ".\"$username\"" $USER_DB > /dev/null; then
            print_message "$YELLOW" "User $username already exists. Skipping..."
            continue
        fi

        CLIENT_PRIVATE_KEY=$(wg genkey)
        CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)
        CLIENT_IP="10.0.0.$((RANDOM % 254 + 2))"

        while jq -e ".[] | select(.ip == \"$CLIENT_IP\")" $USER_DB > /dev/null; do
            CLIENT_IP="10.0.0.$((RANDOM % 254 + 2))"
        done

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
        wg set wg0 peer $CLIENT_PUBLIC_KEY allowed-ips $CLIENT_IP/32 || {
            print_message "$RED" "Unable to modify interface: No such device"
            return 1
        }
        add_user_to_db "$username" "$email" "$CLIENT_IP" "$CLIENT_PUBLIC_KEY"
        print_message "$GREEN" "Generated certificate for $username ($email)"
    done
    wg-quick save wg0
}

remove_user_certificates() {
    print_message "$YELLOW" "Removing user certificates..."

    users=($(jq -r 'keys[]' $USER_DB))

    if [[ ${#users[@]} -eq 0 ]]; then
        print_message "$RED" "No user certificates found."
        return
    fi

    print_message "$YELLOW" "Select users to remove certificates for:"
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    read -p "Enter numbers of users (comma-separated) or 'all': " selection

    if [[ "$selection" == "all" ]]; then
        selected_indices=$(seq 0 $((${#users[@]}-1)))
    else
        IFS=',' read -ra selected_indices <<< "$selection"
        selected_indices=(${selected_indices[@]})
        for i in "${!selected_indices[@]}"; do
            selected_indices[$i]=$((${selected_indices[$i]}-1))
        done
    fi

    for index in "${selected_indices[@]}"; do
        username="${users[$index]}"
        rm "/etc/wireguard/clients/$username.conf"
        client_pubkey=$(jq -r ".[\"$username\"].pubkey" $USER_DB)
        wg set wg0 peer $client_pubkey remove
        remove_user_from_db "$username"
        print_message "$GREEN" "Removed certificate for $username"
    done
    wg-quick save wg0
}

list_users() {
    print_message "$YELLOW" "Current WireGuard users:"
    jq -r 'to_entries[] | "\(.key) (\(.value.email))"' $USER_DB
}

generate_qr_code() {
    local username=$1
    if [[ ! -f "/etc/wireguard/clients/$username.conf" ]]; then
        print_message "$RED" "Configuration for $username not found."
        return 1
    fi
    qrencode -t ansiutf8 < "/etc/wireguard/clients/$username.conf"
}