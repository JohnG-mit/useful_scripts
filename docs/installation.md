# Installation Guide

## Prerequisites

### System Requirements
- Linux operating system (Ubuntu, CentOS, RHEL, Debian, etc.)
- Bash shell (version 4.0 or later)
- ZSH shell (for service manager script)
- Python 3.6 or later

### Required System Tools
Most scripts use standard Linux utilities that are typically pre-installed:

- `systemctl` - For service management
- `ping` - For network connectivity tests
- `traceroute` - For network path tracing
- `ss` or `netstat` - For network statistics
- `find` - For file operations
- `tar` - For backup operations
- `grep`, `awk`, `sed` - For text processing

## Installation Steps

### 1. Clone the Repository
```bash
git clone <repository-url>
cd useful_scripts
```

### 2. Install Python Dependencies
```bash
# Install pip if not already installed
sudo apt update && sudo apt install python3-pip  # Ubuntu/Debian
sudo yum install python3-pip                     # CentOS/RHEL
sudo dnf install python3-pip                     # Fedora

# Install required Python packages
pip3 install psutil
```

### 3. Make Scripts Executable
```bash
# Make all scripts executable
find . -name "*.py" -exec chmod +x {} \;
find . -name "*.sh" -exec chmod +x {} \;
find . -name "*.zsh" -exec chmod +x {} \;

# Or individually:
chmod +x monitoring/system_monitor.py
chmod +x backup/backup_manager.sh
chmod +x network/network_diagnostics.py
chmod +x system/service_manager.zsh
chmod +x logs/log_analyzer.py
chmod +x security/security_scanner.sh
```

### 4. Optional: Add to PATH
To run scripts from anywhere, add the repository to your PATH:

```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="$PATH:/path/to/useful_scripts/monitoring"
export PATH="$PATH:/path/to/useful_scripts/backup"
export PATH="$PATH:/path/to/useful_scripts/network"
export PATH="$PATH:/path/to/useful_scripts/system"
export PATH="$PATH:/path/to/useful_scripts/logs"
export PATH="$PATH:/path/to/useful_scripts/security"

# Or create symbolic links
sudo ln -s /path/to/useful_scripts/monitoring/system_monitor.py /usr/local/bin/
sudo ln -s /path/to/useful_scripts/backup/backup_manager.sh /usr/local/bin/
# ... continue for other scripts
```

## Verification

### Test Basic Functionality
```bash
# Test system monitor
./monitoring/system_monitor.py --help

# Test backup manager
./backup/backup_manager.sh help

# Test network diagnostics
./network/network_diagnostics.py --help

# Test service manager
./system/service_manager.zsh --help

# Test log analyzer
./logs/log_analyzer.py --help

# Test security scanner
./security/security_scanner.sh --help
```

### Run Quick Tests
```bash
# Quick system monitor test (5 seconds)
./monitoring/system_monitor.py -i 1 -d 5

# Network connectivity test
./network/network_diagnostics.py --ping-only

# List system services
./system/service_manager.zsh list | head -10

# Security scan (services only)
./security/security_scanner.sh --services
```

## Troubleshooting

### Common Issues

#### Python Scripts Won't Run
```bash
# Check Python version
python3 --version

# Check if psutil is installed
python3 -c "import psutil; print('psutil is available')"

# Install psutil if missing
pip3 install psutil
```

#### Permission Errors
```bash
# Make sure scripts are executable
ls -la monitoring/system_monitor.py
# Should show: -rwxr-xr-x

# Fix permissions if needed
chmod +x monitoring/system_monitor.py
```

#### ZSH Not Found
```bash
# Install ZSH
sudo apt install zsh          # Ubuntu/Debian
sudo yum install zsh          # CentOS/RHEL
sudo dnf install zsh          # Fedora

# Or modify the shebang to use bash
sed -i 's|#!/usr/bin/env zsh|#!/bin/bash|' system/service_manager.zsh
```

#### Missing System Tools
```bash
# Install missing network tools
sudo apt install net-tools traceroute     # Ubuntu/Debian
sudo yum install net-tools traceroute     # CentOS/RHEL

# Install missing utilities
sudo apt install findutils coreutils      # Ubuntu/Debian
```

### Dependency Check Script
Create a simple dependency checker:

```bash
#!/bin/bash
# Check dependencies

echo "Checking dependencies..."

# Check Python
if command -v python3 >/dev/null; then
    echo "✓ Python3: $(python3 --version)"
else
    echo "✗ Python3 not found"
fi

# Check required Python modules
if python3 -c "import psutil" 2>/dev/null; then
    echo "✓ Python psutil module available"
else
    echo "✗ Python psutil module missing - run: pip3 install psutil"
fi

# Check system tools
tools=("systemctl" "ping" "traceroute" "ss" "tar" "find" "grep" "awk")
for tool in "${tools[@]}"; do
    if command -v "$tool" >/dev/null; then
        echo "✓ $tool available"
    else
        echo "✗ $tool not found"
    fi
done

echo "Dependency check complete."
```

## Next Steps

After installation, see:
- [Usage Examples](examples.md) for common use cases
- [Configuration Guide](configuration.md) for customization options
- Main [README.md](../README.md) for complete script documentation