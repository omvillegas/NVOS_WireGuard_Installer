#!/bin/bash

configure_fail2ban() {
    print_message "$YELLOW" "Configuring fail2ban for WireGuard..."
    cat << EOF > /etc/fail2ban/filter.d/wireguard.conf
[Definition]
failregex = Failed to authenticate packet from .* port \d+$
ignoreregex =
EOF

    cat << EOF > /etc/fail2ban/jail.d/wireguard.conf
[wireguard]
enabled = true
port = $WG_PORT
filter = wireguard
logpath = /var/log/syslog
maxretry = 3
bantime = 3600
EOF

    systemctl restart fail2ban
    print_message "$GREEN" "fail2ban configured for Wireguard."
}

parse_human_size() {
    local input="$1"
    local number unit bytes
    input="$(echo "$input" | xargs)"
    IFS=' ' read -r number unit <<< "$input"
    number="$(echo "$number" | sed 's/[^0-9\.]//g')"
    unit="$(echo "$unit" | sed 's/[^A-Za-z]//g')"
    [ -z "$unit" ] && unit="B"
    case "$unit" in
        B|b) bytes=$(printf "%.0f" "$number") ;;
        KiB) bytes=$(echo "$number*1024" | bc -l) ;;
        MiB) bytes=$(echo "$number*1024*1024" | bc -l) ;;
        GiB) bytes=$(echo "$number*1024*1024*1024" | bc -l) ;;
        *)   bytes=$(printf "%.0f" "$number") ;;
    esac
    printf "%.0f" "$bytes"
}

show_usage_stats() {
    print_message "$YELLOW" "WireGuard Usage Statistics:"

    if ! command -v wg &> /dev/null; then
        echo "WireGuard is not installed or the 'wg' command was not found."
        return
    fi

    USERS_JSON="/etc/wireguard/users.json"
    if [ ! -f "$USERS_JSON" ]; then
        echo "Users file not found at $USERS_JSON."
        return
    fi

    declare -A user_map
    while read -r pubkey username; do
        user_map["$pubkey"]="$username"
    done < <(jq -r 'to_entries[] | "\(.value.pubkey) \(.key)"' "$USERS_JSON")

    show_output=$(wg show all)
    declare -A peers
    current_peer=""
    rx_bytes=0
    tx_bytes=0

    while IFS= read -r line; do
        if [[ $line =~ ^peer:\ ([A-Za-z0-9+/=]+) ]]; then
            current_peer="${BASH_REMATCH[1]}"
            rx_bytes=0
            tx_bytes=0
        elif [[ $line =~ ^\ +transfer:\ ([0-9\.]+\ [KMG]?iB)\ received,\ ([0-9\.]+\ [KMG]?iB)\ sent ]]; then
            rx_raw="${BASH_REMATCH[1]}"
            tx_raw="${BASH_REMATCH[2]}"
            rx="$(parse_human_size "$rx_raw")"
            tx="$(parse_human_size "$tx_raw")"
            peers["$current_peer,rx"]=$rx
            peers["$current_peer,tx"]=$tx
        fi
    done <<< "$show_output"

    if [ ${#peers[@]} -eq 0 ]; then
        echo "No peer usage data available."
        return
    fi

    if command -v column &> /dev/null; then
        {
            echo -e "User\t\tReceived\tSent"
            for key in "${!peers[@]}"; do
                IFS=',' read -r pubkey type <<< "$key"
                if [[ $type == "rx" ]]; then
                    rx="${peers[$key]}"
                elif [[ $type == "tx" ]]; then
                    tx="${peers[$key]}"
                    username="${user_map[$pubkey]}"
                    [ -z "$username" ] && username="$pubkey"
                    if [ "$rx" -gt 0 ] || [ "$tx" -gt 0 ]; then
                        rx_hr=$(numfmt --to=iec --format="%.1f" "$rx")
                        tx_hr=$(numfmt --to=iec --format="%.1f" "$tx")
                        echo -e "$username\t$rx_hr\t$tx_hr"
                    fi
                fi
            done
        } | column -t
    else
        echo -e "User\t\tReceived\tSent"
        for key in "${!peers[@]}"; do
            IFS=',' read -r pubkey type <<< "$key"
            if [[ $type == "rx" ]]; then
                rx="${peers[$key]}"
            elif [[ $type == "tx" ]]; then
                tx="${peers[$key]}"
                username="${user_map[$pubkey]}"
                [ -z "$username" ] && username="$pubkey"
                if [ "$rx" -gt 0 ] || [ "$tx" -gt 0 ]; then
                    rx_hr=$(numfmt --to=iec --format="%.1f" "$rx")
                    tx_hr=$(numfmt --to=iec --format="%.1f" "$tx")
                    echo -e "$username\t$rx_hr\t$tx_hr"
                fi
            fi
        done
    fi
}

check_wireguard_status() {
    print_message "$YELLOW" "Checking WireGuard status..."

    if [[ -f /etc/wireguard/wg_manager.conf ]]; then
        source /etc/wireguard/wg_manager.conf
    else
        print_message "$RED" "Error: wg_manager.conf not found. Cannot determine WireGuard status."
        return 1
    fi

    if ip link show wg0 up &> /dev/null; then
        print_message "$GREEN" "WireGuard is running."
    else
        print_message "$RED" "WireGuard is not running."
    fi

    echo "Current WireGuard port: $WG_PORT"
    wg show wg0 public-key | awk '{print "Interface: wg0\n  Public Key:", $0}'
    echo "  Private Key: (hidden)"
    echo "  Listening Port: $WG_PORT"
}

check_wireguard_accessibility() {
    local LINE_TOP="════════════════════════════════════════════════════════════"
    local LINE_BOT="════════════════════════════════════════════════════════════"

    print_message "$CYAN" "$LINE_TOP"
    print_message "$CYAN" "              WIREGUARD ACCESSIBILITY CHECK"
    print_message "$CYAN" "$LINE_TOP"

    local PUBLIC_IP
    local WG_PORT
    local WG_LISTENING=false
    local UFW_RULE=false
    local UDP_ACCESSIBLE=false

    PUBLIC_IP="$(curl -s https://api.ipify.org || echo "Unavailable")"
    WG_PORT="$(wg show all listen-port | awk '{print $2}')"

    if [ -z "$WG_PORT" ]; then
        WG_PORT="$(grep ListenPort /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')"
    fi

    if [ -z "$WG_PORT" ]; then
        print_message "$RED" "Unable to determine the WireGuard port."
        print_message "$CYAN" "$LINE_BOT"
        return
    fi

    print_message "$YELLOW" "Public IP: $PUBLIC_IP"
    print_message "$YELLOW" "WireGuard Port (UDP): $WG_PORT"
    print_message "$CYAN" "$LINE_TOP"

    if ss -lunp | grep -q ":$WG_PORT"; then
        WG_LISTENING=true
        print_message "$GREEN" "✅ WireGuard is listening on UDP port $WG_PORT."
    else
        print_message "$RED" "❌ WireGuard does not appear to be listening on UDP port $WG_PORT."
    fi

    if command -v ufw &>/dev/null; then
        print_message "$YELLOW" "Checking UFW rules..."
        if ufw status | grep -q "$WG_PORT/udp.*ALLOW"; then
            UFW_RULE=true
            print_message "$GREEN" "✅ UFW has a rule allowing traffic on port $WG_PORT/udp."
        else
            print_message "$RED" "❌ No UFW rule found allowing traffic on port $WG_PORT/udp."
        fi
    else
        print_message "$YELLOW" "UFW is not installed on this system."
    fi

    if ! command -v nc &>/dev/null; then
        print_message "$RED" "The 'nc' (netcat) command is not installed. Installing..."
        apt update && apt install -y netcat
    fi

    print_message "$CYAN" "$LINE_TOP"
    if [ "$WG_LISTENING" = true ]; then
        print_message "$YELLOW" "Attempting a UDP check on $PUBLIC_IP:$WG_PORT with: nc -u -vz"
        if timeout 5 nc -u -vz "$PUBLIC_IP" "$WG_PORT" 2>&1 | grep -iq 'open'; then
            UDP_ACCESSIBLE=true
            print_message "$GREEN" "✅ UDP port $WG_PORT appears open from the outside (netcat)."
        else
            print_message "$RED" "❌ UDP port $WG_PORT did not respond to netcat."
            print_message "$YELLOW" "WireGuard often does not reply to empty UDP probes."
            print_message "$YELLOW" "If remote clients can connect, it's functioning correctly."
        fi
    else
        print_message "$RED" "Skipping external connectivity check (WireGuard not listening)."
    fi

    print_message "$CYAN" "$LINE_TOP"
    print_message "$YELLOW" "Summary of Results:"

    if [ "$WG_LISTENING" = true ]; then
        print_message "$GREEN" " • WireGuard is listening on UDP port $WG_PORT."
    else
        print_message "$RED" " • WireGuard is NOT listening on UDP port $WG_PORT."
    fi

    if command -v ufw &>/dev/null; then
        if [ "$UFW_RULE" = true ]; then
            print_message "$GREEN" " • UFW rule allows UDP port $WG_PORT."
        else
            print_message "$RED" " • No UFW rule for UDP port $WG_PORT."
        fi
    fi

    if [ "$WG_LISTENING" = true ]; then
        if [ "$UDP_ACCESSIBLE" = true ]; then
            print_message "$GREEN" " • Netcat suggests UDP port $WG_PORT is reachable."
        else
            print_message "$RED" " • Netcat did NOT confirm UDP port $WG_PORT is open."
            print_message "$RED" "   It may still be open if clients can connect."
        fi
    fi

    print_message "$CYAN" "$LINE_TOP"
    print_message "$YELLOW" "Would you like to run an Nmap UDP scan on port $WG_PORT? (y/N)"
    read -r user_choice
    if [[ "$user_choice" =~ ^[Yy]$ ]]; then
        if ! command -v nmap &>/dev/null; then
            print_message "$RED" "Nmap is not installed. Installing..."
            apt update && apt install -y nmap
        fi

        print_message "$YELLOW" "Starting Nmap UDP scan on $PUBLIC_IP:$WG_PORT..."

        if [ "$(id -u)" -eq 0 ]; then
            nmap -sU -p "$WG_PORT" "$PUBLIC_IP"
        else
            if command -v sudo &>/dev/null; then
                if sudo -n true 2>/dev/null; then
                    sudo nmap -sU -p "$WG_PORT" "$PUBLIC_IP"
                else
                    print_message "$YELLOW" "Sudo privileges are required for a more complete UDP scan. Continue? (y/N)"
                    read -r sudo_choice
                    if [[ "$sudo_choice" =~ ^[Yy]$ ]]; then
                        sudo nmap -sU -p "$WG_PORT" "$PUBLIC_IP"
                    else
                        print_message "$RED" "Running Nmap without sudo. Results may be incomplete."
                        nmap -sU -p "$WG_PORT" "$PUBLIC_IP"
                    fi
                fi
            else
                print_message "$RED" "sudo is not installed or unavailable. Running Nmap as current user."
                nmap -sU -p "$WG_PORT" "$PUBLIC_IP"
            fi
        fi
    else
        print_message "$YELLOW" "Skipping Nmap UDP scan."
    fi

    print_message "$CYAN" "$LINE_BOT"
    print_message "$CYAN" "           ACCESSIBILITY CHECK COMPLETED"
    print_message "$CYAN" "$LINE_BOT"
}
