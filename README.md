# WireGuard Manager - README

## Introduction

This repository provides a comprehensive set of bash scripts designed to manage WireGuard VPN on Ubuntu 22.04 LTS. The scripts cover various tasks, including installation, configuration, user management, monitoring, backup, and restoration of WireGuard configurations. Note that these scripts have only been tested on Ubuntu 22.04 LTS, and network configurations must be adjusted accordingly to publish the service.

## Prerequisites

- **Operating System**: Ubuntu 22.04 LTS
- **User Privileges**: Root user or sudo privileges

## Installation

1. Clone the repository to your server:
    ```bash
    git clone https://github.com/omvillegas/NVOS_WireGuard_Installer.git
    cd NVOS_WireGuard_Installer
    ```

2. Ensure all scripts are executable:
    ```bash
    chmod +x *.sh
    ```

3. Run the main script to start the WireGuard Manager:
    ```bash
    sudo ./wireguard_manager.sh
    ```

## Usage

All functionalities are accessed through the `wireguard_manager.sh` script. This script provides a menu-based interface to manage WireGuard. You do not need to run individual scripts manually.

### Main Menu

After running the `wireguard_manager.sh` script, you will see a menu with the following options:

1. Auto-Configure Server
2. Install WireGuard
3. Generate User Certificates
4. Remove User Certificates
5. List Current Users
6. Generate QR Code for User
7. Check WireGuard Status
8. Show Usage Statistics
9. Update System and WireGuard
10. Rotate Server Keys
11. Configure fail2ban
12. Backup WireGuard Configuration
13. Restore WireGuard Configuration
14. Change WireGuard Port
15. Uninstall WireGuard
16. Check WireGuard Accessibility
17. Exit

### Detailed Function Descriptions

#### Auto-Configure Server
This option performs several tasks to set up WireGuard:
- **Detect Network Configuration**: Identifies the network interface and server IP address, and generates a random WireGuard port.
- **Install WireGuard**: Installs WireGuard on the system.
- **Configure WireGuard Server**: Sets up WireGuard configuration files.
- **Configure UFW**: Adjusts UFW rules to allow traffic on the WireGuard port.

#### Install WireGuard
Installs the WireGuard package on your system:
- Updates the package list.
- Installs the WireGuard package.

#### Generate User Certificates
Generates WireGuard configuration files for users listed in `users.csv`:
- Reads the user details from `users.csv`.
- Generates client configuration files and keys.
- Adds users to the WireGuard server.

#### Remove User Certificates
Removes the WireGuard configuration files for selected users:
- Lists existing users.
- Prompts to select users for removal.
- Removes the user configuration and keys from the server.

#### List Current Users
Displays a list of current WireGuard users:
- Reads the user database.
- Outputs the list of users along with their details.

#### Generate QR Code for User
Generates a QR code for the selected user's configuration:
- Prompts for the username.
- Generates a QR code from the user's configuration file for easy mobile client setup.

#### Check WireGuard Status
Checks if the WireGuard service is running and displays its status:
- Checks the status of the WireGuard service.
- Outputs whether WireGuard is active or not.
- Displays the current WireGuard port and peer information.

#### Show Usage Statistics
Displays usage statistics for WireGuard:
- Shows data usage per peer.
- Formats and presents the data in a readable manner.

#### Update System and WireGuard
Updates the system packages and WireGuard to the latest versions:
- Updates the package list.
- Upgrades all packages to their latest versions.

#### Rotate Server Keys
Rotates the WireGuard server keys and updates client configurations:
- Generates new server keys.
- Updates the server configuration with the new keys.
- Updates client configurations with the new server public key.

#### Configure fail2ban
Configures fail2ban to protect the WireGuard service:
- Sets up fail2ban filters for WireGuard.
- Configures jail rules to monitor WireGuard logs and block IPs after failed connection attempts.

#### Backup WireGuard Configuration
Backs up the current WireGuard configuration:
- Creates a timestamped backup directory.
- Copies the WireGuard configuration files to the backup directory.

#### Restore WireGuard Configuration
Restores a previously backed up WireGuard configuration:
- Lists available backups.
- Prompts to select a backup for restoration.
- Restores the selected backup and restarts the WireGuard service.

#### Change WireGuard Port
Changes the WireGuard listening port and updates UFW rules:
- Prompts for a new port number.
- Updates the WireGuard configuration with the new port.
- Adjusts UFW rules to allow traffic on the new port.
- Restarts the WireGuard service to apply changes.

#### Uninstall WireGuard
Uninstalls WireGuard from the system:
- Stops the WireGuard service.
- Disables the WireGuard service from starting on boot.
- Removes the WireGuard package and configuration files.

#### Check WireGuard Accessibility
Checks if the WireGuard port is accessible from the internet:
- Retrieves the server's public IP.
- Checks if the WireGuard port is open and accessible.
- Verifies firewall rules and network configurations.

#### Exit
Exits the WireGuard Manager menu.

## Network Configuration Considerations

When deploying these scripts, ensure that your network settings allow traffic on the WireGuard port specified in your configurations. This typically involves:

1. **Firewall Configuration**: Ensure the firewall (UFW or another) allows traffic on the WireGuard port.
    ```bash
    sudo ufw allow <WG_PORT>/udp
    sudo ufw reload
    ```

2. **Router Settings**: If behind a NAT router, configure port forwarding to the server's WireGuard port.
3. **Public IP**: Ensure your server has a public IP address or is accessible through a public-facing IP.

### Example Network Configuration

To detect network configuration, select the "Auto-Configure Server" option from the main menu. This script will identify your network interface, server IP, and generate a random WireGuard port. Use these details to configure your firewall and router.

## Logging

All operations are logged to `/var/log/wireguard_manager.log` for troubleshooting and auditing purposes.

## Dependencies

The following dependencies must be installed:

- WireGuard
- UFW
- QRencode
- jq
- Fail2ban
- curl
- Prometheus Node Exporter
- ssmtp

The main script (`wireguard_manager.sh`) checks for and installs these dependencies if missing.

## Conclusion

This set of scripts provides a robust solution for managing WireGuard on Ubuntu 22.04 LTS. Ensure that network configurations are properly adjusted for the service to be accessible. For any issues or improvements, feel free to contribute or raise issues on the repository.