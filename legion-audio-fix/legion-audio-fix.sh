#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${STATE_DIR:-/var/lib/legion-audio-fix}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/legion-audio-fix}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.env}"

WORK_DIR="${WORK_DIR:-/usr/src/legion-audio-fix}"
PATCH_BASE_URL="${PATCH_BASE_URL:-https://raw.githubusercontent.com/nadimkobeissi/16iax10h-linux-sound-saga/e13e1a3090a2a249be606d609081bac23ffc8049/fix/patches}"

FIRMWARE_URL="${FIRMWARE_URL:-https://raw.githubusercontent.com/nadimkobeissi/16iax10h-linux-sound-saga/e13e1a3090a2a249be606d609081bac23ffc8049/fix/firmware/aw88399_acf.bin}"
ORIGINAL_FIRMWARE="/lib/firmware/aw88399_acf.bin"
ORIGINAL_FIRMWARE_ALT="/lib/firmware/awinic/aw88399.acf"

BUILD_DEPS=(
  build-essential
  libncurses-dev
  flex
  bison
  gawk
  libssl-dev
  libelf-dev
  libdw-dev
  dwarves
  bc
  rsync
  dkms
  git
  curl
  xz-utils
)

log() { printf '%s\n' "$*"; }
die() { log "error: $*"; exit 1; }

run_logged() {
  local log_file="$1"
  shift
  "$@" 2>&1 | tee -a "$log_file"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this script with sudo"
}

ensure_dirs() {
  install -d -m 0755 "$STATE_DIR" "$BACKUP_DIR" "$WORK_DIR"
}

backup_path_for() {
  local path="$1"
  printf '%s/%s' "$BACKUP_DIR" "${path#/}"
}

backup_file_if_exists() {
  local path="$1"
  local backup
  backup="$(backup_path_for "$path")"
  if [[ -e "$path" && ! -e "$backup" ]]; then
    install -d -m 0755 "$(dirname "$backup")"
    cp -a "$path" "$backup"
  fi
}

restore_file_if_backed_up() {
  local path="$1"
  local backup
  backup="$(backup_path_for "$path")"
  if [[ -e "$backup" ]]; then
    install -d -m 0755 "$(dirname "$path")"
    cp -a "$backup" "$path"
  else
    rm -f "$path"
  fi
}

save_state() {
  [[ -r "$STATE_FILE" ]] && return 0
  cat >"$STATE_FILE" <<EOF
ORIGINAL_KERNEL=$(uname -r)
EOF
}

set_state_var() {
  local key="$1"
  local value="$2"

  if [[ ! -r "$STATE_FILE" ]]; then
    save_state
  fi

  if grep -q "^${key}=" "$STATE_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#g" "$STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$STATE_FILE"
  fi
}

load_state() {
  [[ -r "$STATE_FILE" ]] || die "missing saved state; run '$SCRIPT_NAME apply' first"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${ORIGINAL_KERNEL:-}" ]] || die "state file does not contain ORIGINAL_KERNEL"
}

ensure_state() {
  [[ -r "$STATE_FILE" ]] || save_state
  load_state
}

kernel_series_from_release() {
  local release="$1"
  release="${release%%-*}" # e.g. 7.0.0
  printf '%s\n' "${release%.*}" # e.g. 7.0
}

kernel_suffix_from_release() {
  local release="$1"
  if [[ "$release" == *-* ]]; then
    printf -- '-%s\n' "${release#*-}" # e.g. -22-generic
  else
    printf '%s\n' "-generic"
  fi
}

kernel_tarball_url_for_series() {
  local series="$1" # e.g. 7.0
  local major="${series%%.*}"
  printf 'https://cdn.kernel.org/pub/linux/kernel/v%s.x/linux-%s.tar.xz\n' "$major" "$series"
}

patch_url_for_series() {
  local series="$1" # e.g. 7.0
  printf '%s/16iax10h-audio-linux-%s.patch\n' "$PATCH_BASE_URL" "$series"
}

local_patch_file_for_series() {
  local series="$1" # e.g. 7.0
  printf '%s/16iax10h-audio-linux-%s.patch\n' "$SCRIPT_DIR" "$series"
}

grub_entry_for_kernel() {
  local kernel_version="$1"

  [[ -r /boot/grub/grub.cfg ]] || return 1
  python3 - "$kernel_version" <<'PY'
import re
import sys

kernel_version = sys.argv[1]
current_submenu = ""
submenu_depth = 0

with open("/boot/grub/grub.cfg", encoding="utf-8", errors="ignore") as fh:
    for raw_line in fh:
        line = raw_line.strip()

        submenu_match = re.match(r"submenu\s+'([^']+)'", line)
        if submenu_match:
            current_submenu = submenu_match.group(1)
            submenu_depth = line.count("{") - line.count("}")
            continue

        menuentry_match = re.match(r"menuentry\s+'([^']+)'", line)
        if menuentry_match:
            menuentry = menuentry_match.group(1)
            if menuentry.startswith(f"Ubuntu, with Linux {kernel_version}"):
                if current_submenu:
                    print(f"{current_submenu}>{menuentry}")
                else:
                    print(menuentry)
                raise SystemExit(0)

        if current_submenu:
            submenu_depth += line.count("{") - line.count("}")
            if submenu_depth <= 0:
                current_submenu = ""
                submenu_depth = 0

raise SystemExit(1)
PY
}

installed_kernels() {
  local current
  current="$(uname -r)"
  shopt -s nullglob
  for image in /boot/vmlinuz-*; do
    local version="${image#/boot/vmlinuz-}"
    if [[ "$version" == "$current" ]]; then
      printf '* %s (current)\n' "$version"
    else
      printf '  %s\n' "$version"
    fi
  done
  shopt -u nullglob
}

kernel_installed() {
  local kernel_version="$1"
  [[ -e "/boot/vmlinuz-$kernel_version" ]]
}

install_firmware() {
  local tmp_fw
  tmp_fw="$(mktemp)"

  curl -fsSL "$FIRMWARE_URL" -o "$tmp_fw"

  backup_file_if_exists "$ORIGINAL_FIRMWARE"
  backup_file_if_exists "$ORIGINAL_FIRMWARE_ALT"

  install -d -m 0755 /lib/firmware/awinic
  install -m 0644 "$tmp_fw" "$ORIGINAL_FIRMWARE"
  install -m 0644 "$tmp_fw" "$ORIGINAL_FIRMWARE_ALT"
  rm -f "$tmp_fw"
}

install_build_deps() {
  apt-get update
  apt-get install -y "${BUILD_DEPS[@]}"
}

apply_patch_if_needed() {
  local source_dir="$1"
  local patch_file="$2"

  cd "$source_dir"

  if grep -q "ALC287_FIXUP_LENOVO_LEGION_AW88399" sound/hda/codecs/realtek/alc269.c; then
    log "kernel source already contains the Legion AW88399 patch; reusing it"
    return 0
  fi

  patch -p1 --forward < "$patch_file"
}

configure_patched_kernel() {
  local source_dir="$1"
  local base_kernel="$2"
  local local_version

  local_version="$(kernel_suffix_from_release "$base_kernel")-patched"

  cd "$source_dir"
  cp "/boot/config-$base_kernel" .config
  make olddefconfig

  ./scripts/config --set-str LOCALVERSION "$local_version"
  ./scripts/config --disable LOCALVERSION_AUTO
  ./scripts/config --module SND_HDA_SCODEC_AW88399
  ./scripts/config --module SND_HDA_SCODEC_AW88399_I2C
  ./scripts/config --module SND_SOC_AW88399
  ./scripts/config --enable SND_SOC_SOF_INTEL_TOPLEVEL
  ./scripts/config --module SND_SOC_SOF_INTEL_COMMON
  ./scripts/config --module SND_SOC_SOF_INTEL_MTL
  ./scripts/config --module SND_SOC_SOF_INTEL_LNL
  # Ubuntu kernel configs often reference distro cert files not present in vanilla trees.
  ./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
  ./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

  make olddefconfig
}

default_build_jobs() {
  local cpu_count jobs
  cpu_count="$(nproc)"
  if (( cpu_count > 2 )); then
    jobs=$((cpu_count - 2))
  else
    jobs=1
  fi
  printf '%s\n' "$jobs"
}

build_and_install_patched_kernel() {
  local base_kernel="${1:-$(uname -r)}"
  local series tarball_name tarball_url tarball_path
  local source_dir patch_url patch_file local_patch_file kernel_release jobs build_log

  [[ -r "/boot/config-$base_kernel" ]] || die "missing /boot/config-$base_kernel"

  series="$(kernel_series_from_release "$base_kernel")"
  tarball_name="linux-$series.tar.xz"
  tarball_url="$(kernel_tarball_url_for_series "$series")"
  tarball_path="$WORK_DIR/$tarball_name"
  source_dir="$WORK_DIR/linux-$series"
  patch_url="$(patch_url_for_series "$series")"
  patch_file="$WORK_DIR/16iax10h-audio-linux-$series.patch"
  local_patch_file="$(local_patch_file_for_series "$series")"
  jobs="${KERNEL_BUILD_JOBS:-$(default_build_jobs)}"
  build_log="$WORK_DIR/build-patched-kernel-${base_kernel}-$(date +%Y%m%d-%H%M%S).log"

  log "installing kernel build dependencies"
  install_build_deps

  if [[ ! -f "$tarball_path" ]]; then
    log "downloading kernel source: $tarball_url"
    curl -fsSL "$tarball_url" -o "$tarball_path"
  fi

  if [[ ! -d "$source_dir" ]]; then
    log "extracting kernel source to $source_dir"
    tar -xf "$tarball_path" -C "$WORK_DIR"
  fi

  if [[ -r "$local_patch_file" ]]; then
    log "using bundled Legion audio patch: $local_patch_file"
    patch_file="$local_patch_file"
  else
    log "downloading Legion audio patch: $patch_url"
    curl -fsSL "$patch_url" -o "$patch_file"
  fi

  log "applying patch"
  apply_patch_if_needed "$source_dir" "$patch_file"

  log "configuring patched kernel"
  configure_patched_kernel "$source_dir" "$base_kernel"

  log "building kernel (this can take a while)"
  log "full build log: $build_log"
  log "parallel build jobs: $jobs"
  cd "$source_dir"
  run_logged "$build_log" make -j"$jobs"
  kernel_release="$(make -s kernelrelease)"

  log "installing modules and kernel image"
  run_logged "$build_log" make modules_install
  run_logged "$build_log" make install

  if command -v update-initramfs >/dev/null 2>&1; then
    run_logged "$build_log" update-initramfs -u -k "$kernel_release" || run_logged "$build_log" update-initramfs -c -k "$kernel_release"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    run_logged "$build_log" update-grub
  fi

  set_state_var LAST_PATCHED_KERNEL "$kernel_release"
  set_state_var LAST_BUILD_LOG "$build_log"
  restore_original_kernel

  log "patched kernel installed: $kernel_release"
  log "both kernels should now appear in GRUB"
  log "test it once with: sudo $SCRIPT_NAME test-kernel $kernel_release"
}

set_one_time_kernel() {
  local kernel_version="$1"
  local entry

  ensure_state
  if [[ "$kernel_version" == "$(uname -r)" ]]; then
    die "kernel $kernel_version is the one you are already running. Install or build a different kernel version first, then test it."
  fi
  if ! kernel_installed "$kernel_version"; then
    die "kernel $kernel_version is not installed yet. Run '$SCRIPT_NAME list-kernels' to see what is available."
  fi
  entry="$(grub_entry_for_kernel "$kernel_version" || true)"
  [[ -n "$entry" ]] || die "could not find a GRUB menu entry for kernel $kernel_version"
  grub-reboot "$entry"
  log "next boot will use: $entry"
}

set_default_kernel() {
  local kernel_version="$1"
  local entry

  ensure_state
  if ! kernel_installed "$kernel_version"; then
    die "kernel $kernel_version is not installed yet. Run '$SCRIPT_NAME list-kernels' to see what is available."
  fi
  entry="$(grub_entry_for_kernel "$kernel_version" || true)"
  [[ -n "$entry" ]] || die "could not find a GRUB menu entry for kernel $kernel_version"
  grub-set-default "$entry"
  log "default kernel set to: $entry"
}

restore_original_kernel() {
  local entry

  load_state
  entry="$(grub_entry_for_kernel "$ORIGINAL_KERNEL" || true)"
  [[ -n "$entry" ]] || die "could not find a GRUB menu entry for the original kernel $ORIGINAL_KERNEL"
  grub-set-default "$entry"
  log "default kernel restored to: $entry"
}

rollback_everything() {
  restore_file_if_backed_up "$ORIGINAL_FIRMWARE"
  restore_file_if_backed_up "$ORIGINAL_FIRMWARE_ALT"
  restore_original_kernel
  log "firmware restored and original kernel selected"
}

show_status() {
  if [[ -r "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    log "saved original kernel: ${ORIGINAL_KERNEL:-unknown}"
    log "last patched kernel: ${LAST_PATCHED_KERNEL:-none yet}"
  else
    log "saved original kernel: none yet"
    log "last patched kernel: none yet"
  fi

  log "running kernel: $(uname -r)"
  log "firmware bin: $(test -e "$ORIGINAL_FIRMWARE" && echo present || echo missing)"
  log "firmware acf: $(test -e "$ORIGINAL_FIRMWARE_ALT" && echo present || echo missing)"
}

usage() {
  cat <<EOF
Usage:
  sudo $SCRIPT_NAME apply
  sudo $SCRIPT_NAME build-patched-kernel [base-kernel]
  sudo $SCRIPT_NAME list-kernels
  sudo $SCRIPT_NAME test-kernel <kernel-version>
  sudo $SCRIPT_NAME keep-kernel <kernel-version>
  sudo $SCRIPT_NAME rollback
  sudo $SCRIPT_NAME status

What the commands mean:
  apply               Save your current kernel and install the AW88399 firmware file.
  build-patched-kernel Build and install a side-by-side patched kernel entry.
                      Default base kernel is your current running kernel.
  list-kernels        Show kernels already installed on this machine.
  test-kernel         Boot into a different kernel once, for testing.
  keep-kernel         Make a kernel the default boot choice.
  rollback            Restore firmware backup and set original kernel as default.
  status              Show what this script has saved and what is installed now.
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    apply)
      require_root
      ensure_dirs
      save_state
      install_firmware
      log "saved your current kernel for recovery"
      log "installed the AW88399 firmware blob"
      ;;
    build-patched-kernel)
      require_root
      ensure_dirs
      save_state
      build_and_install_patched_kernel "${2:-}"
      ;;
    list-kernels)
      installed_kernels
      ;;
    test-kernel)
      require_root
      [[ $# -ge 2 ]] || die "test-kernel needs a kernel version"
      set_one_time_kernel "$2"
      ;;
    keep-kernel)
      require_root
      [[ $# -ge 2 ]] || die "keep-kernel needs a kernel version"
      set_default_kernel "$2"
      ;;
    rollback)
      require_root
      ensure_dirs
      rollback_everything
      ;;
    status)
      show_status
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
