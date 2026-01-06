#!/bin/bash
# ============================================================================
# Automatic System Optimization Script for sysctl
# Detects hardware, generates optimized config, tests, and applies
# Version: 2.0 (Hardened)
# ============================================================================

# Exit on undefined variables, but handle errors manually
set -u

# Script info
readonly SCRIPT_VERSION="2.0"
readonly SCRIPT_NAME="$(basename "$0")"

# Colors (with fallback for non-terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# Configuration
readonly FINAL_CONF="/etc/sysctl.conf"
TEMP_CONF=""
TEST_CONF=""
BACKUP_CONF=""

# System variables (will be detected)
CORES=1
RAM=1
NIC_SPEED=1000
DISK_TYPE="hdd"
ACTIVE_IF="unknown"
IS_CONTAINER=false

# Flags
DRY_RUN=false
FORCE=false
VERBOSE=false
NIC_SPEED_OVERRIDE=""

# Counters for testing
TOTAL_PARAMS=0
WORKING_PARAMS=0
FAILED_PARAMS=0

# ============================================================================
# Utility Functions
# ============================================================================

print_header() {
    echo -e "${BLUE}${BOLD}"
    echo "========================================================================"
    echo "  Automatic sysctl Optimization Script v${SCRIPT_VERSION}"
    echo "========================================================================"
    echo -e "${NC}"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Safe integer comparison (handles empty/non-numeric values)
is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

# ============================================================================
# Prerequisite Checks
# ============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for root
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi

    # Check for required commands
    local required_cmds=("sysctl" "grep" "awk" "sed" "cat" "cp" "rm" "df")
    for cmd in "${required_cmds[@]}"; do
        if ! command_exists "$cmd"; then
            die "Required command not found: $cmd"
        fi
    done

    # Check if /proc is mounted
    if [[ ! -f /proc/meminfo ]]; then
        die "/proc filesystem not mounted or accessible"
    fi

    # Check if sysctl is functional
    if ! sysctl -a >/dev/null 2>&1; then
        die "sysctl is not functional on this system"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Container Detection
# ============================================================================

detect_container() {
    IS_CONTAINER=false

    # Check for Docker
    if [[ -f /.dockerenv ]]; then
        IS_CONTAINER=true
        log_warning "Running inside Docker container - some parameters may be read-only"
        return
    fi

    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]]; then
        if grep -qE '(docker|lxc|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
            IS_CONTAINER=true
            log_warning "Running inside container - some parameters may be read-only"
            return
        fi
    fi

    # Check for LXC
    if [[ -f /run/.containerenv ]] || grep -q "container=" /proc/1/environ 2>/dev/null; then
        IS_CONTAINER=true
        log_warning "Running inside container - some parameters may be read-only"
        return
    fi
}

# ============================================================================
# System Detection Functions
# ============================================================================

detect_cpu() {
    log_info "Detecting CPU configuration..."

    CORES=1  # Safe default

    if command_exists nproc; then
        local detected
        detected=$(nproc 2>/dev/null) || detected=""
        if is_positive_integer "$detected"; then
            CORES=$detected
        fi
    fi

    # Fallback to /proc/cpuinfo
    if [[ "$CORES" -eq 1 ]] && [[ -f /proc/cpuinfo ]]; then
        local detected
        detected=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || detected=""
        if is_positive_integer "$detected"; then
            CORES=$detected
        fi
    fi

    log_success "Detected: $CORES CPU core(s)"
}

detect_ram() {
    log_info "Detecting RAM..."

    RAM=1  # Safe default (1GB minimum)

    if [[ -f /proc/meminfo ]]; then
        local mem_kb
        mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null) || mem_kb=""

        if is_positive_integer "$mem_kb"; then
            RAM=$(( mem_kb / 1024 / 1024 ))
            # Ensure minimum of 1GB
            if [[ "$RAM" -lt 1 ]]; then
                RAM=1
            fi
        fi
    fi

    log_success "Detected: ${RAM} GB RAM"
}

detect_network() {
    log_info "Detecting network interface..."

    ACTIVE_IF="unknown"
    NIC_SPEED=1000  # Safe default

    # Try to find active interface via routing table
    if command_exists ip; then
        local route_output
        route_output=$(ip -o route get 1.1.1.1 2>/dev/null) || route_output=""
        if [[ -n "$route_output" ]]; then
            # Parse: "1.1.1.1 via X.X.X.X dev ethX src X.X.X.X"
            ACTIVE_IF=$(echo "$route_output" | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        fi
    fi

    # Fallback: find first non-loopback interface
    if [[ -z "$ACTIVE_IF" || "$ACTIVE_IF" == "lo" || "$ACTIVE_IF" == "unknown" ]]; then
        if [[ -d /sys/class/net ]]; then
            for iface in /sys/class/net/*; do
                local name
                name=$(basename "$iface")
                if [[ "$name" != "lo" && -d "$iface" ]]; then
                    ACTIVE_IF="$name"
                    break
                fi
            done
        fi
    fi

    # Detect speed (unless overridden)
    if [[ -n "$NIC_SPEED_OVERRIDE" ]]; then
        NIC_SPEED=$NIC_SPEED_OVERRIDE
        log_success "Using override: ${ACTIVE_IF} at ${NIC_SPEED} Mbps (user-specified)"
    else
        if [[ -n "$ACTIVE_IF" && "$ACTIVE_IF" != "unknown" ]]; then
            local speed_file="/sys/class/net/${ACTIVE_IF}/speed"
            if [[ -f "$speed_file" ]]; then
                local speed
                speed=$(cat "$speed_file" 2>/dev/null) || speed=""
                # Speed can be -1 if unknown, or non-numeric
                if [[ "$speed" =~ ^[0-9]+$ ]] && [[ "$speed" -gt 0 ]]; then
                    NIC_SPEED=$speed
                fi
            fi
        fi
        log_success "Detected: ${ACTIVE_IF} at ${NIC_SPEED} Mbps"
    fi
}

detect_disk() {
    log_info "Detecting disk type..."

    DISK_TYPE="hdd"  # Safe default

    # Get root filesystem device
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}') || root_dev=""

    if [[ -z "$root_dev" ]]; then
        log_warning "Could not detect root device, assuming HDD"
        log_success "Detected: HDD (default)"
        return
    fi

    # Extract base device name (handle /dev/sda1 -> sda, /dev/nvme0n1p1 -> nvme0n1, etc.)
    local base_dev
    base_dev=$(echo "$root_dev" | sed -E 's|/dev/||; s|([a-z]+)[0-9]+$|\1|; s|(nvme[0-9]+n[0-9]+)p[0-9]+$|\1|; s|(xvd[a-z])[0-9]+$|\1|; s|(vd[a-z])[0-9]+$|\1|')

    # Check for NVMe
    if [[ "$base_dev" == nvme* ]]; then
        DISK_TYPE="nvme"
    # Check rotational flag
    elif [[ -f "/sys/block/${base_dev}/queue/rotational" ]]; then
        local rotational
        rotational=$(cat "/sys/block/${base_dev}/queue/rotational" 2>/dev/null) || rotational="1"
        if [[ "$rotational" == "0" ]]; then
            DISK_TYPE="ssd"
        fi
    fi

    local disk_name="HDD"
    [[ "$DISK_TYPE" == "ssd" ]] && disk_name="SSD"
    [[ "$DISK_TYPE" == "nvme" ]] && disk_name="NVMe SSD"

    log_success "Detected: $disk_name"
}

# ============================================================================
# BBR Availability Check
# ============================================================================

check_bbr_available() {
    # Check if BBR is available
    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            return 0
        fi
    fi

    # Try to load the module
    if modprobe tcp_bbr 2>/dev/null; then
        if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# ============================================================================
# Configuration Generation
# ============================================================================

generate_config() {
    log_info "Generating optimized sysctl configuration..."

    # Create temp file
    TEMP_CONF=$(mktemp /tmp/sysctl-optimized-XXXXXX.conf) || die "Failed to create temp file"

    # Calculate derived values with bounds checking
    local swappiness dirty_ratio dirty_bg min_free_kb

    # Swappiness based on disk type
    if [[ "$DISK_TYPE" == "ssd" || "$DISK_TYPE" == "nvme" ]]; then
        swappiness=10
    else
        swappiness=20
    fi

    # Dirty ratios
    if [[ "$RAM" -ge 16 ]]; then
        dirty_ratio=10
        dirty_bg=3
    else
        dirty_ratio=15
        dirty_bg=5
    fi

    # min_free_kbytes: scale with RAM but cap at reasonable values
    # Too high can cause OOM, too low can cause memory pressure
    min_free_kb=$(( RAM * 4096 ))
    # Cap at 512MB for very large systems
    if [[ "$min_free_kb" -gt 524288 ]]; then
        min_free_kb=524288
    fi
    # Minimum 64MB
    if [[ "$min_free_kb" -lt 65536 ]]; then
        min_free_kb=65536
    fi

    # Network buffers based on NIC speed
    local rmax wmax tcp_rmem tcp_wmem
    if [[ "$NIC_SPEED" -ge 10000 ]]; then
        rmax=33554432
        wmax=33554432
        tcp_rmem="4096 262144 33554432"
        tcp_wmem="4096 262144 33554432"
    else
        rmax=16777216
        wmax=16777216
        tcp_rmem="4096 131072 16777216"
        tcp_wmem="4096 131072 16777216"
    fi

    # Process limits with bounds
    local pid_max file_max
    pid_max=$(( RAM * 16384 ))
    [[ "$pid_max" -lt 32768 ]] && pid_max=32768
    [[ "$pid_max" -gt 4194304 ]] && pid_max=4194304

    file_max=$(( RAM * 262144 ))
    [[ "$file_max" -lt 65536 ]] && file_max=65536
    [[ "$file_max" -gt 26214400 ]] && file_max=26214400

    # Connection queue size
    local somaxconn
    somaxconn=$(( CORES * 512 ))
    [[ "$somaxconn" -lt 4096 ]] && somaxconn=4096
    [[ "$somaxconn" -gt 65535 ]] && somaxconn=65535

    # SYN backlog
    local syn_backlog
    syn_backlog=$(( CORES * 1024 ))
    [[ "$syn_backlog" -lt 8192 ]] && syn_backlog=8192
    [[ "$syn_backlog" -gt 262144 ]] && syn_backlog=262144

    # Netdev backlog
    local netdev_backlog
    if [[ "$NIC_SPEED" -ge 10000 ]]; then
        netdev_backlog=250000
    else
        netdev_backlog=30000
    fi

    # Shared memory (90% of RAM, in bytes)
    local shmmax shmall
    shmmax=$(( RAM * 1024 * 1024 * 1024 * 90 / 100 ))
    shmall=$(( shmmax / 4096 ))

    # Congestion control
    local congestion_control="cubic"
    if check_bbr_available; then
        congestion_control="bbr"
    else
        log_warning "BBR not available, using cubic congestion control"
    fi

    # Generate configuration file
    cat > "$TEMP_CONF" << SYSCTL_EOF
# ============================================================================
# Optimized sysctl.conf for General Purpose Server
# Generated by: ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Hardware: ${CORES} cores, ${RAM}GB RAM, ${NIC_SPEED}Mb/s NIC, ${DISK_TYPE^^}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================================

# KERNEL SETTINGS
kernel.pid_max = ${pid_max}
kernel.threads-max = ${pid_max}
kernel.sched_autogroup_enabled = 0
kernel.sched_cfs_bandwidth_slice_us = 3000
kernel.sched_rt_runtime_us = 980000
kernel.sched_child_runs_first = 0
kernel.shmmax = ${shmmax}
kernel.shmall = ${shmall}
kernel.shmmni = 4096
kernel.sysrq = 1
kernel.panic = 10
kernel.panic_on_oops = 1

# MEMORY MANAGEMENT
vm.swappiness = ${swappiness}
vm.dirty_ratio = ${dirty_ratio}
vm.dirty_background_ratio = ${dirty_bg}
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 100
vm.min_free_kbytes = ${min_free_kb}
vm.vfs_cache_pressure = 50
vm.zone_reclaim_mode = 0
vm.overcommit_memory = 0
vm.overcommit_ratio = 50
vm.max_map_count = 1048576
vm.page-cluster = 0
vm.oom_kill_allocating_task = 1

# NETWORK - CORE
net.core.rmem_max = ${rmax}
net.core.wmem_max = ${wmax}
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.optmem_max = 4194304
net.core.netdev_max_backlog = ${netdev_backlog}
net.core.netdev_budget = 300
net.core.dev_weight = 64
net.core.somaxconn = ${somaxconn}
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.default_qdisc = fq

# NETWORK - TCP/UDP
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 4194304 8388608 16777216
net.ipv4.tcp_congestion_control = ${congestion_control}
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 1024 65535

# NETWORK - IPv4 SECURITY
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 0

# NETWORK - IPv6
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

# FILESYSTEM
fs.file-max = ${file_max}
fs.nr_open = 26214400
fs.aio-max-nr = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576

# SECURITY
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 1
kernel.perf_event_paranoid = 2
fs.suid_dumpable = 0
kernel.core_uses_pid = 1
SYSCTL_EOF

    log_success "Configuration generated: $TEMP_CONF"
}

# ============================================================================
# Configuration Testing
# ============================================================================

test_configuration() {
    log_info "Testing configuration parameters..."

    # Create tested config file
    TEST_CONF=$(mktemp /tmp/sysctl-tested-XXXXXX.conf) || die "Failed to create test file"

    # Reset counters
    TOTAL_PARAMS=0
    WORKING_PARAMS=0
    FAILED_PARAMS=0

    # Write header
    cat > "$TEST_CONF" << EOF
# ============================================================================
# Tested and Verified sysctl.conf
# Generated by: ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Hardware: ${CORES} cores, ${RAM}GB RAM, ${NIC_SPEED}Mb/s NIC, ${DISK_TYPE^^}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# All parameters below have been tested and verified to work on this system
# ============================================================================

EOF

    # Read and test each line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines - pass through unchanged
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
            echo "$line" >> "$TEST_CONF"
            continue
        fi

        # Try to parse as key = value
        if [[ "$line" =~ ^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            local param="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Trim whitespace
            param="${param#"${param%%[![:space:]]*}"}"
            param="${param%"${param##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            ((TOTAL_PARAMS++)) || true

            # Test the parameter
            if sysctl -w "${param}=${value}" >/dev/null 2>&1; then
                echo "$line" >> "$TEST_CONF"
                ((WORKING_PARAMS++)) || true
                log_debug "OK: $param"
            else
                echo "# DISABLED: ${line}  # Not supported on this kernel" >> "$TEST_CONF"
                ((FAILED_PARAMS++)) || true
                log_warning "Parameter not supported: $param"
            fi
        else
            # Unknown format, pass through
            echo "$line" >> "$TEST_CONF"
        fi
    done < "$TEMP_CONF"

    # Add summary
    echo "" >> "$TEST_CONF"
    echo "# Testing Summary: ${WORKING_PARAMS}/${TOTAL_PARAMS} parameters applied successfully" >> "$TEST_CONF"

    log_success "Testing complete: ${WORKING_PARAMS}/${TOTAL_PARAMS} parameters work"

    if [[ "$FAILED_PARAMS" -gt 0 ]]; then
        log_warning "$FAILED_PARAMS parameter(s) were disabled (not supported on this kernel)"
    fi

    # Warn if too many failures
    if [[ "$TOTAL_PARAMS" -gt 0 ]]; then
        local fail_percent=$(( FAILED_PARAMS * 100 / TOTAL_PARAMS ))
        if [[ "$fail_percent" -gt 20 ]]; then
            log_warning "High failure rate (${fail_percent}%) - consider checking kernel compatibility"
        fi
    fi
}

# ============================================================================
# Backup and Apply
# ============================================================================

backup_current_config() {
    # Generate backup filename at backup time (not script start)
    BACKUP_CONF="/etc/sysctl.conf.backup.$(date +%Y%m%d-%H%M%S)"

    if [[ -f "$FINAL_CONF" ]]; then
        log_info "Backing up current configuration..."
        if cp "$FINAL_CONF" "$BACKUP_CONF"; then
            log_success "Backup created: $BACKUP_CONF"
        else
            die "Failed to create backup"
        fi
    else
        log_warning "No existing $FINAL_CONF found, creating new file"
        BACKUP_CONF=""
    fi
}

apply_configuration() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would apply configuration to $FINAL_CONF"
        echo ""
        echo "Generated configuration:"
        echo "========================"
        cat "$TEST_CONF"
        return 0
    fi

    log_info "Applying tested configuration to $FINAL_CONF..."

    # Copy tested config to final location
    if ! cp "$TEST_CONF" "$FINAL_CONF"; then
        die "Failed to copy configuration to $FINAL_CONF"
    fi

    # Apply the configuration
    local apply_output
    apply_output=$(sysctl -p "$FINAL_CONF" 2>&1)
    local result=$?

    if [[ $result -eq 0 ]]; then
        log_success "Configuration applied successfully!"
        return 0
    else
        log_error "Failed to apply configuration"
        log_error "sysctl output: $apply_output"

        # Attempt rollback
        if [[ -n "$BACKUP_CONF" && -f "$BACKUP_CONF" ]]; then
            log_warning "Rolling back to backup..."
            if cp "$BACKUP_CONF" "$FINAL_CONF"; then
                sysctl -p "$FINAL_CONF" >/dev/null 2>&1 || true
                log_info "Rollback complete"
            else
                log_error "Rollback failed!"
            fi
        fi
        return 1
    fi
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    # Only log if files exist
    local cleaned=false

    if [[ -n "${TEMP_CONF:-}" && -f "$TEMP_CONF" ]]; then
        rm -f "$TEMP_CONF"
        cleaned=true
    fi

    if [[ -n "${TEST_CONF:-}" && -f "$TEST_CONF" ]]; then
        rm -f "$TEST_CONF"
        cleaned=true
    fi

    if [[ "$cleaned" == true ]]; then
        log_debug "Temporary files cleaned up"
    fi
}

# ============================================================================
# Summary Report
# ============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}========================================================================"
    echo "  Optimization Complete!"
    echo -e "========================================================================${NC}"
    echo ""
    echo -e "${CYAN}System Specifications:${NC}"
    echo "  CPU Cores:      $CORES"
    echo "  RAM:            ${RAM} GB"
    echo "  Network:        ${ACTIVE_IF} at ${NIC_SPEED} Mbps"
    echo "  Disk Type:      ${DISK_TYPE^^}"
    [[ "$IS_CONTAINER" == true ]] && echo "  Environment:    Container"
    echo ""
    echo -e "${CYAN}Configuration:${NC}"
    echo "  Parameters:     ${WORKING_PARAMS}/${TOTAL_PARAMS} applied"
    echo "  Active Config:  $FINAL_CONF"
    [[ -n "$BACKUP_CONF" ]] && echo "  Backup:         $BACKUP_CONF"
    echo ""
    echo -e "${CYAN}Key Optimizations:${NC}"
    if check_bbr_available; then
        echo "  - TCP Congestion Control: BBR"
    else
        echo "  - TCP Congestion Control: cubic (BBR not available)"
    fi
    echo "  - Network Buffers: Scaled for ${NIC_SPEED}Mbps"
    echo "  - Swappiness: ${DISK_TYPE^^} optimized"
    echo "  - File Descriptors: Scaled to ${RAM}GB RAM"
    echo "  - Security: Hardened (rp_filter, ASLR, etc.)"
    echo ""
    echo -e "${YELLOW}Verification:${NC}"
    echo "  sysctl vm.swappiness"
    echo "  sysctl net.ipv4.tcp_congestion_control"
    echo "  sysctl net.core.rmem_max"
    echo ""
    if [[ -n "$BACKUP_CONF" ]]; then
        echo -e "${YELLOW}To rollback:${NC}"
        echo "  sudo cp $BACKUP_CONF $FINAL_CONF && sudo sysctl -p"
        echo ""
    fi
}

# ============================================================================
# Usage
# ============================================================================

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Automatically optimize sysctl parameters for your system.

Options:
  -d, --dry-run          Generate and test config without applying
  -f, --force            Skip confirmation prompt
  -n, --nic-speed SPEED  Override detected NIC speed (in Mbps)
                         Use 10000 for 10Gbps tuning on VMs
  -v, --verbose          Show detailed output
  -h, --help             Show this help message

Examples:
  sudo $SCRIPT_NAME                    # Interactive mode
  sudo $SCRIPT_NAME --dry-run          # Preview changes
  sudo $SCRIPT_NAME --force            # Apply without confirmation
  sudo $SCRIPT_NAME --nic-speed 10000  # Force 10Gbps network tuning

EOF
    exit 0
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--nic-speed)
                if [[ -z "${2:-}" ]]; then
                    die "Option --nic-speed requires a value (e.g., --nic-speed 10000)"
                fi
                if ! is_positive_integer "$2"; then
                    die "Invalid NIC speed: $2 (must be a positive integer in Mbps)"
                fi
                NIC_SPEED_OVERRIDE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    parse_args "$@"

    print_header
    check_prerequisites

    echo ""

    # Detect container environment
    detect_container

    # Detect system specs
    detect_cpu
    detect_ram
    detect_network
    detect_disk

    echo ""

    # Generate configuration
    generate_config

    echo ""

    # Test configuration
    test_configuration

    echo ""

    # Check if we should proceed
    if [[ "$WORKING_PARAMS" -eq 0 ]]; then
        die "No parameters could be applied - check kernel compatibility"
    fi

    # Ask for confirmation (unless force or dry-run)
    if [[ "$FORCE" != true && "$DRY_RUN" != true ]]; then
        echo -e "${YELLOW}${BOLD}Ready to apply optimizations${NC}"
        echo "This will:"
        echo "  1. Backup current $FINAL_CONF"
        echo "  2. Apply ${WORKING_PARAMS} tested optimizations"
        echo "  3. Make changes persistent across reboots"
        echo ""

        # Check if we have a terminal
        if [[ -t 0 ]]; then
            local REPLY=""
            read -r -p "Continue? [y/N]: " REPLY
            echo ""

            if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                log_warning "Aborted by user"
                cleanup
                exit 0
            fi
        else
            log_warning "Non-interactive mode detected, use --force to apply"
            cleanup
            exit 0
        fi
    fi

    echo ""

    # Backup and apply (skip backup for dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        backup_current_config
    fi

    if apply_configuration; then
        # Cleanup temp files
        cleanup

        # Show summary (not for dry-run, already shown)
        if [[ "$DRY_RUN" != true ]]; then
            print_summary
        fi
    else
        cleanup
        exit 1
    fi
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# Run main with all arguments
main "$@"
