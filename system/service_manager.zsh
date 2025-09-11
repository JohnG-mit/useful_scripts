#!/bin/bash
#
# Service Manager - ZSH script for managing systemd services
# Provides a user-friendly interface for common service operations
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script name
SCRIPT_NAME="service_manager"

# Print colored output
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Check if running with appropriate privileges
check_privileges() {
    if [[ $EUID -ne 0 ]] && [[ "$1" =~ ^(start|stop|restart|reload|enable|disable)$ ]]; then
        print_color "$RED" "Error: This operation requires root privileges."
        print_color "$YELLOW" "Please run with sudo or as root."
        exit 1
    fi
}

# Get service status with colored output
get_service_status() {
    local service="$1"
    local status=$(systemctl is-active "$service" 2>/dev/null)
    local enabled=$(systemctl is-enabled "$service" 2>/dev/null)
    
    case "$status" in
        "active")
            status_color="$GREEN"
            ;;
        "inactive"|"failed")
            status_color="$RED"
            ;;
        *)
            status_color="$YELLOW"
            ;;
    esac
    
    case "$enabled" in
        "enabled")
            enabled_color="$GREEN"
            ;;
        "disabled")
            enabled_color="$RED"
            ;;
        *)
            enabled_color="$YELLOW"
            ;;
    esac
    
    printf "%-25s ${status_color}%-10s${NC} ${enabled_color}%-10s${NC}\n" "$service" "$status" "$enabled"
}

# List services
list_services() {
    local filter="$1"
    
    print_color "$BLUE" "=== System Services ==="
    printf "%-25s %-10s %-10s\n" "SERVICE" "STATUS" "ENABLED"
    print_color "$CYAN" "$(printf '%.60s' "$(yes '-' | head -60 | tr -d '\n')")"
    
    if [[ -n "$filter" ]]; then
        systemctl list-units --type=service --no-legend | \
        grep "$filter" | \
        awk '{print $1}' | \
        sed 's/\.service$//' | \
        while read service; do
            get_service_status "$service"
        done
    else
        systemctl list-units --type=service --no-legend | \
        awk '{print $1}' | \
        sed 's/\.service$//' | \
        while read service; do
            get_service_status "$service"
        done
    fi
}

# Show detailed service information
show_service_info() {
    local service="$1"
    
    if [[ -z "$service" ]]; then
        print_color "$RED" "Error: Service name required"
        return 1
    fi
    
    print_color "$BLUE" "=== Service Information: $service ==="
    
    # Basic status
    echo
    print_color "$CYAN" "Status:"
    systemctl status "$service" --no-pager
    
    # Service file location
    echo
    print_color "$CYAN" "Service File:"
    systemctl show "$service" -p FragmentPath --no-pager
    
    # Dependencies
    echo
    print_color "$CYAN" "Dependencies:"
    systemctl list-dependencies "$service" --no-pager
}

# Control service (start, stop, restart, etc.)
control_service() {
    local action="$1"
    local service="$2"
    
    if [[ -z "$service" ]]; then
        print_color "$RED" "Error: Service name required"
        return 1
    fi
    
    check_privileges "$action"
    
    print_color "$BLUE" "Performing action: $action on service: $service"
    
    case "$action" in
        "start")
            systemctl start "$service"
            ;;
        "stop")
            systemctl stop "$service"
            ;;
        "restart")
            systemctl restart "$service"
            ;;
        "reload")
            systemctl reload "$service"
            ;;
        "enable")
            systemctl enable "$service"
            ;;
        "disable")
            systemctl disable "$service"
            ;;
        *)
            print_color "$RED" "Error: Unknown action: $action"
            return 1
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        print_color "$GREEN" "Action '$action' completed successfully for service '$service'"
        echo
        get_service_status "$service"
    else
        print_color "$RED" "Action '$action' failed for service '$service'"
        return 1
    fi
}

# Show service logs
show_logs() {
    local service="$1"
    local lines="${2:-50}"
    local follow="$3"
    
    if [[ -z "$service" ]]; then
        print_color "$RED" "Error: Service name required"
        return 1
    fi
    
    print_color "$BLUE" "=== Logs for service: $service ==="
    
    if [[ "$follow" == "follow" ]]; then
        print_color "$YELLOW" "Following logs (Ctrl+C to exit)..."
        journalctl -u "$service" -f
    else
        journalctl -u "$service" -n "$lines" --no-pager
    fi
}

# Interactive service selection
interactive_select() {
    local services=($(systemctl list-units --type=service --no-legend | awk '{print $1}' | sed 's/\.service$//'))
    
    if [[ ${#services[@]} -eq 0 ]]; then
        print_color "$RED" "No services found"
        return 1
    fi
    
    print_color "$BLUE" "Select a service:"
    
    # Use fzf if available, otherwise use basic selection
    if command -v fzf >/dev/null 2>&1; then
        local selected=$(printf '%s\n' "${services[@]}" | fzf --height=10 --prompt="Service> ")
        echo "$selected"
    else
        # Basic selection with numbers
        for i in {1..${#services[@]}}; do
            printf "%3d) %s\n" "$i" "${services[$i]}"
        done
        
        echo
        read "selection?Enter service number: "
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#services[@]} ]]; then
            echo "${services[$selection]}"
        else
            print_color "$RED" "Invalid selection"
            return 1
        fi
    fi
}

# Show usage help
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [COMMAND] [OPTIONS]

COMMANDS:
    list [FILTER]           List all services (optionally filter by name)
    info SERVICE            Show detailed information about a service
    start SERVICE           Start a service
    stop SERVICE            Stop a service
    restart SERVICE         Restart a service
    reload SERVICE          Reload a service configuration
    enable SERVICE          Enable a service to start at boot
    disable SERVICE         Disable a service from starting at boot
    logs SERVICE [LINES]    Show logs for a service (default: 50 lines)
    follow SERVICE          Follow logs for a service in real-time
    interactive             Interactive service selection
    
OPTIONS:
    -h, --help              Show this help message

EXAMPLES:
    $SCRIPT_NAME list                    # List all services
    $SCRIPT_NAME list ssh                # List services containing 'ssh'
    $SCRIPT_NAME info nginx              # Show nginx service information
    $SCRIPT_NAME start apache2           # Start apache2 service
    $SCRIPT_NAME logs nginx 100          # Show last 100 log entries for nginx
    $SCRIPT_NAME follow sshd             # Follow sshd logs in real-time
    $SCRIPT_NAME interactive             # Interactive mode

NOTE: Service control commands (start/stop/restart/reload/enable/disable) require root privileges.
EOF
}

# Main function
main() {
    case "$1" in
        "list")
            list_services "$2"
            ;;
        "info")
            show_service_info "$2"
            ;;
        "start"|"stop"|"restart"|"reload"|"enable"|"disable")
            control_service "$1" "$2"
            ;;
        "logs")
            show_logs "$2" "$3"
            ;;
        "follow")
            show_logs "$2" "50" "follow"
            ;;
        "interactive")
            selected=$(interactive_select)
            if [[ -n "$selected" ]]; then
                print_color "$GREEN" "Selected service: $selected"
                show_service_info "$selected"
            fi
            ;;
        "-h"|"--help"|"help"|"")
            usage
            ;;
        *)
            print_color "$RED" "Unknown command: $1"
            echo
            usage
            exit 1
            ;;
    esac
}

main "$@"