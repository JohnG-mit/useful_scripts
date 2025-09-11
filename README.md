# Useful Scripts for Linux Operation and Maintenance

A comprehensive collection of Python and shell scripts designed to help with Linux system administration, monitoring, and maintenance tasks.

## 📁 Repository Structure

```
├── monitoring/           # System monitoring and resource tracking
├── backup/              # Backup and data protection utilities
├── network/             # Network diagnostics and connectivity tools
├── system/              # System administration and service management
├── security/            # Security assessment and monitoring
├── logs/                # Log analysis and management tools
└── docs/                # Documentation and guides
```

## 🛠️ Available Scripts

### System Monitoring (`monitoring/`)

#### `system_monitor.py`
Real-time system resource monitoring tool that tracks CPU, memory, disk usage, and network statistics.

**Features:**
- CPU usage per core and overall
- Memory usage with detailed statistics
- Disk usage for all mounted partitions
- Network I/O statistics
- Load average (Unix systems)
- Configurable monitoring intervals
- Duration-limited monitoring

**Usage:**
```bash
./monitoring/system_monitor.py
./monitoring/system_monitor.py -i 10 -d 300  # Monitor every 10s for 5 minutes
```

**Options:**
- `-i, --interval`: Monitoring interval in seconds (default: 5)
- `-d, --duration`: Duration to monitor in seconds (unlimited by default)

### Backup Management (`backup/`)

#### `backup_manager.sh`
Flexible backup solution with incremental backups and configurable retention.

**Features:**
- Configurable source directories
- Multiple compression options (gzip, bzip2, xz)
- Automatic retention management
- Backup listing and cleanup
- Detailed logging
- Configuration management

**Usage:**
```bash
./backup/backup_manager.sh init           # Initialize configuration
./backup/backup_manager.sh backup         # Create backup
./backup/backup_manager.sh backup "weekly" # Create named backup
./backup/backup_manager.sh list          # List all backups
./backup/backup_manager.sh cleanup 7     # Remove backups older than 7 days
```

**Configuration:**
The script creates a configuration file at `~/.config/backup_manager/backup.conf` where you can specify source directories, backup location, and retention settings.

### Network Diagnostics (`network/`)

#### `network_diagnostics.py`
Comprehensive network connectivity and performance testing tool.

**Features:**
- Multi-threaded ping tests
- Port connectivity scanning
- DNS resolution testing
- Network interface information
- Routing table display
- Traceroute functionality
- Comprehensive reporting

**Usage:**
```bash
./network/network_diagnostics.py                           # Test default hosts
./network/network_diagnostics.py google.com github.com     # Test specific hosts
./network/network_diagnostics.py -p 80 443 22             # Include port scans
./network/network_diagnostics.py -t                       # Include traceroute
./network/network_diagnostics.py --ping-only              # Ping tests only
./network/network_diagnostics.py --dns-only               # DNS tests only
```

### System Administration (`system/`)

#### `service_manager.zsh`
User-friendly interface for managing systemd services with enhanced features.

**Features:**
- Colored output for easy reading
- Service status overview
- Detailed service information
- Service control (start/stop/restart/reload/enable/disable)
- Log viewing with follow mode
- Interactive service selection
- Filtering and search capabilities

**Usage:**
```bash
./system/service_manager.zsh list                    # List all services
./system/service_manager.zsh list ssh               # List services containing 'ssh'
./system/service_manager.zsh info nginx             # Show service details
./system/service_manager.zsh start apache2          # Start service (requires sudo)
./system/service_manager.zsh logs nginx 100         # Show last 100 log entries
./system/service_manager.zsh follow sshd            # Follow service logs
./system/service_manager.zsh interactive            # Interactive mode
```

### Log Analysis (`logs/`)

#### `log_analyzer.py`
Advanced log analysis tool with pattern matching, error detection, and statistical analysis.

**Features:**
- Error and warning detection
- IP address analysis
- SSH activity monitoring
- HTTP status code analysis
- Custom pattern searching
- Time range filtering
- Context line display
- Multiple log format support

**Usage:**
```bash
./logs/log_analyzer.py /var/log/syslog              # Comprehensive analysis
./logs/log_analyzer.py /var/log/auth.log -e         # Show only errors/warnings
./logs/log_analyzer.py /var/log/access.log -w       # Web server analysis
./logs/log_analyzer.py /var/log/auth.log -s         # SSH activity analysis
./logs/log_analyzer.py /var/log/syslog -p "failed" -c 3  # Search pattern with context
./logs/log_analyzer.py /var/log/syslog --since "2024-01-01 00:00:00"  # Time filtering
```

### Security Tools (`security/`)

#### `security_scanner.sh`
Basic security assessment tool for Linux systems.

**Features:**
- Running service analysis
- File permission checks
- User account auditing
- SSH configuration review
- System update status
- Firewall status check
- Comprehensive reporting
- Detailed security recommendations

**Usage:**
```bash
./security/security_scanner.sh                 # Full security scan
./security/security_scanner.sh --ssh          # SSH configuration only
./security/security_scanner.sh --services     # Service analysis only
./security/security_scanner.sh --users        # User account audit only
./security/security_scanner.sh --firewall     # Firewall status only
```

## 🚀 Quick Start

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd useful_scripts
   ```

2. **Make scripts executable:**
   ```bash
   chmod +x monitoring/*.py backup/*.sh network/*.py system/*.zsh logs/*.py security/*.sh
   ```

3. **Install Python dependencies** (if needed):
   ```bash
   pip3 install psutil  # For system monitoring
   ```

4. **Run your first script:**
   ```bash
   ./monitoring/system_monitor.py -i 5 -d 60
   ```

## 📋 Requirements

### System Requirements
- Linux operating system
- Bash shell (version 4.0+)
- ZSH (for service manager)
- Python 3.6 or later

### Python Dependencies
- `psutil` (for system monitoring)
- Standard library modules (no additional packages required for most scripts)

### System Tools
Most scripts use standard Linux utilities:
- `systemctl` (for service management)
- `ping`, `traceroute` (for network diagnostics)
- `ss` or `netstat` (for network analysis)
- `iptables`, `ufw`, or `firewalld` (for firewall checks)

## 🔧 Configuration

### Backup Manager
Initialize and configure backup settings:
```bash
./backup/backup_manager.sh init
# Edit ~/.config/backup_manager/backup.conf
```

### Environment Variables
Some scripts respect these environment variables:
- `LOG_LEVEL`: Set logging verbosity
- `CONFIG_DIR`: Override default configuration directory

## 🛡️ Security Considerations

- Scripts requiring privileged operations will prompt for appropriate permissions
- Log files may contain sensitive information - handle with care
- Review security scanner recommendations carefully
- Always test scripts in a safe environment first

## 🤝 Contributing

Contributions are welcome! Please:
1. Follow existing code style and conventions
2. Add appropriate error handling
3. Include usage documentation
4. Test thoroughly before submitting

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

For questions or issues:
1. Check the script's help message (`--help`)
2. Review the documentation above
3. Create an issue in the repository

## 🔄 Version History

- **v1.0.0**: Initial release with core monitoring, backup, network, system, security, and log analysis tools
