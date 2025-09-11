#!/bin/bash
#
# Security Scanner - Basic security assessment script
# Performs common security checks on Linux systems
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_NAME="security_scanner"
REPORT_DIR="/tmp/security_scan_$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$REPORT_DIR/security_report.txt"

# Print colored output
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}" | tee -a "$REPORT_FILE"
}

# Log function
log_info() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $message" | tee -a "$REPORT_FILE"
}

# Initialize report
init_report() {
    mkdir -p "$REPORT_DIR"
    cat > "$REPORT_FILE" << EOF
Security Scan Report
Generated on: $(date)
Hostname: $(hostname)
User: $(whoami)
======================================

EOF
}

# Check for running services
check_services() {
    print_color "$BLUE" "=== Checking Running Services ==="
    log_info "Checking for potentially risky services"
    
    # High-risk services to check
    local risky_services=("telnet" "rsh" "rlogin" "ftp" "tftp" "finger" "rwho")
    
    print_color "$CYAN" "Checking for risky services:"
    for service in "${risky_services[@]}"; do
        if systemctl is-active "$service" &>/dev/null; then
            print_color "$RED" "  WARNING: $service is running (potential security risk)"
        else
            print_color "$GREEN" "  OK: $service is not running"
        fi
    done
    
    # List all listening ports
    print_color "$CYAN" "\nOpen ports and services:"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep LISTEN | tee -a "$REPORT_FILE"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep LISTEN | tee -a "$REPORT_FILE"
    else
        print_color "$YELLOW" "  Neither ss nor netstat available to check open ports"
    fi
    
    echo "" | tee -a "$REPORT_FILE"
}

# Check file permissions
check_permissions() {
    print_color "$BLUE" "=== Checking Critical File Permissions ==="
    log_info "Checking permissions on critical system files"
    
    # Critical files to check
    local critical_files=(
        "/etc/passwd:644"
        "/etc/shadow:640"
        "/etc/group:644"
        "/etc/gshadow:640"
        "/etc/sudoers:440"
    )
    
    for file_perm in "${critical_files[@]}"; do
        IFS=':' read -r file expected_perm <<< "$file_perm"
        
        if [[ -f "$file" ]]; then
            actual_perm=$(stat -c "%a" "$file")
            if [[ "$actual_perm" == "$expected_perm" ]]; then
                print_color "$GREEN" "  OK: $file has correct permissions ($actual_perm)"
            else
                print_color "$RED" "  WARNING: $file has permissions $actual_perm (expected: $expected_perm)"
            fi
        else
            print_color "$YELLOW" "  INFO: $file does not exist"
        fi
    done
    
    # Check for world-writable files in critical directories
    print_color "$CYAN" "\nChecking for world-writable files in /etc:"
    local world_writable=$(find /etc -type f -perm -002 2>/dev/null)
    if [[ -n "$world_writable" ]]; then
        print_color "$RED" "  WARNING: World-writable files found in /etc:"
        echo "$world_writable" | while read -r file; do
            print_color "$RED" "    $file"
        done
    else
        print_color "$GREEN" "  OK: No world-writable files found in /etc"
    fi
    
    echo "" | tee -a "$REPORT_FILE"
}

# Check user accounts
check_users() {
    print_color "$BLUE" "=== Checking User Accounts ==="
    log_info "Analyzing user accounts and privileges"
    
    # Check for accounts with UID 0
    print_color "$CYAN" "Accounts with UID 0 (root privileges):"
    local root_accounts=$(awk -F: '$3==0 {print $1}' /etc/passwd)
    if [[ "$root_accounts" == "root" ]]; then
        print_color "$GREEN" "  OK: Only root account has UID 0"
    else
        print_color "$RED" "  WARNING: Multiple accounts with UID 0 found:"
        echo "$root_accounts" | while read -r account; do
            print_color "$RED" "    $account"
        done
    fi
    
    # Check for accounts without passwords
    print_color "$CYAN" "\nChecking for accounts without passwords:"
    if [[ -r /etc/shadow ]]; then
        local no_pass_accounts=$(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null)
        if [[ -n "$no_pass_accounts" ]]; then
            print_color "$RED" "  WARNING: Accounts without passwords found:"
            echo "$no_pass_accounts" | while read -r account; do
                print_color "$RED" "    $account"
            done
        else
            print_color "$GREEN" "  OK: All accounts have passwords set"
        fi
    else
        print_color "$YELLOW" "  INFO: Cannot read /etc/shadow (insufficient permissions)"
    fi
    
    # Check sudo access
    print_color "$CYAN" "\nUsers with sudo privileges:"
    if command -v getent >/dev/null 2>&1; then
        local sudo_users=$(getent group sudo 2>/dev/null | cut -d: -f4)
        local admin_users=$(getent group admin 2>/dev/null | cut -d: -f4)
        
        if [[ -n "$sudo_users" ]]; then
            print_color "$YELLOW" "  Sudo group members: $sudo_users"
        fi
        if [[ -n "$admin_users" ]]; then
            print_color "$YELLOW" "  Admin group members: $admin_users"
        fi
    fi
    
    echo "" | tee -a "$REPORT_FILE"
}

# Check SSH configuration
check_ssh() {
    print_color "$BLUE" "=== Checking SSH Configuration ==="
    log_info "Analyzing SSH daemon configuration"
    
    local ssh_config="/etc/ssh/sshd_config"
    
    if [[ ! -f "$ssh_config" ]]; then
        print_color "$YELLOW" "  SSH configuration file not found"
        return
    fi
    
    # Check important SSH settings
    print_color "$CYAN" "SSH security settings:"
    
    # Root login
    local root_login=$(grep -E "^PermitRootLogin" "$ssh_config" | awk '{print $2}')
    if [[ "$root_login" == "no" ]]; then
        print_color "$GREEN" "  OK: Root login is disabled"
    elif [[ "$root_login" == "yes" ]]; then
        print_color "$RED" "  WARNING: Root login is enabled"
    else
        print_color "$YELLOW" "  INFO: Root login setting: ${root_login:-default}"
    fi
    
    # Password authentication
    local pass_auth=$(grep -E "^PasswordAuthentication" "$ssh_config" | awk '{print $2}')
    if [[ "$pass_auth" == "no" ]]; then
        print_color "$GREEN" "  OK: Password authentication is disabled (key-based auth)"
    else
        print_color "$YELLOW" "  INFO: Password authentication: ${pass_auth:-default}"
    fi
    
    # Protocol version
    local protocol=$(grep -E "^Protocol" "$ssh_config" | awk '{print $2}')
    if [[ "$protocol" == "2" ]]; then
        print_color "$GREEN" "  OK: Using SSH protocol version 2"
    elif [[ -n "$protocol" ]]; then
        print_color "$RED" "  WARNING: Using SSH protocol version $protocol (should be 2)"
    fi
    
    # Empty passwords
    local empty_pass=$(grep -E "^PermitEmptyPasswords" "$ssh_config" | awk '{print $2}')
    if [[ "$empty_pass" == "no" ]]; then
        print_color "$GREEN" "  OK: Empty passwords are not permitted"
    elif [[ "$empty_pass" == "yes" ]]; then
        print_color "$RED" "  WARNING: Empty passwords are permitted"
    fi
    
    echo "" | tee -a "$REPORT_FILE"
}

# Check system updates
check_updates() {
    print_color "$BLUE" "=== Checking System Updates ==="
    log_info "Checking for available security updates"
    
    # Detect package manager and check updates
    if command -v apt >/dev/null 2>&1; then
        print_color "$CYAN" "Checking for APT updates..."
        apt list --upgradable 2>/dev/null | grep -c "upgradable" > /dev/null
        local update_count=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
        if [[ "$update_count" -gt 0 ]]; then
            print_color "$YELLOW" "  $update_count package updates available"
        else
            print_color "$GREEN" "  System is up to date"
        fi
        
    elif command -v yum >/dev/null 2>&1; then
        print_color "$CYAN" "Checking for YUM updates..."
        local update_count=$(yum check-update -q | wc -l)
        if [[ "$update_count" -gt 0 ]]; then
            print_color "$YELLOW" "  $update_count package updates available"
        else
            print_color "$GREEN" "  System is up to date"
        fi
        
    elif command -v dnf >/dev/null 2>&1; then
        print_color "$CYAN" "Checking for DNF updates..."
        local update_count=$(dnf check-update -q | wc -l)
        if [[ "$update_count" -gt 0 ]]; then
            print_color "$YELLOW" "  $update_count package updates available"
        else
            print_color "$GREEN" "  System is up to date"
        fi
        
    else
        print_color "$YELLOW" "  Unknown package manager - cannot check for updates"
    fi
    
    echo "" | tee -a "$REPORT_FILE"
}

# Check firewall status
check_firewall() {
    print_color "$BLUE" "=== Checking Firewall Status ==="
    log_info "Checking firewall configuration"
    
    # Check UFW
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status=$(ufw status | head -1)
        if [[ "$ufw_status" == *"active"* ]]; then
            print_color "$GREEN" "  UFW firewall is active"
        else
            print_color "$RED" "  WARNING: UFW firewall is inactive"
        fi
        ufw status | tee -a "$REPORT_FILE"
        
    # Check iptables
    elif command -v iptables >/dev/null 2>&1; then
        local rule_count=$(iptables -L | grep -c "^Chain")
        if [[ "$rule_count" -gt 3 ]]; then
            print_color "$GREEN" "  iptables rules are configured"
        else
            print_color "$YELLOW" "  WARNING: Basic iptables configuration detected"
        fi
        
    # Check firewalld
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state &>/dev/null; then
            print_color "$GREEN" "  firewalld is running"
        else
            print_color "$RED" "  WARNING: firewalld is not running"
        fi
        
    else
        print_color "$RED" "  WARNING: No firewall detected"
    fi
    
    echo "" | tee -a "$REPORT_FILE"
}

# Generate summary
generate_summary() {
    print_color "$BLUE" "=== Security Scan Summary ==="
    print_color "$CYAN" "Report saved to: $REPORT_FILE"
    print_color "$CYAN" "Scan completed at: $(date)"
    
    # Count warnings and errors in report
    local warning_count=$(grep -c "WARNING" "$REPORT_FILE")
    local ok_count=$(grep -c "OK" "$REPORT_FILE")
    
    print_color "$YELLOW" "\nScan Results:"
    print_color "$GREEN" "  ✓ OK checks: $ok_count"
    print_color "$RED" "  ⚠ Warnings: $warning_count"
    
    if [[ "$warning_count" -eq 0 ]]; then
        print_color "$GREEN" "\n✓ No security warnings found!"
    else
        print_color "$YELLOW" "\n⚠ Please review the warnings above and take appropriate action."
    fi
}

# Show usage
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --services      Check only running services
    --permissions   Check only file permissions
    --users         Check only user accounts
    --ssh           Check only SSH configuration
    --updates       Check only system updates
    --firewall      Check only firewall status
    --all           Run all checks (default)
    -h, --help      Show this help message

EXAMPLES:
    $SCRIPT_NAME                # Run all security checks
    $SCRIPT_NAME --ssh          # Check only SSH configuration
    $SCRIPT_NAME --services     # Check only running services
EOF
}

# Main function
main() {
    local run_all=true
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --services)
                run_all=false
                init_report
                check_services
                ;;
            --permissions)
                run_all=false
                init_report
                check_permissions
                ;;
            --users)
                run_all=false
                init_report
                check_users
                ;;
            --ssh)
                run_all=false
                init_report
                check_ssh
                ;;
            --updates)
                run_all=false
                init_report
                check_updates
                ;;
            --firewall)
                run_all=false
                init_report
                check_firewall
                ;;
            --all)
                run_all=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_color "$RED" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
    
    # Run all checks if no specific check was requested
    if [[ "$run_all" == true ]]; then
        init_report
        print_color "$BLUE" "Starting comprehensive security scan..."
        check_services
        check_permissions
        check_users
        check_ssh
        check_updates
        check_firewall
        generate_summary
    fi
}

main "$@"