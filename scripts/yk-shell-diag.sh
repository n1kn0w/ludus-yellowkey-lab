#!/bin/bash
set -euo pipefail
VMID="${VMID:-121}"
OUTDIR="/tmp/yk-rescan"
mkdir -p "${OUTDIR}"
rm -f "${OUTDIR}"/*.png

qmp() { socat - "UNIX-CONNECT:/var/run/qemu-server/${VMID}.qmp" <<E >/dev/null 2>&1
{"execute":"qmp_capabilities"}
$1
E
}
type_key() {
  qmp "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\"$1\"}}},{\"type\":\"key\",\"data\":{\"down\":false,\"key\":{\"type\":\"qcode\",\"data\":\"$1\"}}}]}}"; sleep 0.05
}
alt_code() {
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"alt"}}}]}}'; sleep 0.04
  for ((i=0; i<${#1}; i++)); do
    qmp "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\"kp_${1:$i:1}\"}}},{\"type\":\"key\",\"data\":{\"down\":false,\"key\":{\"type\":\"qcode\",\"data\":\"kp_${1:$i:1}\"}}}]}}"; sleep 0.04
  done
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"alt"}}}]}}'; sleep 0.08
}
type_str() {
  for ((i=0; i<${#1}; i++)); do
    local c="${1:$i:1}"
    case "$c" in [a-z0-9]) type_key "$c";; ' ') type_key spc;; ':') alt_code "0058";; '\') type_key backslash;; '.') type_key dot;; '-') type_key minus;; esac
  done
}
enter() {
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ret"}}},{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"ret"}}}]}}'; sleep 0.1
}
snap() {
  echo "screendump ${OUTDIR}/$1.ppm" | qm monitor "${VMID}" >/dev/null 2>&1
  pnmtopng "${OUTDIR}/$1.ppm" > "${OUTDIR}/$1.png" 2>/dev/null
  rm -f "${OUTDIR}/$1.ppm"; echo "[+] $1"
}

# clear with cls
type_str "cls"; enter; sleep 1
type_str "diskpart"; enter; sleep 4; snap "01_dp_open"
type_str "rescan"; enter; sleep 4; snap "02_rescan"
type_str "list disk"; enter; sleep 3; snap "03_listdisk"
type_str "select disk 0"; enter; sleep 1
type_str "list partition"; enter; sleep 3; snap "04_listpart"
type_str "list volume"; enter; sleep 3; snap "05_listvol"
