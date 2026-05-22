# sbr.bitlocker

Active BitLocker sur le volume OS d'une VM Windows.

## Variables

| Variable | Defaut | Description |
|---|---|---|
| `bitlocker_protector` | `tpm` | `tpm` (UEFI + vTPM + Secure Boot) ou `password` (non implemente pour OS drive). |
| `bitlocker_target_drive` | `C:` | Volume a chiffrer. |
| `bitlocker_used_space_only` | `true` | Si `true`, chiffre uniquement l'espace utilise (rapide pour PoC). |
| `bitlocker_recovery_password_dest` | `/tmp/yk-recovery-{{ inventory_hostname }}.txt` | Fichier ou ecrire la recovery password (sur le Ludus host). |

## Notes

- Le role suppose qu'un vTPM est present (ajoute par `scripts/post-deploy-hw.sh` apres
  le premier deploy Ludus).
- En mode `tpm`, un reboot est declenche apres activation pour passer en
  `ProtectionStatus = On`.
- La recovery password est aussi visible cote Windows :
  `manage-bde -protectors -get C:`.
