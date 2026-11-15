Here is the complete, unified `.sh` file. I have integrated the fixes for user detection, the `as_user` environment injection, the `fix_chime` Python logic, and the `verify` stage to ensure it handles SSH/non-GUI sessions gracefully.

```bash
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
#   B  modprobe options       single_cmd=1 power_save=0 + softdep
#   C  snd-hda-codec-cs420x   patched Cirrus CS4208 driver
#   D  snd-hda-codec-generic patched: skips the input bring-up that latches the codec clock fault
#   -  PipeWire EQ sink + WirePlumber raw-PCM speaker node
#   -  headphone-jack auto-switch (systemd user service)
#   -  suspend/resume recovery (systemd system service)
#
# Source: omnidecker/macbook8.1-speaker-driver (pinned to verified commit)
set -Eeuo pipefail

PIN_REPO="https://github.com/omnidecker/macbook8.1-speaker-driver.git"
PIN_COMMIT="e4134fb272ba3be29aa71ad7aa6eae8b0ebddf1a"

BASE=/opt/mb81-audio
SRC=$BASE/src
LOG=/var/log/mb81-audio.log
DKMS_NAME=macbook12-audio
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
STEP_TOTAL=8 STEP_NOW=0 PB_TTY=0
[[ -t 1 ]] && PB_TTY=1
pb_draw() {
  local n=$1 label=$2 sub=${3:-0} pct
  (( PB_TTY )) || { printf '[%d/%d] %s\n' "$n" "$STEP_TOTAL" "$label"; return; }
  pct=$(( ( (n-1)*100 + sub ) / STEP_TOTAL ))
  printf '\r\033[K%s %3d%%  %d/%d  %s' "$(pb_bar "$pct")" "$pct" "$n" "$STEP_TOTAL" "$label"
}
pb_step() {
  STEP_NOW=$(( STEP_NOW + 1 )); pb_draw "$STEP_NOW" "$1" 0
}
pb_done() {
  local label=${1:-done} pct
  pct=$(( STEP_NOW * 100 / STEP_TOTAL ))
  (( STEP_NOW < STEP_TOTAL )) || pct=100
  if (( PB_TTY )); then
    printf '\r\033[K%s %3d%%  %d/%d  %s\n' "$(pb_bar "$pct")" "$pct" "$STEP_NOW" "$STEP_TOTAL" "$label"
  else
    printf '    %s\n' "$label"
  fi
}
pb_bar() {
  local pct=$1 width=28 filled empty bar="" dots=""
  filled=$(( pct * width / 100 )); empty=$(( width - filled ))
  printf -v bar '%*s' "$filled" ''; bar=${bar// /#}
  printf -v dots '%*s' "$empty" ''; dots=${dots// /.}
  printf '[%s%s]' "$bar" "$dots"
}
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
  --force-model      skip the MacBook8,1 / PCI-ID safety checks
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
  if [[ -z "$REAL_USER" || "$REAL nas_user" == "root" ]]; then
    REAL_USER=$(logname 2>/dev/null || true)
  fi
  if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
  fi
}

as_user() {
  [[ -z "$REAL_USER" ]] && return 1
  local uid
  uid=$(id -u "$REAL_USER")
  runuser -u "$REAL_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 1
  local a; read -r -p "$1 [Y/n] " a; [[ -z $a || $a =~ ^[Yy] ]]
}

kernel_ge() {
  local k=${1:?} m=${2:?} cur_maj cur_min v; v=$(uname -r)
  cur_maj=${v%%.*}; curmin=${v#*.}; curmin=${curmin%%[!0-9]*}
  (( cur_maj > k || (cur_maj == k && curmin >= m) ))
}

wp_version() { wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; }
wp_is_modern() {
  local v maj min; v=$(wp_version); [[ -n $v ]] || return 1
  maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  (( maj > 0 || min >= 5 ))
}

chime_state() {
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
    f=$EFIVARS/Systemvolume-$APPLE_GUID
    b=$(tail -c1 "$f" | od -An -tu1 | tr -d ' ')
    new=$(( b & 0x7f ))
  elif [[ -r $EFIVARS/StartupMute-$APPLE_GUID ]]; then
    f=$EFIVARS/StartupMute-$APPLE_GUID; new=0
  else
    warn "no chime NVRAM variable found"; return 0
  fi
  chattr -i "$f" 2>/dev/null || true
  if python3 - "$f" "$new" <<'PY'
import os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY)
    os.write(fd, bytes([0x07, 0x00, 0x00, 0x00, int(sys.argv[2])]))
    os.close(fd)
    sys.exit(0)
except:
    sys.exit(1)
PY
  then
    say "EFI startup chime un-muted"
    return 0
  fi
  warn "could not change the chime variable via python script."
  return 1
}

preflight() {
  local model v sv d sb dk
  model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if [[ $model != "MacBook8,1" ]]; then
    (( FORCE_MODEL )) || die "This is for MacBook8,1 only."
    warn "model is '$model' — continuing because of --force-model"
  fi
  [[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode."
  command -v apt-get >/dev/null && command -v update-initramfs >/dev/null || die "needs Debian/Ubuntu/Mint."
  [[ -d /sys/bus/pci/devices/$HDA_PCI ]] || die "HDA controller not found at $HDA_PCI."
  
  dk=$(dkms status 2>/dev/null || true)
  if grep -q "^$DKMS_NAME" <<<"$dk"; then
    die "DKMS package $DKMS_NAME is already installed. Remove it first."
  fi

  kernel_ge 6 17 || warn "Kernel is older than 6.17; build path is untested."
  d=$(df --output=avail -B1 /opt | tail -1 | tr -d ' ')
  (( d > 1000000000 )) || die "need ~1 GB free in /opt."
}

check_network() {
  git ls-remote --heads "$PIN_REPO" >/dev/null 2>&1 || [[ -n $SRC_OVERRIDE ]] || die "cannot reach $PIN_REPO"
}

check_audio_server() {
  local out; [[ -n $REAL_USER ]] || return 0
  out=$(as_user pactl info 2>/dev/null | awk -F': ' '/Server Name/ {print $2}' || true)
  case $out in
    *PipeWire*) say "audio server: $out" ;;
    "")         warn "no active desktop session; assuming PipeWire." ;;
    *)          die "Active audio server is '$out', not PipeWire. Switch to PipeWire first." ;;
  esac
}

# ----------------------------------------------------------------------------------------------
# Install steps
# ----------------------------------------------------------------------------------------------
headers_meta() {
  local img
  img=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null \
        | awk '$1=="ii" && $2 ~ /^linux-image-(generic|lowlatency)(-hwe-[0-9.]+)?$/ {print $2}' || true)
  img=${img%%$'\n'*}
  [[ -n $img ]] && echo "${img/linux-image-/linux-headers-}" || true
}

install_packages() {
  pb_step "installing build dependencies"
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(dkms build-essential git wget ca-certificates python3 kmod alsa-utils alsa-tools
              pipewire pipewire-bin pipewire-pulse pulseaudio-utils wireplumber "linux-headers-$(uname -r)")
  local meta; meta=$(headers_meta)
  [[ -n $meta ]] && pkgs+=("$meta")
  run_with_progress "apt: packages" bash -c 'apt-get update -qq && apt-get install -y --no-install-recommends "$@"' _ "${pkgs[@]}"
}

fetch_source() {
  pb_step "fetching upstream source"
  local tmp; mkdir -p "$BASE"; tmp=$(mktemp -d "$BASE/.fetch.XXXXXX"); FETCH_TMP=$tmp
  local repo
  if [[ -n $SRC_OVERRIDE ]]; then
    repo=$SRC_OVERRIDE
  else
    repo=$tmp/repo
    git clone --quiet --no-checkout "$PIN_REPO" "$repo"
    git -C "$repo" cat-file -e "$PIN_COMMIT^{commit}" 2>/dev/null || die "pinned commit is gone."
    git -C "$repo" -c advice.detachedHead=false checkout -q "$PIN_COMMIT"
  fi
  mkdir "$tmp/tree"
  git -C "$repo" archive "$PIN_COMMIT" | tar -x -C "$tmp/tree"
  
  # Apply local tweak for modern targets
  if grep -q 'node.target  *= "MacBook_Speaker_Raw"' "$tmp/tree/51-macbook81-speaker.conf"; then
    sed -i 's|^\( *\)node.target\( *\)= "MacBook_Speaker_Raw"|&\n\1target.object\2= "MacBook_Speaker_Raw"|' \
      "$tmp/tree/51-macbook81-speaker.conf"
  fi

  rm -rf "$SRC.old"; [[ -d $SRC ]] && mv "$SRC" "$SRC.old"
  mv "$tmp/tree" "$SRC"
  echo "$PIN_COMMIT" > "$BASE/COMMIT"
}

kernel_layout_check() {
  local kd="/lib/modules/$1/build" maj min
  maj=${1%%.*}; min=${1#*.}; min=${min%%[!0-9]*}
  if [[ ! -e $kd/include/sound/hda_codec.h ]]; then
    die "kernel $1 headers are missing sound/hda_codec.h; install linux-headers-$1."
  fi
}

build_dkms() {
  kernel_layout_check "$(uname -r)"
  pb_step "building patched drivers with DKMS"
  run_with_progress "dkms: build" bash -c 'cd "$1" && MB81_SKIP_INITRAMFS=1 bash ./dkms.sh' _ "$SRC"
  depmod -a
}

install_runtime() {
  pb_step "installing configuration files"
  install -m0644 "$SRC/mb81-singlecmd.conf" /etc/modprobe.d/mb81-singlecmd.conf
  install -m0644 "$SRC/51-macbook81-speaker.conf" /etc/pipewire/pipewire.conf.d/51-macbook81-speaker.conf
  install -d /etc/pipewire/pipewire.conf.d
  
  if wp_is_modern; then
    install -d /etc/wireplumber/wireplumber.conf.d
    install -m0644 "$SRC/51-mb81-rawpcm-speaker.conf" /etc/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf
  else
    install -d /etc/wireplumber/main.lua.d
    # We'll write the Lua file in the next step
    cat > /etc/wireplumber/main.lua.d/51-mb81-rawpcm-speaker.lua <<'LUA'
table.insert(alsa_monitor.rules, {
  matches = { { { "device.name", "equals", "alsa_card.pci-0000_00_1b.0" } } },
  apply_properties = { ["api.alsa.use-acp"] = false },
})
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.1.0" } } },
  apply_properties = { ["node.disabled"] = true },
})
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.2.0" } } },
  apply_properties = {
    ["node.name"] = "MacBook_Speaker_Raw",
    ["node.description"] = "MacBook Speaker (Raw)",
    ["audio.format"] = "S16LE",
    ["audio.rate"] = 44100,
    ["audio.channels"] = 4,
    ["audio.position"] = "FL,FR,RL,RR",
    ["api.alsa.period-size"] = 1024,
    ["api.alsa.headroom"] = 1024,
    ["node.pause-on-idle"] = false,
    ["session.suspend-timeout-seconds"] = 0,
  },
})
LUA
  # Note: The Lua file is written via the logic below to ensure it's clean.
  # We'll use the logic from the original script's write_wp04_lua function.
fi

# Re-defining the write function to be used during install
write_wp04_lua() {
  cat > "$1" <<'LUA'
table.insert(alsa_monitor.rules, {
  matches = { { { "device.name", "equals", "alsa_card.pci-0000_00_1b.0" } } },
  apply_properties = { ["api.alsa.use-acp"] = false },
})
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.1.0" } } },
  apply_properties = { ["node.disabled"] = true },
})
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.2.0" } } },
  apply_properties = {
    ["node.name"] = "MacBook_Speaker_Raw",
    ["node.description"] = "MacBook Speaker (Raw)",
    ["audio.format"] = "S16LE",
    ["audio.rate"] = 44100,
    ["audio.channels"] = 4,
    ["audio.position"] = "FL,FR,RL,RR",
    ["api.alsa.period-size"] = 1024,
    ["api.alsa.headroom"] = 1024,
    ["node.pause-on-idle"] = false,
    ["session.suspend-timeout-seconds"] = 0,
  },
})
LUA
}

install_runtime_final() {
  pb_step "finalizing runtime config"
  install -m0644 "$SRC/mb81-singlecmd.conf" /etc/modprobe.d/mb81-singlecmd.conf
  install -m0644 "$SRC/51-macbook81-speaker.conf" /etc/pipewire/pipewire.conf.d/51-macbook81-speaker.conf
  
  if wp_is_modern; then
    install -d /etc/wireplumber/wireplumber.conf.d
    install -m0644 "$SRC/51-mb81-rawpcm-speaker.conf" /etc/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf
  else
    install -d /etc/wireplumber/main.lua.d
    write_wp04_lua "/etc/wireplumber/main.lua.d/51-mb81-rawpcm-speaker.lua"
  fi

  install -m0755 "$SRC/mb81-jack-switch.sh" /usr/local/bin/mb81-jack-switch
  install -m0644 "$SRC/mb81-jack-switch.service" /etc/systemd/user/mb81-jack-switch.service
  systemctl --global enable mb81-jack-switch.service >/dev/null 2>&1 || true

  install -m0755 "$SRC/resume_recover.sh" /usr/local/bin/mb81-resume-recover
  install -m0755 "$SRC/efi_recover.py"   /usr/local/bin/efi_recover.py
  install -m0644 "$SRC/mb81-resume-recover.service" /etc/systemd/system/mb81-resume-recover.service
  systemctl daemon-reload
  systemctl enable mb81-resume-recover.service >/dev/null 2>&1 || true
}

refresh_initramfs() {
  pb_step "refreshing initramfs"
  run_with_progress "update-initramfs" update-initramfs -u -k all
}

do_install() {
  exec > >(tee -a "$LOG") 2>&1
  say "mb81-audio install — $(date -Is)"
  detect_user
  preflight
  check_network
  check_audio_server
  install_packages
  fetch_source
  build_dkms
  install_runtime_final
  refresh_initramfs

  case $(chime_state) in
    muted)
      if confirm "Un-mute the chime in NVRAM now?"; then fix_chime || true; fi ;;
    unmuted) say "EFI startup chime is enabled" ;;
  esac

  pb_step "finished"; pb_done "install complete"
  cat <<EOF
================================================================
Installed. Reboot once to activate:  sudo reboot
After the reboot:                              sudo $0 --verify
Remove everything:                             sudo $0 --uninstall
Log: $LOG
================================================================
EOF
}

do_rebuild() {
  exec > >(tee -a "$LOG") 2>&1
  [[ -d $SRC ]] || die "not installed."
  local k n=0
  for k in /lib/modules/*/; do
    k=$(basename "$k")
    [[ -e /lib/modules/$k/build/include ]] || continue
    say "dkms install for $k"
    dkms install -m "$DKMS_NAME" -v "$DKMS_VER" -k "$k" --force && n=$((n+1)) || warn "failed"
  done
  depmod -a; refresh_initramfs
  say "rebuilt for $n kernel(s)"
}

do_uninstall() {
  exec > >(tee -a "$LOG") 2>&1
  detect_user
  say "mb81-audio uninstall"
  systemctl disable --now mb81-resume-recover.service 2>/dev/null || true
  rm -f /etc/systemd/system/mb81-resume-recover.service /usr/local/bin/mb81-resume-recover /usr/local/bin/efi_recover.py
  systemctl daemon-reload 2>/dev/null || true
  systemctl --global disable mb81-jack-switch.service 2>/dev/null || true
  as_user systemctl --user stop mb81-jack-switch.service 2>/dev/null || true
  rm -f /usr/local/bin/mb81-jack-switch
  
  if [[ -f $SRC/dkms.sh ]]; then ( cd "$SRC" && MB81_SKIP_INITRAMFS=1 bash ./dkms.sh -r ) || true
  else
    dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all 2>/dev/null || true
    rm -rf "/var/lib/dkms/$DKMS_NAME" "$SRC"
  fi
  rm -f /etc/modprobe.d/mb81-singlecmd.conf /etc/pipewire/pipewire.conf.d/51-macbook81-speaker.conf \
        /etc/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf /etc/wireplumber/main.lua.d/51-mb81-rawpcm-speaker.lua
  depmod -a
  refresh_initramfs
  say "removed. Reboot to return to stock drivers."
}

do_verify() {
  detect_user
  local k m p card codecf dev coef jack stream sink want dk logs
  k=$(uname -r)
  echo "mb81-audio verify — kernel $k, user ${REAL_USER:-?}"

  echo "[driver]"
  [[ $(cat /sys/class/dmi/id/product_name 2>/dev/null) == MacBook8,1 ]] && ok "model is MacBook8,1" || bad "model is not MacBook8,1"
  dk=$(dkms status -m "$DKMS_NAME" -v "$DKMS_VER" -k "$k" 2>/dev/null || true)
  grep -q ': installed' <<<"$dk" && ok "DKMS installed" || bad "DKMS NOT installed"
  
  for m in snd-hda-intel snd-hda-codec-cs420x snd-hda-codec-generic; do
    p=$(modinfo -n "$m" 2>/dev/null || true)
    [[ $p == */updates/* || $p == */extra/* ]] && ok "$m is patched" || bad "$m is stock"
  done

  codecf=$(grep -l 'Cirrus Logic CS4208' /proc/asound/card*/codec#0 2>/dev/null | head -1 || true)
  if [[ -n $codecf ]]; then
    card=$(grep -oP 'card\K[0-9]+' <<<"$codecf"); ok "CS4208 bound"
  else
    bad "CS4208 not found"
  fi

  echo "[services]"
  systemctl is-enabled --quiet mb81-resume-recover.service && ok "recovery service enabled" || bad "recovery service disabled"
  
  if [[ -n $REAL_USER ]]; then
    echo "[user session: $REAL_USER]"
    if [[ -z $(as_user whoami 2>/dev/null) ]]; then
      note "No active user session detected (likely SSH). Cannot verify PipeWire."
    else
      nodes=$(as_user pw-cli ls Node 2>/dev/null || true)
      grep -q 'node.name = "MacBook_Speaker_Raw"' <<<"$nodes" && ok "Raw speaker node exists" || bad "Raw speaker node missing"
      grep -q 'node.name = "input.MacBook_Speaker"' <<<"$nodes" && ok "EQ sink exists" || bad "EQ sink missing"
    fi
  fi

  echo "[audio]"
  if [[ -n $REAL_USER && -n $card ]] && command -v pw-play >/dev/null; then
    local wav=/tmp/mb81-tone.wav; python3 - "$wav" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<hh', *(int(9000*math.sin(2*math.pi*440*i/44100),),)*2) for i in range(44100*3)))
w.close()
PY
    chmod 644 "$wav"
    as_user pw-play "$wav" >/dev/null 2>&1 & local pid=$!
    sleep 1.5
    stream=$(awk '/^Node 0x0a /{f=1} f&&/Converter: stream=/{print $2; exit}' "/proc/asound/card$card/codec#0" 2>/dev/null || true)
    [[ -n $stream && $stream != 0 ]] && ok "speaker streaming" || bad "speaker silent"
    wait "$pid" 2>/dev/null || true; rm -f "$wav"
  fi
  echo; echo "result: $PASS passed, $FAILN failed"
}

ok()   { printf '  \033[32mPASS\033m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033m  %s\n' "$*"; FAILN=$((FAILN+1)); }
note() { printf '  \033[33mNOTE\033m  %s\n' "$*"; }
PASS=0; FAILN=0

main() {
  (( EUID == 0 )) || exec sudo -E bash "$0" "$@"
  case $ACTION in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    verify)    do_verify ;;
    rebuild)   do_rebuild ;;
    chime)     [[ $(chime_state) == muted ]] && fix_chime || say "chime: $(chime_state)" ;;
  esac
}

[[ ${MB81_SOURCE_ONLY:-0} == 1 ]] || main "$@"
```
