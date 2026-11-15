#!/usr/bin/env bash
# mb81-audio.sh — one-shot internal-speaker + audio installer for the
# 12-inch MacBook (Early 2015, MacBook8,1, A1534) on Debian / Ubuntu / Linux Mint.
#
#   sudo ./mb81-audio.sh               install (then reboot once)
#   sudo ./mb81-audio.sh --uninstall   remove everything, restore stock drivers
#   sudo ./mb81-audio.sh --verify      after reboot: is the driver loaded, does audio flow?
#   sudo ./mb81-audio.sh --rebuild     rebuild the DKMS modules for every installed kernel
#   sudo ./mb81-audio.sh --fix-chime   only un-mute the EFI startup chime (see below)
#
# What it installs (all pieces are required together; see HOW_IT_WORKS.md upstream):
#   A  snd-hda-intel         patched: attach to the live EFI link without a controller reset
#   B  modprobe options      single_cmd=1 power_save=0 + softdep so cs420x binds first
#   C  snd-hda-codec-cs420x  patched Cirrus CS4208 driver (4-ch TDM speaker path, amp coef image)
#   D  snd-hda-codec-generic patched: skips the input bring-up that latches the codec clock fault
#   -  PipeWire EQ sink + WirePlumber raw-PCM speaker node (WirePlumber 0.4 Lua OR >=0.5 conf, auto-picked)
#   -  headphone-jack auto-switch (systemd user service, enabled for every user)
#   -  suspend/resume recovery (systemd system service)
# A, C, D are built by DKMS and rebuild on every kernel upgrade.
#
# Source of the kernel patches: omnidecker/macbook8.1-speaker-driver (a fork of
# thomas-shirley/macbook8.1-speaker-driver), fetched at install time and pinned to one commit
# that is verified before anything is built. Nothing from it is bundled here.
set -Eeuo pipefail

PIN_REPO="https://github.com/omnidecker/macbook8.1-speaker-driver.git"
PIN_COMMIT="e4134fb272ba3be29aa71ad7aa6eae8b0ebddf1a"   # 2026-09-10, validated upstream on 6.17 and 7.2.4

BASE=/opt/mb81-audio
SRC=$BASE/src
LOG=/var/log/mb81-audio.log
DKMS_NAME=macbook12-audio          # name is baked into the upstream dkms.conf
DKMS_VER=0.1
DKMS_SRC_LINK=/usr/src/$DKMS_NAME-$DKMS_VER
HDA_PCI=0000:00:1b.0
EFIVARS=/sys/firmware/efi/efivars
APPLE_GUID=7c436110-ab2a-4bbb-a880-fe41995c9f82

ACTION=install ASSUME_YES=0 FORCE_MODEL=0 SRC_OVERRIDE="" REAL_USER="" FETCH_TMP=""
trap '[[ -n $FETCH_TMP ]] && rm -rf "$FETCH_TMP"' EXIT

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- progress bar ---------------------------------------------------------------------------
# STEP_TOTAL steps in the install flow; step N draws "[#####.....] 3/8 label". Falls back to
# plain lines when stdout is not a terminal (logs, cron, piping through tee).
STEP_TOTAL=8 STEP_NOW=0 PB_TTY=0
[[ -t 1 ]] && PB_TTY=1
pb_draw() {   # pb_draw <step> <label> [percent-within-step]
  local n=$1 label=$2 sub=${3:-0} pct
  (( PB_TTY )) || { printf '[%d/%d] %s\n' "$n" "$STEP_TOTAL" "$label"; return; }
  pct=$(( ( (n-1)*100 + sub ) / STEP_TOTAL ))
  printf '\r\033[K%s %3d%%  %d/%d  %s' "$(pb_bar "$pct")" "$pct" "$n" "$STEP_TOTAL" "$label"
}
pb_step() {   # pb_step <label>: advance to the next numbered step and draw it
  STEP_NOW=$(( STEP_NOW + 1 )); pb_draw "$STEP_NOW" "$1" 0
}
pb_done() {   # finish the current step: the bar fills to the end of this step's share
  local label=${1:-done} pct
  pct=$(( STEP_NOW * 100 / STEP_TOTAL ))
  (( STEP_NOW < STEP_TOTAL )) || pct=100
  if (( PB_TTY )); then
    printf '\r\033[K%s %3d%%  %d/%d  %s\n' "$(pb_bar "$pct")" "$pct" "$STEP_NOW" "$STEP_TOTAL" "$label"
  else
    printf '    %s\n' "$label"
  fi
}
pb_bar() {    # pb_bar <percent>: prints [#####.....] for a percentage
  local pct=$1 width=28 filled empty bar="" dots=""
  filled=$(( pct * width / 100 )); empty=$(( width - filled ))
  printf -v bar '%*s' "$filled" ''; bar=${bar// /#}
  printf -v dots '%*s' "$empty" ''; dots=${dots// /.}
  printf '[%s%s]' "$bar" "$dots"
}
# run_with_progress <step-label> <cmd...> : runs cmd, keeps the bar moving, shows a spinner
# so long DKMS builds never look hung, and prints the full output to the log only.
run_with_progress() {
  local label=$1; shift
  local logf base_pct=$(( STEP_NOW * 100 / STEP_TOTAL )); logf=$(mktemp "${TMPDIR:-/tmp}/mb81-step.XXXXXX")
  "$@" >"$logf" 2>&1 & local pid=$! i=0 spin='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    if (( PB_TTY )); then
      printf '\r\033[K%s %s %s' "$(pb_bar "$base_pct")" "${spin:i%4:1}" "$label"
    fi
    i=$(( i + 1 )); sleep 0.2
  done
  local rc=0; wait "$pid" || rc=$?
  if (( rc == 0 )); then printf '\r\033[K'; pb_done "$label"
  else (( PB_TTY )) && printf '\r\033[K'; warn "$label failed (exit $rc). Last output:"; tail -n 25 "$logf" >&2; rm -f "$logf"; return "$rc"; fi
  cat "$logf" >> "$LOG" 2>/dev/null || true; rm -f "$logf"
}

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options:
  -y, --yes          do not ask questions (also un-mutes the EFI chime if muted)
  --src DIR          use a local checkout of the upstream repo (must be clean and at the pinned commit)
  --force-model      skip the MacBook8,1 / PCI-ID safety checks (the patches will probably do nothing)
  -h, --help
EOF
}

while (($#)); do
  case $1 in
    --install) ACTION=install ;;
    --uninstall|--remove|-r|-u) ACTION=uninstall ;;
    --verify) ACTION=verify ;;
    --rebuild) ACTION=rebuild ;;
    --fix-chime) ACTION=chime ;;
    -y|--yes) ASSUME_YES=1 ;;
    --force-model) FORCE_MODEL=1 ;;
    --src) [[ -n ${2:-} ]] || die "--src needs a directory"; SRC_OVERRIDE=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

detect_user() {
  REAL_USER=${SUDO_USER:-}
  [[ -z $REAL_USER || $REAL_USER == root ]] && REAL_USER=$(logname 2>/dev/null || true)
  [[ -z $REAL_USER || $REAL_USER == root ]] && REAL_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
  return 0
}

# Run a command inside the desktop user's session environment (PipeWire/pactl live there).
as_user() {
  [[ -n $REAL_USER ]] || return 1
  local uid; uid=$(id -u "$REAL_USER")
  runuser -u "$REAL_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

confirm() {   # confirm "question" -> 0 = yes
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 1
  local a; read -r -p "$1 [Y/n] " a; [[ -z $a || $a =~ ^[Yy] ]]
}

kernel_ge() {  # kernel_ge MAJOR MINOR  (running kernel >= MAJOR.MINOR)
  local k=${1:?} m=${2:?} cur_maj cur_min v; v=$(uname -r)
  cur_maj=${v%%.*}; cur_min=${v#*.}; cur_min=${cur_min%%[!0-9]*}
  (( cur_maj > k || (cur_maj == k && cur_min >= m) ))
}

wp_version() { wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; }
wp_is_modern() {  # WirePlumber >= 0.5 uses wireplumber.conf.d; 0.4.x uses Lua main.lua.d
  local v maj min; v=$(wp_version); [[ -n $v ]] || return 1
  maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  (( maj > 0 || min >= 5 ))
}

# ----------------------------------------------------------------------------------------------
# EFI startup chime. The speaker amplifier is powered by firmware only while it plays the chime;
# a muted chime (NVRAM bit 7 of SystemAudioVolume, or StartupMute=1) means no software fix can work.
# ----------------------------------------------------------------------------------------------
chime_state() {   # echoes: muted | unmuted | unknown
  local f b
  f=$EFIVARS/SystemAudioVolume-$APPLE_GUID
  if [[ -r $f ]]; then
    b=$(tail -c1 "$f" | od -An -tu1 | tr -d ' '); [[ -n $b ]] || { echo unknown; return; }
    (( b & 0x80 )) && echo muted || echo unmuted; return
  fi
  f=$EFIVARS/StartupMute-$APPLE_GUID
  if [[ -r $f ]]; then
    b=$(tail -c1 "$f" | od -An -tu1 | tr -d ' '); [[ -n $b ]] || { echo unknown; return; }
    (( b == 1 )) && echo muted || echo unmuted; return
  fi
  echo unknown
}

fix_chime() {
  local f b new
  [[ -d $EFIVARS ]] || { warn "efivarfs not available; cannot touch NVRAM"; return 1; }
  if [[ -r $EFIVARS/SystemAudioVolume-$APPLE_GUID ]]; then
    f=$EFIVARS/SystemAudioVolume-$APPLE_GUID
    b=$(tail -c1 "$f" | od -An -tu1 | tr -d ' ')
    new=$(( b & 0x7f ))                       # clear only the mute bit, keep the volume bits
  elif [[ -r $EFIVARS/StartupMute-$APPLE_GUID ]]; then
    f=$EFIVARS/StartupMute-$APPLE_GUID; new=0
  else
    warn "no chime NVRAM variable found; nothing to change"; return 0
  fi
  chattr -i "$f" 2>/dev/null || true
  # One write() on an O_WRONLY fd with standard attributes 0x00000007 (tee/O_TRUNC makes efivarfs delete it).
  if python3 - "$f" "$new" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
os.write(fd, bytes([0x07, 0x00, 0x00, 0x00, int(sys.argv[2])]))
os.close(fd)
PY
  then
    [[ $(chime_state) == unmuted ]] && { say "EFI startup chime un-muted (you will hear it at every boot; the amp needs it)"; return 0; }
  fi
  warn "could not change the chime variable. Un-mute it in macOS (System Settings > Sound > Play sound on startup)"
  warn "or reset NVRAM (hold Cmd+Option+P+R at power-on for ~20 s; this also clears boot entries)."
  return 1
}

# ----------------------------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------------------------
preflight() {
  local model v sv d sb dk
  model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if [[ $model != "MacBook8,1" ]]; then
    (( FORCE_MODEL )) || die "this machine reports '${model:-unknown}'. This installer is only for the MacBook8,1 (12-inch, Early 2015). MacBook9,1/10,1 need leifliddy/macbook12-audio-driver instead."
    warn "model is '$model' — continuing because of --force-model"
  fi
  [[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode. The fix depends on the codec state EFI leaves behind."
  command -v apt-get >/dev/null && command -v update-initramfs >/dev/null \
    || die "needs a Debian/Ubuntu/Mint system (apt-get + update-initramfs)."

  [[ -d /sys/bus/pci/devices/$HDA_PCI ]] || die "HD-audio controller not found at $HDA_PCI (the upstream scripts hard-code it)."
  v=$(<"/sys/bus/pci/devices/$HDA_PCI/vendor"):$(<"/sys/bus/pci/devices/$HDA_PCI/device")
  sv=$(<"/sys/bus/pci/devices/$HDA_PCI/subsystem_vendor"):$(<"/sys/bus/pci/devices/$HDA_PCI/subsystem_device")
  if [[ $v != 0x8086:0x9ca0 || $sv != 0x8086:0x7270 ]]; then
    (( FORCE_MODEL )) || die "HDA controller is $v (subsystem $sv); the patch only matches 0x8086:0x9ca0 / 0x8086:0x7270."
    warn "unexpected HDA controller $v ($sv) — continuing because of --force-model"
  fi

  dk=$(dkms status 2>/dev/null || true)
  if grep -q "^$DKMS_NAME" <<<"$dk" || [[ -e $DKMS_SRC_LINK ]]; then
    if [[ $(readlink -f "$DKMS_SRC_LINK" 2>/dev/null || true) != "$SRC" ]]; then
      die "another DKMS package named '$DKMS_NAME' is installed (probably leifliddy's 9,1/10,1 driver, which does not work on the 8,1). Remove it first:  sudo dkms remove $DKMS_NAME/$DKMS_VER --all && sudo rm -rf $DKMS_SRC_LINK"
    fi
  fi

  kernel_ge 6 17 || warn "kernel $(uname -r) is older than 6.17. Upstream only validated 6.17 and 7.2.x; the older-kernel build path is untested on this model. Updating the kernel first is recommended."
  if command -v mokutil >/dev/null; then
    sb=$(mokutil --sb-state 2>/dev/null || true)
    grep -qi 'enabled' <<<"$sb" && warn "Secure Boot is enabled; unsigned DKMS modules may be refused."
  fi

  d=$(df --output=avail -B1 /opt | tail -1 | tr -d ' ')
  (( d > 1000000000 )) || die "need ~1 GB free in /opt (kernel source tarball + build)."
}

check_network() {
  git ls-remote --heads "$PIN_REPO" >/dev/null 2>&1 || [[ -n $SRC_OVERRIDE ]] || die "cannot reach $PIN_REPO"
  wget -q --spider --timeout=15 "https://cdn.kernel.org/pub/linux/kernel/v$(uname -r | cut -d. -f1).x/" \
    || warn "cannot reach cdn.kernel.org; the DKMS build downloads the matching kernel source (Ubuntu's linux-source package is the fallback)."
}

check_audio_server() {
  local out; [[ -n $REAL_USER ]] || return 0
  out=$(as_user pactl info 2>/dev/null | awk -F': ' '/Server Name/ {print $2}' || true)
  case $out in
    *PipeWire*) say "audio server: $out" ;;
    "")         warn "could not query the audio server (no active desktop session?); assuming PipeWire." ;;
    *)          die "the active audio server is '$out', not PipeWire. Switch Mint to PipeWire first (apt install pipewire-pulse wireplumber; disable pulseaudio), then re-run." ;;
  esac
}

# ----------------------------------------------------------------------------------------------
# Install steps
# ----------------------------------------------------------------------------------------------
headers_meta() {   # e.g. linux-headers-generic-hwe-24.04, so new kernels always arrive with headers
  local img
  img=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null \
        | awk '$1=="ii" && $2 ~ /^linux-image-(generic|lowlatency)(-hwe-[0-9.]+)?$/ {print $2}' || true)
  img=${img%%$'\n'*}
  [[ -n $img ]] && echo "${img/linux-image-/linux-headers-}" || true
}

install_packages() {
  pb_step "installing build dependencies and kernel headers"
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(dkms build-essential git wget ca-certificates python3 kmod alsa-utils alsa-tools
              pipewire pipewire-bin pipewire-pulse pulseaudio-utils wireplumber "linux-headers-$(uname -r)")
  local meta; meta=$(headers_meta)
  [[ -n $meta ]] && pkgs+=("$meta")
  run_with_progress "apt: packages" bash -c 'apt-get update -qq && apt-get install -y --no-install-recommends "$@"' _ "${pkgs[@]}"
}

fetch_source() {
  pb_step "fetching upstream source (pinned to ${PIN_COMMIT:0:12})"
  local tmp; mkdir -p "$BASE"; tmp=$(mktemp -d "$BASE/.fetch.XXXXXX"); FETCH_TMP=$tmp
  local repo
  if [[ -n $SRC_OVERRIDE ]]; then
    repo=$SRC_OVERRIDE
    [[ $(git -C "$repo" rev-parse HEAD 2>/dev/null) == "$PIN_COMMIT" ]] || die "--src checkout is not at $PIN_COMMIT"
    [[ -z $(git -C "$repo" status --porcelain) ]] || die "--src checkout has local modifications"
  else
    repo=$tmp/repo
    git clone --quiet --no-checkout "$PIN_REPO" "$repo"
    git -C "$repo" cat-file -e "$PIN_COMMIT^{commit}" 2>/dev/null || die "pinned commit $PIN_COMMIT is gone from $PIN_REPO (history rewritten or repo removed). Refusing to build unreviewed code."
    git -C "$repo" -c advice.detachedHead=false checkout -q "$PIN_COMMIT"
    [[ $(git -C "$repo" rev-parse HEAD) == "$PIN_COMMIT" ]] || die "commit verification failed"
  fi
  mkdir "$tmp/tree"
  git -C "$repo" archive "$PIN_COMMIT" | tar -x -C "$tmp/tree"

  # One local tweak: also set the modern target.object next to the deprecated node.target in the EQ chain.
  if grep -q 'node.target  *= "MacBook_Speaker_Raw"' "$tmp/tree/51-macbook81-speaker.conf"; then
    sed -i 's|^\( *\)node.target\( *\)= "MacBook_Speaker_Raw"|&\n\1target.object\2= "MacBook_Speaker_Raw"|' \
      "$tmp/tree/51-macbook81-speaker.conf"
  else
    warn "EQ config layout changed; leaving node.target as shipped"
  fi

  rm -rf "$SRC.old"; [[ -d $SRC ]] && mv "$SRC" "$SRC.old"
  mv "$tmp/tree" "$SRC"
  echo "$PIN_COMMIT" > "$BASE/COMMIT"
  rm -rf "$SRC.old"
}

kernel_layout_check() {
  # The patches assume the HD-audio tree layout of the kernel being built. Fail early with a clear
  # message instead of a cryptic compile error if the headers do not match the expected layout.
  local kd="/lib/modules/$1/build" maj min
  maj=${1%%.*}; min=${1#*.}; min=${min%%[!0-9]*}
  if [[ ! -e $kd/include/sound/hda_codec.h ]]; then
    die "kernel $1 headers are missing sound/hda_codec.h; install linux-headers-$1 (or the -generic meta-package) and retry."
  fi
  if (( maj > 6 || (maj == 6 && min >= 17) )); then
    [[ -e $kd/include/sound/hda_codec.h ]] || die "unexpected HD-audio layout for $1"
  fi
  say "kernel $1 headers OK (layout: $( (( maj > 6 || (maj == 6 && min >= 17) )) && echo 'sound/hda/codecs (6.17+)' || echo 'sound/pci/hda (<=6.16)'))"
}

build_dkms() {
  kernel_layout_check "$(uname -r)"
  pb_step "building patched drivers with DKMS (downloads kernel source, several minutes)"
  run_with_progress "dkms: build snd-hda-intel / cs420x / generic" bash -c 'cd "$1" && MB81_SKIP_INITRAMFS=1 bash ./dkms.sh' _ "$SRC"
  depmod -a
}

install_runtime() {
  pb_step "installing modprobe options, PipeWire/WirePlumber config and services"
  say "modprobe options (single_cmd=1 power_save=0, cs420x loaded first)"
  install -m0644 "$SRC/mb81-singlecmd.conf" /etc/modprobe.d/mb81-singlecmd.conf

  say "installing PipeWire EQ sink"
  install -d /etc/pipewire/pipewire.conf.d
  install -m0644 "$SRC/51-macbook81-speaker.conf" /etc/pipewire/pipewire.conf.d/51-macbook81-speaker.conf

  if wp_is_modern; then
    say "WirePlumber $(wp_version): installing wireplumber.conf.d raw-PCM speaker node"
    install -d /etc/wireplumber/wireplumber.conf.d
    install -m0644 "$SRC/51-mb81-rawpcm-speaker.conf" /etc/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf
  else
    say "WirePlumber $(wp_version): installing Lua rules (the upstream .conf format is ignored by 0.4)"
    install -d /etc/wireplumber/main.lua.d
    write_wp04_lua /etc/wireplumber/main.lua.d/51-mb81-rawpcm-speaker.lua
  fi

  # Stale per-user copies from the upstream installer would shadow the system files.
  if [[ -n $REAL_USER ]]; then
    local h f; h=$(getent passwd "$REAL_USER" | cut -d: -f6)
    for f in "$h/.config/pipewire/pipewire.conf.d/51-macbook81-speaker.conf" \
             "$h/.config/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf" \
             "$h/.config/wireplumber/wireplumber.conf.d/51-mb81-disable-iec958.conf"; do
      [[ -e $f ]] && { mkdir -p /var/backups/mb81-audio; mv -f "$f" "/var/backups/mb81-audio/$(basename "$f").$(date +%s)"; say "moved stale user config $f to /var/backups/mb81-audio"; }
    done
  fi

  say "installing headphone-jack auto-switch (user service, enabled for all users)"
  install -m0755 "$SRC/mb81-jack-switch.sh" /usr/local/bin/mb81-jack-switch
  install -m0644 "$SRC/mb81-jack-switch.service" /etc/systemd/user/mb81-jack-switch.service
  systemctl --global enable mb81-jack-switch.service >/dev/null 2>&1 || warn "could not enable mb81-jack-switch.service globally"

  say "installing suspend/resume recovery"
  install -m0755 "$SRC/resume_recover.sh" /usr/local/bin/mb81-resume-recover
  install -m0755 "$SRC/efi_recover.py"   /usr/local/bin/efi_recover.py
  install -m0644 "$SRC/mb81-resume-recover.service" /etc/systemd/system/mb81-resume-recover.service
  systemctl daemon-reload
  systemctl enable mb81-resume-recover.service >/dev/null 2>&1 || warn "could not enable mb81-resume-recover.service"

  # Manual install.*.driver.sh runs drop modules in updates/ that would shadow the DKMS ones.
  rm -f /lib/modules/*/updates/snd-hda-codec-cs420x.ko* /lib/modules/*/updates/snd-hda-codec-generic.ko* \
        /lib/modules/*/updates/snd-hda-intel.ko* 2>/dev/null || true
}

# WirePlumber 0.4.x equivalent of upstream's 51-mb81-rawpcm-speaker.conf. Node names in 0.4.17's raw-PCM mode are
# alsa_output.<card>.playback.<pcm-device>.<subdevice> (see src/scripts/monitors/alsa.lua), so device 2 = TDM speaker.
write_wp04_lua() {
  cat > "$1" <<'LUA'
-- MacBook8,1 (CS4208) raw-PCM speaker node for WirePlumber 0.4.x. Generated by mb81-audio.sh.
-- Raw-PCM mode: ACP/UCM does not know the custom 4-channel TDM speaker PCM (device 2).
table.insert(alsa_monitor.rules, {
  matches = { { { "device.name", "equals", "alsa_card.pci-0000_00_1b.0" } } },
  apply_properties = { ["api.alsa.use-acp"] = false },
})

-- device 1 = SPDIF/Digital: shares converter 0x0a with the speaker and clobbers its stream tag; no jack exists.
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.1.0" } } },
  apply_properties = { ["node.disabled"] = true },
})

-- device 2 = TDM speaker: the sink the EQ filter-chain (MacBook_Speaker_DSP_Out) targets.
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.2.0" } } },
  apply_properties = {
    ["node.name"]                       = "MacBook_Speaker_Raw",
    ["node.description"]                = "MacBook Speaker (Raw)",
    ["audio.format"]                    = "S16LE",
    ["audio.rate"]                      = 44100,
    ["audio.channels"]                  = 4,
    ["audio.position"]                  = "FL,FR,RL,RR",
    ["api.alsa.period-size"]            = 1024,
    ["api.alsa.headroom"]               = 1024,
    ["node.pause-on-idle"]              = false,
    ["session.suspend-timeout-seconds"] = 0,
  },
})
LUA
}

refresh_initramfs() {
  pb_step "refreshing initramfs (patched modules and the softdep load from it at boot)"
  run_with_progress "update-initramfs -k all" update-initramfs -u -k all
}

do_install() {
  exec > >(tee -a "$LOG") 2>&1
  say "mb81-audio install — $(date -Is), kernel $(uname -r)"
  detect_user
  pb_step "preflight checks"
  preflight
  check_network
  check_audio_server
  pb_done "preflight ok"
  install_packages
  fetch_source
  build_dkms
  install_runtime
  refresh_initramfs

  case $(chime_state) in
    muted)
      warn "the EFI startup chime is MUTED. Without it the firmware never powers the speaker amp."
      if confirm "Un-mute the chime in NVRAM now?"; then fix_chime || true
      else warn "skipped. Run later:  sudo $0 --fix-chime" ; fi ;;
    unmuted) say "EFI startup chime is enabled" ;;
    *)       warn "could not read the chime setting; if speakers stay silent, run: sudo $0 --fix-chime" ;;
  esac

  pb_step "finished"; pb_done "install complete"
  cat <<EOF

================================================================
Installed (upstream commit ${PIN_COMMIT:0:12}). Reboot once to activate:  sudo reboot
After the reboot:                              sudo $0 --verify
Remove everything:                             sudo $0 --uninstall
Log: $LOG
================================================================
EOF
}

do_rebuild() {
  exec > >(tee -a "$LOG") 2>&1
  [[ -d $SRC ]] || die "not installed; run the installer first."
  local k n=0
  for k in /lib/modules/*/; do
    k=$(basename "$k")
    [[ -e /lib/modules/$k/build/include ]] || { warn "no headers for $k, skipping"; continue; }
    say "dkms install for $k"
    if dkms install -m "$DKMS_NAME" -v "$DKMS_VER" -k "$k" --force; then n=$((n+1)); else warn "build failed for $k"; fi
  done
  depmod -a; refresh_initramfs
  say "rebuilt for $n kernel(s)"
}

do_uninstall() {
  exec > >(tee -a "$LOG") 2>&1
  detect_user
  say "mb81-audio uninstall — $(date -Is)"
  systemctl disable --now mb81-resume-recover.service 2>/dev/null || true
  rm -f /etc/systemd/system/mb81-resume-recover.service /usr/local/bin/mb81-resume-recover /usr/local/bin/efi_recover.py
  systemctl daemon-reload 2>/dev/null || true
  systemctl --global disable mb81-jack-switch.service 2>/dev/null || true
  as_user systemctl --user stop mb81-jack-switch.service 2>/dev/null || true
  rm -f /etc/systemd/user/mb81-jack-switch.service /usr/local/bin/mb81-jack-switch

  # dkms.sh -r runs `dkms remove` BEFORE deleting anything, which puts the stock in-tree modules back.
  if [[ -f $SRC/dkms.sh ]]; then ( cd "$SRC" && MB81_SKIP_INITRAMFS=1 bash ./dkms.sh -r ) || warn "upstream dkms.sh -r reported problems"
  else
    dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all 2>/dev/null || true
    rm -rf "/var/lib/dkms/$DKMS_NAME"; rm -f "$DKMS_SRC_LINK"
  fi
  rm -f /lib/modules/*/updates/dkms/snd-hda-codec-cs420x.ko* /lib/modules/*/updates/dkms/snd-hda-codec-generic.ko* \
        /lib/modules/*/updates/dkms/snd-hda-intel.ko* 2>/dev/null || true

  rm -f /etc/modprobe.d/mb81-singlecmd.conf /etc/pipewire/pipewire.conf.d/51-macbook81-speaker.conf \
        /etc/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf /etc/wireplumber/main.lua.d/51-mb81-rawpcm-speaker.lua
  rm -rf "$BASE"
  depmod -a
  refresh_initramfs
  say "removed. Reboot to return to the stock in-tree drivers. (An un-muted EFI chime setting is left as is.)"
}

# ----------------------------------------------------------------------------------------------
# Verify
# ----------------------------------------------------------------------------------------------
PASS=0 FAILN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILN=$((FAILN+1)); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; }

do_verify() {
  detect_user
  local k m p card codecf dev coef jack stream sink want dk logs
  k=$(uname -r)
  echo "mb81-audio verify — kernel $k, user ${REAL_USER:-?}"

  echo "[driver]"
  [[ $(cat /sys/class/dmi/id/product_name 2>/dev/null) == MacBook8,1 ]] && ok "model is MacBook8,1" || bad "model is not MacBook8,1"
  dk=$(dkms status -m "$DKMS_NAME" -v "$DKMS_VER" -k "$k" 2>/dev/null || true)
  grep -q ': installed' <<<"$dk" \
    && ok "DKMS package installed for $k" || bad "DKMS package NOT installed for $k  (try: sudo $0 --rebuild, then reboot)"
  for m in snd-hda-intel snd-hda-codec-cs420x snd-hda-codec-generic; do
    p=$(modinfo -n "$m" 2>/dev/null || true)
    if [[ $p == */updates/* || $p == */extra/* ]]; then ok "$m resolves to the patched module ($p)"
    else bad "$m resolves to '${p:-nothing}' (stock driver) — initramfs stale? run --rebuild and reboot"; fi
  done
  [[ $(cat /sys/module/snd_hda_intel/parameters/single_cmd 2>/dev/null) == Y ]] && ok "snd_hda_intel single_cmd=Y" || bad "single_cmd is not enabled"
  [[ $(cat /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null) == 0 ]] && ok "snd_hda_intel power_save=0" || bad "power_save is not 0"
  logs=$({ dmesg 2>/dev/null; journalctl -k -b 0 --no-pager 2>/dev/null; } || true)
  grep -q 'attaching to running EFI link without reset' <<<"$logs" \
    && ok "no-reset EFI attach happened this boot" || bad "no-reset attach message missing (patched snd-hda-intel not in use?)"

  codecf=$(grep -l 'Cirrus Logic CS4208' /proc/asound/card*/codec#0 2>/dev/null | head -1 || true)
  if [[ -n $codecf ]]; then
    card=$(grep -oP 'card\K[0-9]+' <<<"$codecf"); ok "CS4208 bound by its own driver on card $card"
  else
    grep -q 'Cirrus Logic Generic' /proc/asound/card*/codec#0 2>/dev/null && bad "codec was grabbed by the generic parser (cs420x lost the race)" || bad "CS4208 codec not found"
    card=""
  fi
  if [[ -n $card ]] && command -v hda-verb >/dev/null && [[ -e /dev/snd/hwC${card}D0 ]]; then
    dev=/dev/snd/hwC${card}D0
    hda-verb "$dev" 0x24 0x500 0x1f >/dev/null 2>&1 || true
    coef=$(hda-verb "$dev" 0x24 0xC00 0 2>&1 | grep -oP 'value = \K0x[0-9a-f]+' || true)
    [[ $coef == 0x0 || $coef == 0x0000 ]] && ok "codec clock locked (coef 0x1f = $coef)" \
      || bad "codec clock fault latched (coef 0x1f = ${coef:-unreadable}); a plain reboot clears it"
  else
    note "skipped clock-latch check (hda-verb or hwdep node missing)"
  fi
  case $(chime_state) in
    unmuted) ok "EFI startup chime enabled" ;;
    muted)   bad "EFI startup chime is muted — the amp is never powered. Run: sudo $0 --fix-chime && reboot" ;;
    *)       note "EFI chime state unknown" ;;
  esac

  echo "[services]"
  systemctl is-enabled --quiet mb81-resume-recover.service && ok "resume recovery service enabled" || bad "resume recovery service not enabled"
  if [[ -n $REAL_USER ]]; then
    as_user systemctl --user is-active --quiet mb81-jack-switch.service \
      && ok "jack-switch service running for $REAL_USER" || bad "jack-switch service not running for $REAL_USER (log out/in once, or reboot)"
  fi

  echo "[PipeWire / WirePlumber $(wp_version)]"
  if [[ -n $REAL_USER ]] && as_user pw-cli info 0 >/dev/null 2>&1; then
    local nodes; nodes=$(as_user pw-cli ls Node 2>/dev/null || true)
    grep -q 'node.name = "MacBook_Speaker_Raw"' <<<"$nodes" && ok "raw speaker node MacBook_Speaker_Raw exists" \
      || bad "raw speaker node missing (WirePlumber rule not applied; check: pw-cli ls Node | grep node.name)"
    grep -q 'node.name = "input.MacBook_Speaker"' <<<"$nodes" && ok "EQ sink input.MacBook_Speaker exists" || bad "EQ sink input.MacBook_Speaker missing"
    jack=""
    [[ -n $card ]] && jack=$(amixer -c "$card" cget name='Headphone Jack' 2>/dev/null | sed -n 's/.*: values=\(on\|off\).*/\1/p' | head -1 || true)
    want=input.MacBook_Speaker; [[ $jack == on ]] && want=alsa_output.pci-0000_00_1b.0.playback.0.0
    sink=$(as_user pactl get-default-sink 2>/dev/null || true)
    [[ $sink == "$want" ]] && ok "default sink is $sink (headphone jack: ${jack:-unknown})" || bad "default sink is '${sink:-none}', expected $want"
  else
    bad "no PipeWire session reachable for ${REAL_USER:-?}; log in on the desktop and re-run"
  fi

  echo "[audio]"
  if [[ -n $REAL_USER && -n $card ]] && command -v pw-play >/dev/null; then
    local wav=/tmp/mb81-tone.wav; python3 - "$wav" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<hh', *(int(9000*math.sin(2*math.pi*440*i/44100)),)*2) for i in range(44100*3)))
w.close()
PY
    chmod 644 "$wav"
    as_user pw-play "$wav" >/dev/null 2>&1 & local pid=$!
    sleep 1.5
    stream=$(awk '/^Node 0x0a /{f=1} f&&/Converter: stream=/{print $2; exit}' "/proc/asound/card$card/codec#0" 2>/dev/null | tr -dc '0-9' || true)
    [[ -n $stream && $stream != 0 ]] && ok "speaker converter 0x0a is streaming (stream tag $stream)" || bad "converter 0x0a idle while a tone plays — audio is not reaching the speaker path"
    wait "$pid" 2>/dev/null || true; rm -f "$wav"
    if [[ -t 0 ]]; then
      local a; read -r -p "  Did you hear a 440 Hz tone from the speakers? [y/N] " a
      [[ $a =~ ^[Yy] ]] && ok "tone audible (confirmed by you)" || bad "tone not heard"
    else
      note "non-interactive: audibility not confirmed"
    fi
  else
    note "skipped tone test (needs a PipeWire session and the CS4208 card)"
  fi

  echo; echo "result: $PASS passed, $FAILN failed"
  (( FAILN == 0 ))
}

main() {
  (( EUID == 0 )) || exec sudo -E bash "$0" "$@"
  case $ACTION in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    verify)    do_verify ;;
    rebuild)   do_rebuild ;;
    chime)     [[ $(chime_state) == muted ]] && fix_chime || say "chime state: $(chime_state)" ;;
  esac
}

[[ ${MB81_SOURCE_ONLY:-0} == 1 ]] || main "$@"
