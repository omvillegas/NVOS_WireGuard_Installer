#!/bin/bash
set -e
trap 'print_message "$RED" "An error occurred. Exiting..."; exit 1' ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

LOG_FILE="/var/log/wireguard_manager.log"
CONFIG_FILE="/etc/wireguard/wg_manager.conf"
USER_DB="/etc/wireguard/users.json"

# Import other scripts
source ./network_config.sh
source ./user_management.sh
source ./monitoring_alerts.sh
source ./backup_recovery.sh
source ./system_management.sh

# Logging
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# Check users permissions
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_message "$RED" "This script must be run as root"
        exit 1
    fi
}

# Handling dependencies
check_dependencies() {
    local deps=("wireguard" "ufw" "qrencode" "jq" "fail2ban" "curl" "prometheus-node-exporter" "ssmtp")
    #local deps=("wireguard" "ufw" "qrencode" "jq" "fail2ban" "curl" "prometheus-node-exporter" "ssmtp" "column")
    local missing_deps=()
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            missing_deps+=($dep)
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_message "$YELLOW" "Installing missing dependencies: ${missing_deps[*]}"
        apt update && apt install -y ${missing_deps[@]}
    else
        print_message "$GREEN" "All dependencies are installed."
    fi
}

# Main menu
EXIT_MENU=false
while [ "$EXIT_MENU" = false ]; do
    print_message "$YELLOW" "\nWireGuard Management Menu:"
    echo "1. Auto-Configure Server"
    echo "2. Install WireGuard"
    echo "3. Generate User Certificates"
    echo "4. Remove User Certificates"
    echo "5. List Current Users"
    echo "6. Generate QR Code for User"
    echo "7. Check WireGuard Status"
    echo "8. Show Usage Statistics"
    echo "9. Update System and WireGuard"
    echo "10. Rotate Server Keys"
    echo "11. Configure fail2ban"
    echo "12. Backup WireGuard Configuration"
    echo "13. Restore WireGuard Configuration"
    echo "14. Change WireGuard Port"
    echo "15. Uninstall WireGuard"
    echo "16. Check WireGuard Accessibility"
    echo "17. Exit"

    read -p "Enter your choice: " choice
    case $choice in
        1)
            check_root
            check_dependencies
            detect_network_config
            configure_wireguard_server
            configure_ufw
            ;;
        2)
            check_root
            install_wireguard
            ;;
        3)
            check_root
            generate_user_certificates
            ;;
        4)
            check_root
            remove_user_certificates
            ;;
        5)
            list_users
            ;;
        6)
            read -p "Enter username for generate QR code: " username
            generate_qr_code "$username"
            ;;
        7)
            check_wireguard_status
            ;;
        8)
            show_usage_stats
            ;;
        9)
            check_root
            update_system
            ;;
        10)
            check_root
            rotate_server_keys
            ;;
        11)
            check_root
            configure_fail2ban
            ;;
        12)
            check_root
            backup_wireguard_config
            ;;
        13)
            check_root
            restore_wireguard_config
            ;;
        14)
            check_root
            change_wireguard_port
            ;;
        15)
            check_root
            uninstall_wireguard
            ;;
	16)
            check_root
            check_wireguard_accessibility
            ;;
        17)
            EXIT_MENU=true
            ;;
        *)
            print_message "$RED" "Invalid option. Please try again."
            ;;
    esac
done