# Vault air-gapped install bundle builder

`stage-vault-artifacts.sh` builds one verified tarball that you carry to air-gapped **RHEL 9** VMs. It holds Vault, optional OS packages and client tools, and the scripts that install and configure each node. It supports the migration described in [vault-unseal-migration.md](vault-unseal-migration.md) (§3.6 and §4).

It only prepares the nodes. It never starts, initialises, unseals or restores Vault. Those steps follow the migration plan.

## 1. Build the bundle (machine with internet)

**Requirements**
- Use a RHEL 9 host of the same minor release as the targets, with working repositories. Without `dnf` the OS packages are skipped (see Options).
- `bash`, `curl`, `gpg`, `tar`, `unzip` and `sha256sum` must be installed. `rpm`, and `podman` or `docker`, are optional.
- Know the HashiCorp signing-key fingerprint, taken from <https://www.hashicorp.com/security>, so you can check it.

**Run**

```bash
# Typical: Vault 2.2.1, plus the 1.15.2 binary for the downstream-clone test
./stage-vault-artifacts.sh -v 2.2.1 -d "1.15.2" --with-clients --with-docs \
  --gpg-fpr "<fingerprint from hashicorp.com/security>" -y
```

Without `--gpg-fpr` the script prints the key fingerprint and asks you to confirm it.

**Output** (next to the bundle directory)

| File | Purpose |
|---|---|
| `vault-migration-bundle-vault-2.2.1-rhel9-amd64.tar.gz` | The bundle to copy to each target |
| `…tar.gz.sha256` | Checksum. Send it by a **different path** than the bundle. |

During the build, the script checks:
- the GPG signature on each `SHA256SUMS` file
- the sha256 of each Vault zip
- the RPM signature, if `rpm` is available

It stops if any check fails.

## 2. Options

| Option | Default | Meaning |
|---|---|---|
| `-v, --version X.Y.Z` | `2.2.1` | Target Vault version |
| `-a, --arch amd64\|arm64` | `amd64` | Architecture of the target VMs |
| `-d, --downstream "V …"` | none | Extra Vault versions to stage for the downstream-clone test (§5.2) |
| `-o, --out DIR` | `./vault-migration-bundle` | Bundle directory |
| `--rhel N` | `9` | RHEL major version used for the RPM URL |
| `--no-rpm` | off | Skip the RPM. The zip is always included and is the fallback. |
| `--os-packages "…"` | `jq unzip tar chrony firewalld python3-dnf-plugin-versionlock` | RHEL packages bundled with their dependencies |
| `--os-alldeps` | off | Bundle all dependencies, not only those missing on the build host |
| `--no-os-packages` | off | Skip OS packages (use this if the targets have an internal mirror) |
| `--with-clients` | off | Add `oc`, `helm` and `jq` binaries (for the admin or jump host) |
| `--with-docs` | off | Save the Vault upgrade docs as HTML |
| `--with-image` | off | Also pull and save the `hashicorp/vault` images. Only needed for a container install, which this plan does not use. |
| `--gpg-fpr FPR` | prompt | Expected signing-key fingerprint. The build aborts on a mismatch. |
| `-y, --yes` | off | Don't prompt. Use it together with `--gpg-fpr`. |
| `--generate-only` | off | Only write the install scripts, with no downloads. For testing. |

Each option can also be set through its environment variable (`VAULT_VERSION`, `ARCH`, `DOWNSTREAM_VERSIONS`, `OUT_DIR`, `HASHICORP_GPG_FPR`).

## 3. Install on each target VM

```bash
sha256sum -c vault-migration-bundle-vault-2.2.1-rhel9-amd64.tar.gz.sha256
tar xzf vault-migration-bundle-vault-2.2.1-rhel9-amd64.tar.gz
cd vault-migration-bundle
cat README.txt
```

Run these as root, except the first. The bundle's own `README.txt` lists the same order:

| Step | Script | What it does |
|---|---|---|
| 1 | `install/00-verify-bundle.sh` | Checks the manifest and the HashiCorp signatures. Needs no root. Compare the printed key fingerprint with the one you confirmed. |
| 2 | `install/10-install-os-packages.sh` | Installs the bundled RPMs with repos disabled. Skip it if you use an internal mirror. |
| 3 | `install/20-install-vault.sh` | Installs the pinned Vault (RPM, or zip with a systemd unit as fallback). It checks the version and leaves the service **stopped and disabled**. |
| – | *(manual)* | Copy `vault.crt`, `vault.key` and `ca.pem` to `/opt/vault/tls/`. These come from your internal CA. |
| 4 | `install/30-configure-node.sh --node N --domain example.com [--prefix vault-unseal]` | Writes `/etc/vault.d/vault.hcl` for node N, creates `/vault/audit`, and runs `vault operator diagnose`. |
| 5 | `install/40-host-prep.sh [--ntp-server HOST]` | Opens firewall ports 8200 and 8201, enables chrony, and warns if swap is on. |

Run `20-install-vault.sh` on every node. Run `30-configure-node.sh` once per node, with `--node 1`, `2` and `3`.

**Extra scripts, only where needed in the migration**

| Script | Where | Purpose |
|---|---|---|
| `50-install-downstream-versions.sh` | Rehearsal VM only | Unpacks the downstream Vault binaries to `/opt/vault-downstream/<version>/` (§5.2) |
| `60-install-clients.sh` | Admin or jump host | Installs `oc`, `helm` and `jq` to `/usr/local/bin` |
| `65-load-images.sh` | Only with `--with-image` | Loads the saved container images. Does nothing otherwise. |
| `70-install-snapshot-timer.sh [--dir D --keep N --schedule S]` | One node, after cutover | systemd timer for Raft snapshots (§9.2). It expects a token in `/etc/vault.d/snapshot.token` (mode 600). |

For the workstation CLI used by `policy fmt` and `snapshot inspect`, unzip `vault/2.2.1/vault_2.2.1_linux_amd64.zip` by hand.

## 4. Bundle layout

```
vault-migration-bundle/
├── README.txt            run order for the targets
├── MANIFEST.sha256       sha256 of every file
├── vault/<version>/      signed zip, SHA256SUMS, SHA256SUMS.sig (target + downstream versions)
├── rpm/                  Vault RPM
├── os-packages/          OS RPMs with dependencies
├── clients/              oc, helm, jq          (--with-clients)
├── docs/                 saved upgrade docs     (--with-docs)
├── images/               container images       (--with-image)
├── keys/                 HashiCorp signing keys
├── config/vault.hcl.tpl  node config template
└── install/              scripts above, lib.sh, versions.env
```

Empty directories are removed before packing.

## 5. Troubleshooting

| Symptom | Fix |
|---|---|
| `Fingerprint mismatch` on build | The downloaded key is not the one you expected. Stop and check the source. Don't override. |
| `RPM not found at that URL` | The version or OS combination has no RPM. The targets fall back to the zip automatically. |
| `dnf download failed` / OS packages skipped | The build host needs `dnf-plugins-core` and an entitled repo, so run it on a RHEL 9 host. Otherwise use `--no-os-packages` and your internal mirror. |
| `Installed version is not 2.2.1` | Another `vault` binary is earlier in `PATH`, or an older RPM is installed. Run `rpm -q vault` and `which -a vault`. |
| `Missing /opt/vault/tls/…` | Copy the certificate, key and CA before step 4. |
| `diagnose` reports a duplicate key | Remove the duplicate from `vault.hcl`. This is a hard error on 2.x. |
| `dnf` complains about a downgrade when installing OS packages | The build host differs from the targets. Rebuild on a host matching the target minor release, or use your mirror. |
| Vault cannot bind or read files after first start | Check SELinux: `ausearch -m avc -ts recent`. |

## 6. Notes

- **Version:** the default is Vault **2.2.1**, the newest stable release at the time of writing (published 2026-10-22). Before you build, check <https://releases.hashicorp.com/vault/> and use `-v` if a newer patch exists. Use the same version in the rehearsal and at cutover.
- **Native install:** Vault runs as a systemd service, not in containers, as discussed in the plan. `--with-image` exists only for sites that require containers.
- **Never installed on the targets:** the internal-CA certificates and the unseal keys. Handle both outside this bundle.
- **Syntax check only:** the script and the generated scripts have passed `bash -n` and ShellCheck. They have not yet been tested on a real RHEL 9 VM. Do one full dry run on a throwaway VM, with egress blocked, before the rehearsal.
