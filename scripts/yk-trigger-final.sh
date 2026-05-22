#!/bin/bash
# Clean navigation: boot to WinRE, go to Command Prompt with CTRL held
set -euo pipefail
VMID="${VMID:-121}"
OUTDIR="/tmp/yk-clean"
mkdir -p "${OUTDIR}"
rm -f "${OUTDIR}"/*.png "${OUTDIR}"/*.ppm

qmp() {
  socat - "UNIX-CONNECT:/var/run/qemu-server/${VMID}.qmp" <<E >/dev/null 2>&1 || true
{"execute":"qmp_capabilities"}
$1
E
}

key_press() {
  local k="$1"
  qmp "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\"$k\"}}},{\"type\":\"key\",\"data\":{\"down\":false,\"key\":{\"type\":\"qcode\",\"data\":\"$k\"}}}]}}"
}

ctrl_down() {
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ctrl_l"}}},{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ctrl_r"}}}]}}'
}
ctrl_up() {
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"ctrl_l"}}},{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"ctrl_r"}}}]}}'
}

snap() {
  local label="$1"
  local out="${OUTDIR}/${label}"
  echo "screendump ${out}.ppm" | qm monitor "${VMID}" >/dev/null 2>&1
  pnmtopng "${out}.ppm" > "${out}.png" 2>/dev/null
  rm -f "${out}.ppm"
  echo "[+] $(date +%H:%M:%S) ${label}"
}

# wait_for_screen returns when the screen hash stabilizes (no change for 3s).
wait_stable() {
  local name="$1"
  local max="${2:-60}"
  local prev=""
  local stable_count=0
  for ((i=0; i<max; i++)); do
    echo "screendump /tmp/_w.ppm" | qm monitor "${VMID}" >/dev/null 2>&1
    local cur
    cur=$(md5sum /tmp/_w.ppm 2>/dev/null | awk '{print $1}')
    if [[ "$cur" == "$prev" && -n "$cur" ]]; then
      stable_count=$((stable_count + 1))
      if (( stable_count >= 2 )); then return 0; fi
    else
      stable_count=0
    fi
    prev=$cur
    sleep 1.5
  done
}

echo "[*] $(date +%H:%M:%S) reagentc /boottore + shutdown /r"
qm guest exec "${VMID}" --timeout 15 -- reagentc.exe /boottore >/dev/null 2>&1 || true
qm guest exec "${VMID}" --timeout 15 -- shutdown.exe /r /t 0 /f >/dev/null 2>&1 || true

echo "[*] Wait for WinRE keyboard layout screen..."
sleep 25
wait_stable "kbd" 30
snap "01_keyboard_layout"

echo "[*] Enter -> US selected, advance to Choose an option"
key_press "ret"
sleep 2
wait_stable "choose" 15
snap "02_choose_option"

echo "[*] Enter -> Troubleshoot/Advanced options page"
key_press "ret"
sleep 2
wait_stable "advanced" 15
snap "03_advanced_options"

echo "[*] Down -> focus Command Prompt"
key_press "down"
sleep 1
snap "04_cmd_focused"

echo "[*] >>> HOLD CTRL DOWN (sustained) <<<"
ctrl_down
sleep 0.3
ctrl_down
sleep 0.3

echo "[*] Enter on Command Prompt (CTRL still held)"
key_press "ret"

# Maintain CTRL for 20s, snapshot every 4s
for i in 1 2 3 4 5; do
  ctrl_down
  sleep 4
  snap "05_after_$i"
done

ctrl_up
snap "06_released"
