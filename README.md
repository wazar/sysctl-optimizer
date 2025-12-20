# Auto Sysctl Optimizer

Automatically optimize Linux kernel parameters (sysctl) for your server. Detects hardware, generates optimized configuration, tests each parameter, and applies only what works.

## Features

- **Zero Configuration**: Auto-detects CPU, RAM, network speed, and disk type
- **Safe Testing**: Tests every parameter individually before applying
- **Automatic Fallback**: Disables unsupported parameters automatically
- **Container Aware**: Detects Docker/LXC/Kubernetes and warns about limitations
- **BBR Detection**: Uses BBR congestion control if available, falls back to cubic
- **Backup & Rollback**: Creates timestamped backup before any changes
- **Production Ready**: Extensive error handling and validation

## Quick Start

```bash
# Download
curl -O https://raw.githubusercontent.com/YOUR_USERNAME/sysctl-optimizer/main/auto-optimize-sysctl.sh
chmod +x auto-optimize-sysctl.sh

# Run (interactive)
sudo ./auto-optimize-sysctl.sh

# Preview without applying
sudo ./auto-optimize-sysctl.sh --dry-run

# Automated (no prompts)
sudo ./auto-optimize-sysctl.sh --force
```

## Usage

```
Usage: auto-optimize-sysctl.sh [OPTIONS]

Options:
  -d, --dry-run     Generate and test config without applying
  -f, --force       Skip confirmation prompt
  -v, --verbose     Show detailed output
  -h, --help        Show this help message
```

## What Gets Optimized

### Memory Management
- `vm.swappiness` - Optimized for SSD/HDD
- `vm.dirty_ratio` - Balanced for your RAM size
- `vm.min_free_kbytes` - Scaled with bounds (64MB-512MB)

### Network Performance
- `net.ipv4.tcp_congestion_control` - BBR if available
- `net.core.rmem_max/wmem_max` - Scaled to NIC speed
- `net.core.somaxconn` - Scaled to CPU cores
- TCP Fast Open, window scaling, timestamps enabled

### Process Limits
- `kernel.pid_max` - Scaled to RAM
- `fs.file-max` - Scaled to RAM with bounds
- `fs.inotify.max_user_watches` - Increased for dev tools

### Security Hardening
- Reverse path filtering (anti-spoofing)
- ICMP redirect protection
- SYN cookies enabled
- ASLR enabled
- Kernel pointer hiding

## Example Output

```
========================================================================
  Automatic sysctl Optimization Script v2.0
========================================================================

[INFO] Checking prerequisites...
[OK] Prerequisites check passed

[INFO] Detecting CPU configuration...
[OK] Detected: 8 CPU core(s)
[INFO] Detecting RAM...
[OK] Detected: 31 GB RAM
[INFO] Detecting network interface...
[OK] Detected: eth0 at 1000 Mbps
[INFO] Detecting disk type...
[OK] Detected: SSD

[INFO] Generating optimized sysctl configuration...
[OK] Configuration generated

[INFO] Testing configuration parameters...
[OK] Testing complete: 95/95 parameters work

[INFO] Backing up current configuration...
[OK] Backup created: /etc/sysctl.conf.backup.20251220-120000

[OK] Configuration applied successfully!
```

## Rollback

```bash
# List backups
ls -la /etc/sysctl.conf.backup.*

# Restore
sudo cp /etc/sysctl.conf.backup.YYYYMMDD-HHMMSS /etc/sysctl.conf
sudo sysctl -p
```

## Compatibility

- **OS**: Debian, Ubuntu, RHEL, CentOS, Rocky, Alma, Fedora
- **Kernel**: 3.x and higher
- **Architecture**: x86_64, ARM64
- **Environment**: Bare metal, VPS, containers (with limitations)

## How It Works

1. **Prerequisites Check** - Verifies root access, required commands, /proc filesystem
2. **Container Detection** - Warns if running in Docker/LXC/K8s
3. **Hardware Detection** - CPU cores, RAM, NIC speed, disk type (SSD/HDD/NVMe)
4. **Configuration Generation** - Creates optimized config based on detected specs
5. **Parameter Testing** - Tests each sysctl parameter individually
6. **Backup** - Creates timestamped backup of existing config
7. **Apply** - Writes tested config to /etc/sysctl.conf and applies

## Credits

Based on optimization research from:
- [sysctl-Generator](https://github.com/ENGINYRING/sysctl-Generator)
- Linux kernel documentation
- Google BBR research
- Red Hat Performance Tuning Guide

## License

MIT License
