# Validator runbook

Step-by-step procedures for the optional validator client in `validator/`. What it is and the commands: "Optional: validator client" in the [README](../README.md).

Times below use PulseChain's beacon chain: a slot is 10 s, and an epoch is 32 slots (5 min 20 s).

**The one rule behind most of this:** a validator key must only ever sign from **one** place, with the **newest** slashing-protection history. Two copies running at once, or one started from an older copy of its data, can sign conflicting messages. That gets the validator slashed: part of the stake is burned, and it's forced out. Doppelganger protection (on in this setup) catches many such cases, but not all.

---

## 1. First switch-on

Only after the node has met its readiness bar, and the keys were generated **offline** (PulseChain's staking-deposit-cli, never on this machine). You need the `keystore-m_*.json` files and the keystore password. The `deposit_data-*.json` file is only for the launchpad.

1. **Keep the validator data out of backups and snapshots.** It lives in `${DATA_DIR}/validator` (default `/blockchain/validator`). If the node is a VM, make sure that disk is excluded from VM backups (Proxmox: the disk's **Backup** box unchecked). Never take a VM snapshot you might later roll back to.
2. **Settings:** `cp validator/.env.example validator/.env`, then set `FEE_RECIPIENT` to your address. Check it character by character against the address your hardware wallet shows.
3. **Import the keys** from the USB stick: `sudo ./validator/import-keys.sh /media/<stick>/validator_keys`. It asks for a new wallet password on first use. Save that password in your password manager. Then it asks for the keystore password.
4. **Check the public keys** it lists against the `pubkey` fields in `deposit_data-*.json`. Then wipe the keystores from the USB stick (the offline copy and the mnemonic are your backup).
5. **Switch on:** `sudo ./validator/enable.sh`. It shows the fee recipient and asks you to type `switch on`.
   - The client starts, and doppelganger protection waits 2–3 epochs.
   - Before the deposit, the log shows the key as unknown or waiting for a deposit, and the control page shows the status as Unknown. That's expected, and costs nothing.
   - Starting **before** the deposit proves the keys load and the settings are right, while nothing is at stake yet.
6. **Deposit** on the PulseChain launchpad from the wallet holding the stake. Before you confirm, check that the withdrawal credentials start with `0x01` followed by your withdrawal address.
7. **Watch the status** on the control page or the Validator dashboard: Deposited → Pending → Active. Activation can take hours to days, depending on the queue. Within two epochs of Active, "Last attestation" should stay under about 64 slots.
8. **For the first week,** check the Validator dashboard daily. Target votes should be close to 100%, failed attestations near 0, and no alerts.

## 2. Restarts, reboots and updates

- **Every start costs 2–3 epochs** (about 11–16 minutes) of missed attestations, because of the doppelganger wait. That's a small loss, about what it would have earned in that time. Don't restart without a reason.
- **Rebooting the VM or host:** just shut down cleanly. Docker stops the validator with the rest and starts it again on boot.
- **Stop node / Start node** (control page, or `./stop.sh` / `./start.sh`) stop the validator first and bring it back afterwards.
- **Stop validator / Start validator** (control page, or `./validator/stop.sh` / `./validator/resume.sh`): a validator stopped this way stays down through node restarts and reboots until you start it again.
- **Updates:** Apply update never restarts the validator. When an update changes `validator/` (for example a new image pin), it lists `sudo ./validator/restart.sh` as a manual step. Run it when convenient. `restart.sh` runs the start checks again.
- **Changing the fee recipient:** edit `validator/.env`, then `sudo ./validator/restart.sh`.

## 3. Moving the validator to another machine (or a rebuilt VM)

The order matters. Never start the new copy until the old one is provably stopped.

1. **On the old machine:** `sudo ./validator/disable.sh`. This stops it, removes the container and switches it off, so nothing brings it back.
2. **Wait at least 2 full epochs** (11 minutes; 15 to be safe). On the beacon explorer, confirm the validator **missed** an attestation after the stop. That proves nothing else is signing with these keys.
3. **On the old machine:** `sudo ./validator/export-slashing.sh`. It writes `${DATA_DIR}/validator/exports/<time>/`. Copy that JSON to the new machine.
4. **Make sure the old copy can't come back.** Delete its keys (`sudo rm -rf ${DATA_DIR}/validator`, after the export is safely copied), or power the old machine off for good.
5. **On the new machine:** set up `validator/.env`, `sudo ./validator/import-keys.sh <keys>`, `sudo ./validator/import-slashing.sh <exported json>`, then `sudo ./validator/enable.sh`.
6. Watch the first attestations as in step 7 of section 1.

## 4. Restoring the VM, or losing the validator data

- **A VM restored from a backup** brings back only its OS disk. The chain disk, and with it the validator data, isn't in the backup. So the restored VM has no wallet and no `ENABLED` marker, and the validator can't start there by accident. To validate from it, follow section 3. If the old machine is gone, follow the next point.
- **The slashing-protection data is lost** (disk failure, or no export from the old machine):
  1. Make sure no other copy is running anywhere (section 3, steps 1–2).
  2. Wait **at least an hour** since the validator last signed. New attestations are then all for later epochs than anything it signed before, so they can't conflict. An hour costs about 12 epochs of rewards; being slashed costs far more.
  3. Import the keys on a fresh data directory, then `sudo ./validator/enable.sh`. Doppelganger protection is a second check.
- **An older copy of the slashing-protection DB is no better than none.** It's missing the newest signatures. Treat it as lost, and wait as above.
- **Never** restore or roll back a VM snapshot that includes the validator data while the original might still be running.

## 5. Adding another validator

1. Offline, with the same mnemonic: `existing-mnemonic --validator_start_index <N>`, where N is the number of validators you already have, with the same `--execution_address`.
2. `sudo ./validator/stop.sh`, then `sudo ./validator/import-keys.sh <new keys>`, then `./validator/resume.sh`.
3. Deposit the new one on the launchpad, as in section 1, step 6.

## 6. Voluntary exit (permanent)

An exit can't be undone, and the keys can never validate again. The whole balance is paid to the withdrawal address.

1. On the beacon explorer, check that the withdrawal credentials are `0x01` followed by **your** withdrawal address.
2. `sudo ./validator/exit.sh`. Type `exit for good`, then Prysm's own confirmation phrase. The exit is signed by the validator's signing key and sent to the local beacon.
3. **Keep the validator running** until its status reads **Exited**. It still has duties until its exit epoch, and the exit queue can take a while.
4. Then `sudo ./validator/disable.sh`.
5. The balance becomes withdrawable a while after the exit epoch (the protocol's withdrawability delay, about a day), and the next withdrawal sweep pays it to the withdrawal address. Check it arrived.

The pinned client (Prysm-Pulse v2.3.0) predates exits triggered from the withdrawal address (EIP-7002), so plan on exiting with the signing key as above.

## 7. Something looks like double-signing

Signs: the **Slashing protection refused to sign** alert, refusals on the control page, the doppelganger check stopping the client with a "duplicate" or "doppelganger" error in `./validator/logs.sh`, or a **Slashing** status.

1. **Stop everywhere, now:** `sudo ./validator/disable.sh` on this machine, and stop any other machine that might hold the keys.
2. Find the other copy: an old VM, a snapshot, a test machine, a second import.
3. Don't switch back on until you know why, and then follow section 4 (wait, empty or exported history).
4. **If it was slashed** (status Slashing / Exited): the chain exits it by force, and the remaining balance is paid to the withdrawal address weeks later. Leave it switched off. Running it again doesn't help.
