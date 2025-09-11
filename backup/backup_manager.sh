#!/bin/bash
#
# Backup Manager Script
# Simple yet flexible backup solution for Linux systems
# Supports incremental backups and configurable retention
#

# Configuration
SCRIPT_NAME="backup_manager"
CONFIG_DIR="$HOME/.config/$SCRIPT_NAME"
CONFIG_FILE="$CONFIG_DIR/backup.conf"
LOG_FILE="$CONFIG_DIR/backup.log"

# Default values
DEFAULT_BACKUP_DIR="$HOME/backups"
DEFAULT_RETENTION_DAYS=30
DEFAULT_COMPRESSION="gzip"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Print colored output
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Create config directory if it doesn't exist
init_config() {
    mkdir -p "$CONFIG_DIR"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << EOF
# Backup Manager Configuration
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
RETENTION_DAYS=$DEFAULT_RETENTION_DAYS
COMPRESSION="$DEFAULT_COMPRESSION"

# Source directories to backup (one per line)
# Example:
# SOURCES=(
#     "$HOME/Documents"
#     "$HOME/Pictures"
#     "/etc"
# )
SOURCES=()
EOF
        print_color "$GREEN" "Created default config at: $CONFIG_FILE"
        print_color "$YELLOW" "Please edit the configuration file to add source directories."
    fi
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        init_config
        exit 1
    fi
}

# Create backup
create_backup() {
    local backup_name="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    if [[ -z "$backup_name" ]]; then
        backup_name="backup_$timestamp"
    else
        backup_name="${backup_name}_$timestamp"
    fi
    
    local backup_path="$BACKUP_DIR/$backup_name"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    print_color "$BLUE" "Starting backup: $backup_name"
    log_message "INFO" "Starting backup: $backup_name"
    
    # Check if sources are defined
    if [[ ${#SOURCES[@]} -eq 0 ]]; then
        print_color "$RED" "No source directories defined in configuration!"
        log_message "ERROR" "No source directories defined"
        exit 1
    fi
    
    # Create backup archive
    local tar_options="-cf"
    local archive_ext=".tar"
    
    case "$COMPRESSION" in
        "gzip")
            tar_options="-czf"
            archive_ext=".tar.gz"
            ;;
        "bzip2")
            tar_options="-cjf"
            archive_ext=".tar.bz2"
            ;;
        "xz")
            tar_options="-cJf"
            archive_ext=".tar.xz"
            ;;
    esac
    
    local archive_path="$backup_path$archive_ext"
    
    # Perform backup
    if tar $tar_options "$archive_path" "${SOURCES[@]}" 2>/dev/null; then
        local backup_size=$(du -h "$archive_path" | cut -f1)
        print_color "$GREEN" "Backup completed successfully!"
        print_color "$GREEN" "Archive: $archive_path"
        print_color "$GREEN" "Size: $backup_size"
        log_message "INFO" "Backup completed: $archive_path ($backup_size)"
    else
        print_color "$RED" "Backup failed!"
        log_message "ERROR" "Backup failed: $archive_path"
        rm -f "$archive_path" 2>/dev/null
        exit 1
    fi
}

# List backups
list_backups() {
    print_color "$BLUE" "Available backups in $BACKUP_DIR:"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_color "$YELLOW" "Backup directory does not exist."
        return
    fi
    
    find "$BACKUP_DIR" -name "*.tar*" -type f -printf '%T@ %TY-%Tm-%Td %TH:%TM %s %p\n' | \
    sort -n | \
    while read timestamp date time size path; do
        local human_size=$(echo "$size" | numfmt --to=iec)
        local basename=$(basename "$path")
        echo "$date $time $human_size $basename"
    done
}

# Clean old backups
cleanup_backups() {
    local days=${1:-$RETENTION_DAYS}
    
    print_color "$BLUE" "Cleaning backups older than $days days..."
    log_message "INFO" "Starting cleanup: removing backups older than $days days"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_color "$YELLOW" "Backup directory does not exist."
        return
    fi
    
    local count=0
    while IFS= read -r -d '' file; do
        rm -f "$file"
        print_color "$YELLOW" "Removed: $(basename "$file")"
        log_message "INFO" "Removed old backup: $file"
        ((count++))
    done < <(find "$BACKUP_DIR" -name "*.tar*" -type f -mtime +$days -print0)
    
    if [[ $count -eq 0 ]]; then
        print_color "$GREEN" "No old backups to clean."
    else
        print_color "$GREEN" "Cleaned $count old backup(s)."
    fi
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

COMMANDS:
    backup [NAME]     Create a new backup with optional name
    list              List all available backups
    cleanup [DAYS]    Remove backups older than DAYS (default: $DEFAULT_RETENTION_DAYS)
    init              Initialize configuration
    
OPTIONS:
    -h, --help        Show this help message
    
CONFIGURATION:
    Config file: $CONFIG_FILE
    Log file: $LOG_FILE
    
EXAMPLES:
    $0 backup
    $0 backup "weekly_backup"
    $0 list
    $0 cleanup 7
EOF
}

# Main function
main() {
    case "$1" in
        "backup")
            load_config
            create_backup "$2"
            ;;
        "list")
            load_config
            list_backups
            ;;
        "cleanup")
            load_config
            cleanup_backups "$2"
            ;;
        "init")
            init_config
            ;;
        "-h"|"--help"|"help"|"")
            usage
            ;;
        *)
            print_color "$RED" "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"