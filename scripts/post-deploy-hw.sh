#!/usr/bin/env bash
#
# Ajoute le materiel manquant aux VMs YellowKey deployees par Ludus :
#  - vTPM 2.0 (tpmstate0)
#  - disque secondaire 2 Go (simule la cle USB qui portera FsTx)
#
# A executer depuis le Mac, apres `ludus range deploy` (les VMs doivent
# exister cote Proxmox). Le script SSH-e sur le serveur Proxmox.
#
# Usage :
#   ./post-deploy-hw.sh <range_id>
#
# Pre-requis : sshpass (brew install sshpass), variables ci-dessous.

set -euo pipefail

PVE_HOST="${PVE_HOST:?Define PVE_HOST (IP/host of your Proxmox node)}"
PVE_USER="${PVE_USER:-root}"
PVE_PASS="${PVE_PASS:?Define PVE_PASS env var with the Proxmox root password}"
PVE_STORAGE="${PVE_STORAGE:-local}"
USB_DISK_SIZE_GB="${USB_DISK_SIZE_GB:-2}"

RANGE_ID="${1:?Usage: $0 <range_id> -- e.g. ./post-deploy-hw.sh yellowkey}"
WIN11_VM="${RANGE_ID}-yk-win11"

pve() { sshpass -p "${PVE_PASS}" ssh -o StrictHostKeyChecking=accept-new "${PVE_USER}@${PVE_HOST}" "$@"; }

vmid_of() {
  local name="$1"
  pve "qm list | awk -v n=\"${name}\" '\$2==n {print \$1}'"
}

ensure_off() {
  local vmid="$1"
  local status
  status=$(pve "qm status ${vmid}" | awk '{print $2}')
  if [[ "${status}" != "stopped" ]]; then
    echo "[*] VM ${vmid} en cours -> shutdown" >&2
    pve "qm shutdown ${vmid} --timeout 60 || qm stop ${vmid}"
    sleep 2
  fi
}

add_tpm() {
  local vmid="$1"
  local cfg
  cfg=$(pve "qm config ${vmid}")
  if grep -q '^tpmstate0:' <<<"${cfg}"; then
    echo "[=] VM ${vmid} : vTPM deja present" >&2
    return
  fi
  echo "[+] VM ${vmid} : ajout vTPM 2.0" >&2
  pve "qm set ${vmid} -tpmstate0 ${PVE_STORAGE}:1,size=4M,version=v2.0"
}

add_usb_disk() {
  local vmid="$1"
  local cfg
  cfg=$(pve "qm config ${vmid}")
  if grep -qE '^(scsi1|sata1):' <<<"${cfg}"; then
    echo "[=] VM ${vmid} : disque secondaire deja present" >&2
    return
  fi
  echo "[+] VM ${vmid} : ajout disque secondaire (${USB_DISK_SIZE_GB} Go) en scsi1" >&2
  pve "qm set ${vmid} -scsi1 ${PVE_STORAGE}:${USB_DISK_SIZE_GB},ssd=1,discard=on"
}

process_vm() {
  local name="$1"
  local vmid
  vmid=$(vmid_of "${name}")
  if [[ -z "${vmid}" ]]; then
    echo "[!] VM ${name} introuvable cote Proxmox -- skip" >&2
    return
  fi
  echo "=== ${name} (vmid=${vmid}) ===" >&2
  ensure_off "${vmid}"
  add_tpm "${vmid}"
  add_usb_disk "${vmid}"
  echo "[*] Demarrage ${name}" >&2
  pve "qm start ${vmid}"
}

process_vm "${WIN11_VM}"

echo
echo "Fait. La VM est en cours de demarrage avec vTPM + disque secondaire." >&2
echo "Apres boot complet, relance le role BitLocker :" >&2
echo "  ludus range deploy -r ${RANGE_ID} --tags user-defined-roles" >&2
