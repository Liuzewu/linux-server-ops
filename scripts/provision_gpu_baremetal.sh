#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/gpu-baremetal-provision.log"

DRIVER_VERSION="580"
CUDA_VERSION="13.0"
MOUNT_BASE="/data"
FILESYSTEM="ext4"
FORMAT_EMPTY="false"
INSTALL_DOCKER_NVIDIA="false"
FABRIC_MANAGER_MODE="auto"
LOCK_VERSIONS="true"
ASSUME_YES="false"
REBOOT="false"
FORCE="false"
CONFIRM_FORMAT_EMPTY="false"
PIN_FILE="/etc/apt/preferences.d/nvidia-cuda-version-lock.pref"
FSTAB_BACKED_UP="false"
MOUNT_RESULTS=()
SKIP_RESULTS=()

log() {
  local message="$*"
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage:
  sudo ./$SCRIPT_NAME [options]
  sudo ./$SCRIPT_NAME --driver 580 --cuda 13.0 [options]

Defaults:
  --driver 580
  --cuda 13.0

Version options:
  --driver VERSION       NVIDIA driver major version, for example: 550, 570, 580
  --cuda VERSION         CUDA toolkit version, for example: 12.8, 13.0

Options:
  --mount-base PATH      Base mount directory for data disks. Default: /data
  --fs TYPE              Filesystem for newly formatted empty disks. Default: ext4
  --format-empty         Format disks that have no filesystem. Without this flag, blank disks are skipped.
  --fabricmanager        Always install NVIDIA Fabric Manager for the selected driver branch.
  --no-fabricmanager     Do not install NVIDIA Fabric Manager.
  --install-container    Install NVIDIA Container Toolkit for Docker workloads.
  --no-lock              Do not hold NVIDIA/CUDA package versions after installation.
  --force                Continue even when active GPU compute processes are detected.
  --confirm-format-empty Required together with --format-empty to format blank disks.
  --yes                  Execute changes. Without this flag, the script runs in dry-run mode.
  --reboot               Reboot automatically at the end when changes succeed.
  -h, --help             Show this help.

Examples:
  sudo ./$SCRIPT_NAME
  sudo ./$SCRIPT_NAME --yes --reboot
  sudo ./$SCRIPT_NAME --fabricmanager --yes --reboot
  sudo ./$SCRIPT_NAME --format-empty --confirm-format-empty --mount-base /data --yes
EOF
}

run() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    log "RUN: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
  else
    log "DRY-RUN: $*"
  fi
}

run_shell() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    log "RUN: $*"
    bash -c "$*" 2>&1 | tee -a "$LOG_FILE"
  else
    log "DRY-RUN: $*"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --driver)
        DRIVER_VERSION="${2:-}"
        shift 2
        ;;
      --cuda)
        CUDA_VERSION="${2:-}"
        shift 2
        ;;
      --mount-base)
        MOUNT_BASE="${2:-}"
        shift 2
        ;;
      --fs)
        FILESYSTEM="${2:-}"
        shift 2
        ;;
      --format-empty)
        FORMAT_EMPTY="true"
        shift
        ;;
      --fabricmanager)
        FABRIC_MANAGER_MODE="always"
        shift
        ;;
      --no-fabricmanager)
        FABRIC_MANAGER_MODE="never"
        shift
        ;;
      --install-container)
        INSTALL_DOCKER_NVIDIA="true"
        shift
        ;;
      --no-lock)
        LOCK_VERSIONS="false"
        shift
        ;;
      --force)
        FORCE="true"
        shift
        ;;
      --confirm-format-empty)
        CONFIRM_FORMAT_EMPTY="true"
        shift
        ;;
      --yes)
        ASSUME_YES="true"
        shift
        ;;
      --reboot)
        REBOOT="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run as root, for example with sudo."
}

validate_inputs() {
  [[ "$DRIVER_VERSION" =~ ^[0-9]+$ ]] || die "--driver must be a driver major version such as 580."
  [[ "$CUDA_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--cuda must be a CUDA version such as 13.0."
  [[ "$MOUNT_BASE" == /* ]] || die "--mount-base must be an absolute path."
  [[ "$MOUNT_BASE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "--mount-base contains unsupported characters."
  if [[ "$FORMAT_EMPTY" == "true" && "$CONFIRM_FORMAT_EMPTY" != "true" ]]; then
    die "--format-empty requires --confirm-format-empty to reduce accidental data loss."
  fi

  case "$FILESYSTEM" in
    ext4|xfs) ;;
    *) die "--fs currently supports ext4 or xfs." ;;
  esac
}

detect_ubuntu() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script currently supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."
  [[ -n "${VERSION_ID:-}" ]] || die "Cannot detect Ubuntu version."
  case "$VERSION_ID" in
    22.04|24.04) ;;
    *) die "This script supports Ubuntu 22.04 and 24.04 for standard delivery. Detected: ${VERSION_ID}." ;;
  esac
  UBUNTU_VERSION_ID="$VERSION_ID"
  UBUNTU_REPO_ID="ubuntu${VERSION_ID//./}"
  log "Detected Ubuntu ${UBUNTU_VERSION_ID}."
}

detect_architecture() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  [[ "$arch" == "amd64" || "$arch" == "x86_64" ]] || die "This script supports x86_64/amd64 only. Detected: ${arch}."
  log "Detected architecture: ${arch}."
}

secure_boot_enabled() {
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"
    return
  fi

  local sb_var
  sb_var="$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -n 1 || true)"
  [[ -n "$sb_var" ]] || return 1

  od -An -t u1 "$sb_var" 2>/dev/null | awk '{ value=$NF } END { exit value == 1 ? 0 : 1 }'
}

guard_secure_boot() {
  if secure_boot_enabled; then
    die "Secure Boot is enabled. Disable Secure Boot in BIOS/UEFI or handle MOK kernel-module signing manually before running this script."
  fi

  log "Secure Boot is disabled or not detected."
}

check_network_access() {
  local test_url="https://developer.download.nvidia.com/compute/cuda/repos/${UBUNTU_REPO_ID}/x86_64/"

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: check network access to ${test_url}"
    return
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required for NVIDIA repository checks but is not installed."
  log "Checking network access to NVIDIA CUDA repository."
  curl -fsSI --connect-timeout 10 --max-time 30 "$test_url" >/dev/null || \
    die "Cannot reach NVIDIA CUDA repository: ${test_url}. Check DNS, firewall, proxy, or outbound HTTPS access."
}

preflight_checks() {
  log "Running preflight checks."
  detect_architecture
  guard_secure_boot
}

confirm_execution() {
  if [[ "$ASSUME_YES" != "true" ]]; then
    log "Dry-run mode. Add --yes to execute these changes."
    return
  fi

  log "Execution mode enabled."
  log "NVIDIA driver branch target: ${DRIVER_VERSION}"
  log "CUDA toolkit target: cuda-toolkit-${CUDA_VERSION/./-}"
  log "Data disk mount base: ${MOUNT_BASE}"
  log "Fabric Manager mode: ${FABRIC_MANAGER_MODE}"
  log "Version lock after install: ${LOCK_VERSIONS}"
  log "Force active workload upgrade: ${FORCE}"
  [[ "$FORMAT_EMPTY" == "true" ]] && log "Blank data disks may be formatted as ${FILESYSTEM}."
}

active_gpu_processes() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0

  nvidia-smi --query-compute-apps=pid,process_name,used_memory \
    --format=csv,noheader,nounits 2>/dev/null |
    awk 'NF && $1 != "No"'
}

guard_active_workloads() {
  local active_processes
  active_processes="$(active_gpu_processes || true)"

  if [[ -z "$active_processes" ]]; then
    log "No active GPU compute processes detected."
    return
  fi

  log "Active GPU compute processes detected:"
  printf '%s\n' "$active_processes" | tee -a "$LOG_FILE"

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: active GPU processes would block execution unless --force is used."
    return
  fi

  [[ "$FORCE" == "true" ]] || die "Active GPU compute processes found. Stop workloads first or rerun with --force during a maintenance window."
  log "--force supplied; continuing despite active GPU compute processes."
}

show_current_gpu_stack() {
  log "Current GPU software snapshot:"

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "nvidia-smi is not currently available."
  fi

  if command -v nvcc >/dev/null 2>&1; then
    nvcc --version 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "nvcc is not currently available."
  fi

  dpkg-query -W -f='${Package} ${Version}\n' \
    'cuda-*' 'libcuda*' 'libnvidia-*' 'nvidia-*' 'nsight-*' 2>/dev/null |
    sort -u |
    tee -a "$LOG_FILE" || true
}

list_nvidia_cuda_holds() {
  apt-mark showhold 2>/dev/null | grep -E '^(cuda-|libcuda|libnvidia-|nvidia-|nsight-)' || true
}

prepare_for_upgrade() {
  log "Preparing NVIDIA/CUDA packages for target upgrade."

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: remove old lock file ${PIN_FILE} if present"
    log "DRY-RUN: unhold currently held NVIDIA/CUDA packages if any"
    return
  fi

  if [[ -f "$PIN_FILE" ]]; then
    log "RUN: remove old lock file ${PIN_FILE}"
    rm -f "$PIN_FILE"
  fi

  mapfile -t held_packages < <(list_nvidia_cuda_holds)
  if [[ "${#held_packages[@]}" -gt 0 ]]; then
    log "RUN: apt-mark unhold old NVIDIA/CUDA packages"
    apt-mark unhold "${held_packages[@]}" 2>&1 | tee -a "$LOG_FILE"
  else
    log "No existing NVIDIA/CUDA holds found."
  fi
}

detect_runfile_driver() {
  if command -v nvidia-installer >/dev/null 2>&1; then
    return 0
  fi

  [[ -x /usr/bin/nvidia-installer || -x /usr/lib/nvidia/nvidia-installer ]]
}

remove_runfile_driver() {
  if ! detect_runfile_driver; then
    log "No NVIDIA .run installer footprint detected."
    return
  fi

  log "NVIDIA .run installer footprint detected."

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: run nvidia-installer --uninstall --silent before apt installation"
    return
  fi

  if command -v nvidia-installer >/dev/null 2>&1; then
    log "RUN: nvidia-installer --uninstall --silent"
    nvidia-installer --uninstall --silent --no-questions 2>&1 | tee -a "$LOG_FILE" || \
      nvidia-installer --uninstall --silent 2>&1 | tee -a "$LOG_FILE" || \
      die "Failed to uninstall NVIDIA .run driver with nvidia-installer."
  elif [[ -x /usr/bin/nvidia-installer ]]; then
    log "RUN: /usr/bin/nvidia-installer --uninstall --silent"
    /usr/bin/nvidia-installer --uninstall --silent --no-questions 2>&1 | tee -a "$LOG_FILE" || \
      /usr/bin/nvidia-installer --uninstall --silent 2>&1 | tee -a "$LOG_FILE" || \
      die "Failed to uninstall NVIDIA .run driver with /usr/bin/nvidia-installer."
  elif [[ -x /usr/lib/nvidia/nvidia-installer ]]; then
    log "RUN: /usr/lib/nvidia/nvidia-installer --uninstall --silent"
    /usr/lib/nvidia/nvidia-installer --uninstall --silent --no-questions 2>&1 | tee -a "$LOG_FILE" || \
      /usr/lib/nvidia/nvidia-installer --uninstall --silent 2>&1 | tee -a "$LOG_FILE" || \
      die "Failed to uninstall NVIDIA .run driver with /usr/lib/nvidia/nvidia-installer."
  fi

  run ldconfig
  run update-initramfs -u
}

install_base_packages() {
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg lsb-release pciutils jq \
    parted xfsprogs linux-headers-"$(uname -r)" build-essential
}

install_nvidia_repo() {
  local keyring_pkg="cuda-keyring_1.1-1_all.deb"
  local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${UBUNTU_REPO_ID}/x86_64/${keyring_pkg}"

  run_shell "cd /tmp && curl -fsSLO '${keyring_url}'"
  run dpkg -i "/tmp/${keyring_pkg}"
  run apt-get update
}

candidate_version() {
  local package="$1"
  apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ { print $2; exit }'
}

require_candidate() {
  local package="$1"
  local candidate

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: check apt candidate for ${package}"
    return
  fi

  candidate="$(candidate_version "$package")"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] || die "No apt candidate found for ${package}."
  log "Apt candidate for ${package}: ${candidate}"
}

upstream_version() {
  local version="$1"
  version="${version#*:}"
  printf '%s\n' "${version%%-*}"
}

is_fourth_gen_nvswitch_system() {
  command -v lspci >/dev/null 2>&1 || return 1
  lspci | grep -Eiq 'B100|B200|B300|Blackwell'
}

driver_package() {
  if is_fourth_gen_nvswitch_system; then
    printf 'nvidia-open-%s\n' "$DRIVER_VERSION"
  else
    printf 'cuda-drivers-%s\n' "$DRIVER_VERSION"
  fi
}

driver_version_check_package() {
  if is_fourth_gen_nvswitch_system; then
    printf 'nvidia-open-%s\n' "$DRIVER_VERSION"
  else
    printf 'nvidia-driver-%s\n' "$DRIVER_VERSION"
  fi
}

fabric_manager_package() {
  if is_fourth_gen_nvswitch_system; then
    printf 'nvlink5-%s\n' "$DRIVER_VERSION"
  else
    printf 'cuda-drivers-fabricmanager-%s\n' "$DRIVER_VERSION"
  fi
}

fabric_version_check_package() {
  if is_fourth_gen_nvswitch_system; then
    printf 'nvlink5-%s\n' "$DRIVER_VERSION"
  else
    printf 'nvidia-fabricmanager-%s\n' "$DRIVER_VERSION"
  fi
}

should_install_fabric_manager() {
  case "$FABRIC_MANAGER_MODE" in
    always)
      return 0
      ;;
    never)
      return 1
      ;;
  esac

  if command -v lspci >/dev/null 2>&1 && lspci | grep -Eiq 'NVIDIA.*NVSwitch|NVSwitch'; then
    log "NVSwitch detected; Fabric Manager will be installed."
    return 0
  fi

  log "NVSwitch not detected; Fabric Manager will not be installed. Use --fabricmanager to force it."
  return 1
}

check_fabric_manager_candidate() {
  local driver_pkg
  local driver_check_pkg
  local fabric_pkg
  local fabric_check_pkg
  local driver_candidate
  local driver_check_candidate
  local fabric_candidate
  local fabric_check_candidate

  driver_pkg="$(driver_package)"
  driver_check_pkg="$(driver_version_check_package)"
  fabric_pkg="$(fabric_manager_package)"
  fabric_check_pkg="$(fabric_version_check_package)"

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: check apt candidates for ${driver_pkg}, ${driver_check_pkg}, ${fabric_pkg}, and ${fabric_check_pkg}"
    return
  fi

  driver_candidate="$(candidate_version "$driver_pkg")"
  driver_check_candidate="$(candidate_version "$driver_check_pkg")"
  fabric_candidate="$(candidate_version "$fabric_pkg")"
  fabric_check_candidate="$(candidate_version "$fabric_check_pkg")"

  [[ -n "$driver_candidate" && "$driver_candidate" != "(none)" ]] || die "No apt candidate found for ${driver_pkg}."
  [[ -n "$driver_check_candidate" && "$driver_check_candidate" != "(none)" ]] || die "No apt candidate found for ${driver_check_pkg}."
  [[ -n "$fabric_candidate" && "$fabric_candidate" != "(none)" ]] || die "No apt candidate found for ${fabric_pkg}."
  [[ -n "$fabric_check_candidate" && "$fabric_check_candidate" != "(none)" ]] || die "No apt candidate found for ${fabric_check_pkg}."

  if [[ "$(upstream_version "$driver_candidate")" != "$(upstream_version "$fabric_candidate")" ]]; then
    die "${driver_pkg} candidate ${driver_candidate} does not match ${fabric_pkg} candidate ${fabric_candidate}."
  fi

  if [[ "$(upstream_version "$driver_check_candidate")" != "$(upstream_version "$fabric_check_candidate")" ]]; then
    die "${driver_check_pkg} candidate ${driver_check_candidate} does not match ${fabric_check_pkg} candidate ${fabric_check_candidate}."
  fi

  log "Fabric Manager candidate matches driver branch: ${driver_check_pkg} ${driver_check_candidate}; ${fabric_check_pkg} ${fabric_check_candidate}."
}

disable_nouveau() {
  local conf="/etc/modprobe.d/blacklist-nouveau.conf"
  if [[ "$ASSUME_YES" == "true" ]]; then
    log "RUN: write ${conf}"
    cat > "$conf" <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u 2>&1 | tee -a "$LOG_FILE"
  else
    log "DRY-RUN: write ${conf} and update initramfs"
  fi
}

install_gpu_stack() {
  local cuda_pkg="cuda-toolkit-${CUDA_VERSION/./-}"
  local driver_pkg
  driver_pkg="$(driver_package)"
  local packages=("$driver_pkg" "$cuda_pkg")

  disable_nouveau
  require_candidate "$driver_pkg"
  require_candidate "$cuda_pkg"

  if should_install_fabric_manager; then
    check_fabric_manager_candidate
    packages+=("$(fabric_manager_package)")
  fi

  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  if dpkg-query -W -f='${Status}' "$(fabric_version_check_package)" 2>/dev/null | grep -q "install ok installed"; then
    run systemctl enable --now nvidia-fabricmanager
    verify_fabric_manager_version
  fi

  if [[ ! -e /etc/profile.d/cuda.sh || "$ASSUME_YES" != "true" ]]; then
    if [[ "$ASSUME_YES" == "true" ]]; then
      log "RUN: write /etc/profile.d/cuda.sh"
      cat > /etc/profile.d/cuda.sh <<EOF
export CUDA_HOME=/usr/local/cuda-${CUDA_VERSION}
export PATH=\$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\${LD_LIBRARY_PATH:-}
EOF
    else
      log "DRY-RUN: write /etc/profile.d/cuda.sh"
    fi
  fi
}

verify_fabric_manager_version() {
  local driver_pkg
  local fabric_pkg
  local driver_installed
  local fabric_installed

  driver_pkg="$(driver_version_check_package)"
  fabric_pkg="$(fabric_version_check_package)"

  driver_installed="$(dpkg-query -W -f='${Version}' "$driver_pkg" 2>/dev/null || true)"
  fabric_installed="$(dpkg-query -W -f='${Version}' "$fabric_pkg" 2>/dev/null || true)"

  if [[ -z "$driver_installed" || -z "$fabric_installed" ]]; then
    log "Fabric Manager version check skipped because one package is not installed yet."
    return
  fi

  if [[ "$(upstream_version "$driver_installed")" != "$(upstream_version "$fabric_installed")" ]]; then
    die "Installed ${driver_pkg} ${driver_installed} does not match ${fabric_pkg} ${fabric_installed}."
  fi

  log "Installed Fabric Manager matches driver exactly: ${fabric_installed}."
}

lock_installed_versions() {
  [[ "$LOCK_VERSIONS" == "true" ]] || return 0

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: apt-mark hold installed NVIDIA/CUDA packages"
    log "DRY-RUN: write ${PIN_FILE} with installed package versions"
    return
  fi

  mapfile -t locked_packages < <(
    dpkg-query -W -f='${Package} ${Version}\n' \
      'cuda-*' 'libcuda*' 'libnvidia-*' 'nvidia-*' 'nsight-*' 2>/dev/null |
      awk '$2 != "" { print $1 }' |
      sort -u
  )

  if [[ "${#locked_packages[@]}" -eq 0 ]]; then
    log "No installed NVIDIA/CUDA packages found to lock."
    return
  fi

  log "RUN: apt-mark hold NVIDIA/CUDA packages"
  apt-mark hold "${locked_packages[@]}" 2>&1 | tee -a "$LOG_FILE"

  log "RUN: write ${PIN_FILE}"
  {
    printf '# Managed by %s. Remove this file and run apt-mark unhold to upgrade intentionally.\n\n' "$SCRIPT_NAME"
    dpkg-query -W -f='${Package} ${Version}\n' \
      'cuda-*' 'libcuda*' 'libnvidia-*' 'nvidia-*' 'nsight-*' 2>/dev/null |
      sort -u |
      while read -r package version; do
        [[ -n "${package:-}" && -n "${version:-}" ]] || continue
        printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$package" "$version"
      done
  } > "$PIN_FILE"
}

install_container_toolkit() {
  [[ "$INSTALL_DOCKER_NVIDIA" == "true" ]] || return 0

  run_shell "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  run_shell "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list"
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit

  if command -v docker >/dev/null 2>&1; then
    run nvidia-ctk runtime configure --runtime=docker
    run systemctl restart docker
  else
    log "Docker not found; NVIDIA Container Toolkit installed but Docker runtime was not configured."
  fi
}

root_source_name() {
  findmnt -n -o SOURCE / | sed -E 's#^/dev/##; s#[0-9]+$##; s#p$##'
}

is_system_disk() {
  local disk_name="$1"
  local root_name
  root_name="$(root_source_name)"
  [[ "$disk_name" == "$root_name" ]]
}

has_mountpoint() {
  local name="$1"
  lsblk -nr -o MOUNTPOINT "/dev/$name" | awk 'NF { found=1 } END { exit found ? 0 : 1 }'
}

filesystem_type() {
  local path="$1"
  blkid -o value -s TYPE "$path" 2>/dev/null || true
}

has_any_signature() {
  [[ -n "$(filesystem_type "$1")" ]]
}

is_mountable_filesystem() {
  local path="$1"
  local fs_type
  fs_type="$(filesystem_type "$path")"

  case "$fs_type" in
    ext2|ext3|ext4|xfs|btrfs|zfs|ntfs|exfat)
      return 0
      ;;
    "")
      return 1
      ;;
    *)
      log "Skip ${path}; detected non-auto-mounted signature: ${fs_type}."
      return 1
      ;;
  esac
}

mount_device() {
  local path="$1"
  local mountpoint="$2"
  local uuid

  uuid="$(blkid -o value -s UUID "$path" 2>/dev/null || true)"
  if [[ -z "$uuid" && "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: would mount ${path} at ${mountpoint} after filesystem UUID is available"
    return
  fi
  [[ -n "$uuid" ]] || die "Cannot determine UUID for ${path}."

  run mkdir -p "$mountpoint"

  if ! grep -q "UUID=${uuid}" /etc/fstab 2>/dev/null; then
    backup_fstab
    local opts="defaults,nofail"
    local fs_type
    fs_type="$(filesystem_type "$path")"
    run_shell "printf '%s\n' 'UUID=${uuid} ${mountpoint} ${fs_type} ${opts} 0 2' >> /etc/fstab"
  else
    log "fstab already contains UUID=${uuid}."
  fi

  run mount "$mountpoint"
  MOUNT_RESULTS+=("${path} -> ${mountpoint}")
}

backup_fstab() {
  [[ "$FSTAB_BACKED_UP" == "true" ]] && return 0

  if [[ "$ASSUME_YES" == "true" ]]; then
    local backup_path="/etc/fstab.backup.$(date '+%Y%m%d%H%M%S')"
    log "RUN: backup /etc/fstab to ${backup_path}"
    cp -a /etc/fstab "$backup_path"
  else
    log "DRY-RUN: backup /etc/fstab before editing"
  fi

  FSTAB_BACKED_UP="true"
}

mountpoint_in_fstab() {
  local mountpoint="$1"
  awk -v target="$mountpoint" '$1 !~ /^#/ && $2 == target { found=1 } END { exit found ? 0 : 1 }' /etc/fstab 2>/dev/null
}

next_mountpoint() {
  while findmnt -rn "$MOUNT_BASE${MOUNT_INDEX}" >/dev/null 2>&1 || mountpoint_in_fstab "$MOUNT_BASE${MOUNT_INDEX}"; do
    MOUNT_INDEX=$((MOUNT_INDEX + 1))
  done

  printf '%s%s\n' "$MOUNT_BASE" "$MOUNT_INDEX"
  MOUNT_INDEX=$((MOUNT_INDEX + 1))
}

mount_data_disks() {
  log "Scanning unmounted data disks."
  mapfile -t disks < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" { print $1 }')

  MOUNT_INDEX=1
  for disk in "${disks[@]}"; do
    local disk_path="/dev/${disk}"

    if is_system_disk "$disk"; then
      log "Skip system disk ${disk_path}."
      SKIP_RESULTS+=("${disk_path}: system disk")
      continue
    fi

    if has_mountpoint "$disk"; then
      log "Skip ${disk_path}; it already has mounted content."
      SKIP_RESULTS+=("${disk_path}: already mounted")
      continue
    fi

    mapfile -t parts < <(lsblk -nr -o NAME,TYPE "$disk_path" | awk '$2 == "part" { print $1 }')

    if [[ "${#parts[@]}" -eq 0 ]]; then
      if is_mountable_filesystem "$disk_path"; then
        mount_device "$disk_path" "$(next_mountpoint)"
      elif has_any_signature "$disk_path"; then
        log "Skip ${disk_path}; it has a non-mountable signature and will not be formatted automatically."
        SKIP_RESULTS+=("${disk_path}: non-mountable signature")
      elif [[ "$FORMAT_EMPTY" == "true" ]]; then
        log "Preparing blank disk ${disk_path}."
        run wipefs -a "$disk_path"
        run parted -s "$disk_path" mklabel gpt
        run parted -s "$disk_path" mkpart primary 0% 100%
        run partprobe "$disk_path"
        run udevadm settle
        local part_path="${disk_path}1"
        [[ "$disk" =~ [0-9]$ ]] && part_path="${disk_path}p1"
        run mkfs."$FILESYSTEM" -F "$part_path"
        mount_device "$part_path" "$(next_mountpoint)"
      else
        log "Skip blank disk ${disk_path}; add --format-empty to format it."
        SKIP_RESULTS+=("${disk_path}: blank disk skipped")
      fi
      continue
    fi

    for part in "${parts[@]}"; do
      local part_path="/dev/${part}"
      if has_mountpoint "$part"; then
        log "Skip ${part_path}; already mounted."
        SKIP_RESULTS+=("${part_path}: already mounted")
        continue
      fi

      if is_mountable_filesystem "$part_path"; then
        mount_device "$part_path" "$(next_mountpoint)"
      else
        log "Skip ${part_path}; partition has no filesystem."
        SKIP_RESULTS+=("${part_path}: no mountable filesystem")
      fi
    done
  done
}

verify_result() {
  log "Enhanced verification:"

  if [[ "$ASSUME_YES" != "true" ]]; then
    log "DRY-RUN: run enhanced delivery verification after installation"
    return
  fi

  nvidia-smi 2>&1 | tee -a "$LOG_FILE" || true
  nvcc --version 2>&1 | tee -a "$LOG_FILE" || true
  nvidia-smi topo -m 2>&1 | tee -a "$LOG_FILE" || true
  nvidia-smi -q -d PERSISTENCE_MODE 2>&1 | tee -a "$LOG_FILE" || true
  nvidia-smi -q | grep -Ei 'MIG Mode|Current MIG' 2>&1 | tee -a "$LOG_FILE" || true

  if systemctl list-unit-files nvidia-fabricmanager.service >/dev/null 2>&1; then
    systemctl status nvidia-fabricmanager --no-pager 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "nvidia-fabricmanager service not present."
  fi

  apt-mark showhold 2>/dev/null | grep -E '^(cuda-|libcuda|libnvidia-|nvidia-|nsight-)' | tee -a "$LOG_FILE" || true
  lsblk -f 2>&1 | tee -a "$LOG_FILE" || true
  findmnt --verify 2>&1 | tee -a "$LOG_FILE" || true
}

installed_version() {
  local package="$1"
  dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true
}

gpu_count() {
  command -v nvidia-smi >/dev/null 2>&1 || {
    printf '0\n'
    return
  }

  nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true
}

fabric_service_state() {
  if systemctl list-unit-files nvidia-fabricmanager.service >/dev/null 2>&1; then
    systemctl is-active nvidia-fabricmanager 2>/dev/null || true
  else
    printf 'not-installed\n'
  fi
}

delivery_summary() {
  local driver_pkg
  local cuda_pkg
  local fabric_pkg
  local holds_count

  driver_pkg="$(driver_version_check_package)"
  cuda_pkg="cuda-toolkit-${CUDA_VERSION/./-}"
  fabric_pkg="$(fabric_version_check_package)"
  holds_count="$(apt-mark showhold 2>/dev/null | grep -Ec '^(cuda-|libcuda|libnvidia-|nvidia-|nsight-)' || true)"

  log "===== Delivery Summary ====="
  log "Target driver branch: ${DRIVER_VERSION}"
  log "Target CUDA toolkit: ${CUDA_VERSION}"
  log "Installed driver package: ${driver_pkg} $(installed_version "$driver_pkg")"
  log "Installed CUDA package: ${cuda_pkg} $(installed_version "$cuda_pkg")"
  log "Installed Fabric/NVLink package: ${fabric_pkg} $(installed_version "$fabric_pkg")"
  log "GPU count detected: $(gpu_count)"
  log "Fabric Manager service: $(fabric_service_state)"
  log "Version lock enabled: ${LOCK_VERSIONS}; held NVIDIA/CUDA packages: ${holds_count}"
  log "NVIDIA Container Toolkit requested: ${INSTALL_DOCKER_NVIDIA}"
  log "Reboot requested: ${REBOOT}"

  if [[ "${#MOUNT_RESULTS[@]}" -gt 0 ]]; then
    log "Mounted data devices:"
    printf '  %s\n' "${MOUNT_RESULTS[@]}" | tee -a "$LOG_FILE"
  else
    log "Mounted data devices: none"
  fi

  if [[ "${#SKIP_RESULTS[@]}" -gt 0 ]]; then
    log "Skipped devices:"
    printf '  %s\n' "${SKIP_RESULTS[@]}" | tee -a "$LOG_FILE"
  fi

  if [[ "$REBOOT" == "true" ]]; then
    log "Final action: reboot will be triggered."
  else
    log "Final action: manual reboot recommended after driver changes."
  fi
  log "===== End Delivery Summary ====="
}

main() {
  parse_args "$@"
  require_root
  validate_inputs
  detect_ubuntu
  confirm_execution

  preflight_checks
  show_current_gpu_stack
  guard_active_workloads
  remove_runfile_driver
  prepare_for_upgrade
  install_base_packages
  check_network_access
  install_nvidia_repo
  install_gpu_stack
  install_container_toolkit
  lock_installed_versions
  mount_data_disks
  verify_result
  delivery_summary

  log "Provisioning flow complete."
  if [[ "$ASSUME_YES" == "true" && "$REBOOT" == "true" ]]; then
    run reboot
  else
    log "A reboot is recommended after changing NVIDIA drivers."
  fi
}

main "$@"
