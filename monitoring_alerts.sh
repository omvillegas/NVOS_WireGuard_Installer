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

show_usage_stats() {
    print_message "$YELLOW" "WireGuard Usage Statistics:"
    if command -v column &> /dev/null; then
        {
            # Extract and print the header
            echo -e "Peer\tReceived\tSent"
            # Extract the data, format it, and apply numfmt
            wg show all dump | awk '{print $1, $6, $7}' | \
                numfmt --to=iec --field=2,3
        } | column -t
    else
        wg show all dump | awk '{print $1 " Received:" $6 " Sent:" $7}'
    fi
}

check_wireguard_status() {
    print_message "$YELLOW" "Checking WireGuard status..."

    # Source wg_manager.conf to get necessary variables
    if [[ -f /etc/wireguard/wg_manager.conf ]]; then
        source /etc/wireguard/wg_manager.conf
    else
        print_message "$RED" "Error: wg_manager.conf not found. Cannot determine WireGuard status."
        return 1
    fi

    # Check if the WireGuard interface is up
    if ip link show wg0 up &> /dev/null; then
        print_message "$GREEN" "WireGuard is running."
    else
        print_message "$RED" "WireGuard is not running."
    fi

    # Display current WireGuard configuration
    echo "Current WireGuard port: $WG_PORT"
    wg show wg0 public-key | awk '{print "Interface: wg0\n  Public Key:", $0}'
    echo "  Private Key: (hidden)"
    echo "  Listening Port: $WG_PORT"
}

check_wireguard_accessibility() {
    print_message "$YELLOW" "Checking WireGuard accessibility..."

    local PUBLIC_IP=$(curl -s https://api.ipify.org)
    local WG_PORT=$(wg show all listen-port | awk '{print $2}')

    if [ -z "$WG_PORT" ]; then
        WG_PORT=$(grep ListenPort /etc/wireguard/wg0.conf | awk '{print $3}')
    fi

    print_message "$YELLOW" "Public IP: $PUBLIC_IP"
    print_message "$YELLOW" "WireGuard Port: $WG_PORT"

    if ! command -v nc &> /dev/null; then
        print_message "$RED" "The 'nc' (netcat) command is not installed. Installing..."
        apt update && apt install -y netcat
    fi

    if nc -zv -w5 $PUBLIC_IP $WG_PORT 2>&1 | grep -q 'open'; then
        print_message "$GREEN" "✅ Port $WG_PORT is open and accessible from the Internet."
    else
        print_message "$RED" "❌ Port $WG_PORT appears to be closed or blocked."
        print_message "$YELLOW" "Possible causes:"
        print_message "$YELLOW" "  - The server firewall may be blocking access."
        print_message "$YELLOW" "  - The Internet Service Provider may be blocking the port."
        print_message "$YELLOW" "  - An external network firewall may be interfering."
    fi

    if command -v ufw &> /dev/null; then
        print_message "$YELLOW" "Checking UFW rules..."
        if ufw status | grep -q "$WG_PORT/udp.*ALLOW"; then
            print_message "$GREEN" "✅ UFW has a rule allowing traffic on port $WG_PORT/udp."
        else
            print_message "$RED" "❌ No UFW rule found to allow traffic on port $WG_PORT/udp."
        fi
    else
        print_message "$YELLOW" "UFW is not installed on this system."
    fi

    if ss -lnup | grep -q ":$WG_PORT"; then
        print_message "$GREEN" "✅ WireGuard is listening correctly on port $WG_PORT."
    else
        print_message "$RED" "❌ WireGuard does not appear to be listening on port $WG_PORT."
    fi

    print_message "$YELLOW" "Accessibility check completed."
}
