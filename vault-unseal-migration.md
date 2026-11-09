# Procedure: Migrate the `vault-unseal` Vault from OpenShift to a 3-node HA cluster on VMs (1.15.2 → 2.2.1)

> **Scope**: This covers the Vault Community Edition **1.15.2** instance deployed with the Helm chart on OpenShift. That instance provides the **Transit auto-unseal** service for other Vault clusters (called the *downstream* Vaults below). It moves to 3 VMs running Vault CE **2.2.1** with **Integrated Storage (Raft)**, and it keeps all data: the transit key(s), tokens, policies and auth methods.

---

## 0. Summary

| Phase | What happens | Impact |
|---|---|---|
| 1. Discovery | Find the storage backend, seal type, config and downstream consumers | None |
| 2. Version compatibility | Find and fix what breaks between 1.15.2 and 2.2.1, **on the source** | Small config or policy changes on the source |
| 2b. Air-gap prep (§3.6) | Download, verify and stage Vault 2.2.1, downstream binaries, CLIs, offline docs, internal CA certs | None |
| 3. Build the VMs | Install Vault 2.2.1, TLS, config, systemd, load balancer and DNS | None |
| 4. Rehearsal (**mandatory**) | Restore a copy of the data on 2.2.1, validate, and auto-unseal a downstream clone, then wipe | None |
| 5. Cutover | Freeze, final backup, restore on VM 1, join nodes 2 and 3, validate | Short window: downstream Vaults cannot **restart or unseal** |
| 6. Switch consumers | Repoint DNS or downstream `seal "transit"` config, then do a controlled restart | Rolling restarts of downstream Vaults |
| 7. Decommission | After a soak period, remove the Helm release and PVCs | None |

**Recommended approach**

- **The source uses Raft storage**, which is the default when the chart runs with `server.ha.raft.enabled=true`: use a **Raft snapshot, then a forced restore** onto the new cluster (Path A).
- **The source uses `file` storage**, which is the chart's default standalone mode: copy the data directory, then run `vault operator migrate` from file to Raft (Path B).

In both cases the **encrypted data and the barrier keyring move unchanged**. The new cluster is unsealed with the **original unseal keys**. The transit keys, and the tokens the downstream Vaults use, keep working as they did. Vault 2.2.1 upgrades the internal data format automatically on its first unseal (see §3).

---

## 1. Hard prerequisites (blockers)

- [ ] **The original unseal keys** (at least the threshold number of Shamir shares) of the OpenShift `vault-unseal` instance. Without them the migrated data **cannot be decrypted**. Stop here if you don't have them.
- [ ] **A root token, or a token with admin privileges**, that is valid **on the source**. On 2.x, `sys/generate-root` and `sys/rekey` **require an authenticated token** in addition to the key shares (see §3.1). If you don't have a root or admin token, create one **on the 1.15.2 source before the migration** (`vault operator generate-root`), while that endpoint still works without authentication.
- [ ] **All version-compatibility blockers from §3 fixed on the source**, and a rehearsal (§5) that passed on 2.2.1.
- [ ] **An inventory of every downstream Vault** that uses this instance: its Vault version and its `seal "transit"` stanza (address, key name, mount path, token, TLS settings). **Don't upgrade the downstream Vaults** as part of this project. One change at a time.
- [ ] **A change freeze** during the migration:
  - no transit key rotation (`transit/keys/<key>/rotate`)
  - no policy, auth or token changes on `vault-unseal` (except the remediations from §3)
  - **no restarts of downstream Vaults**. If a downstream Vault runs on Kubernetes or OpenShift, look out for node drains, pod evictions and upgrades.

---

## 2. Phase 1: Discovery on OpenShift

Set your context:

```bash
export NS=<vault-namespace>          # e.g. vault-unseal
export RELEASE=<helm-release-name>   # e.g. vault
oc project $NS
```

### 2.1 Helm values and effective config

```bash
helm list -n $NS
helm get values $RELEASE -n $NS -a > helm-values.yaml
oc get cm -n $NS | grep -i config
oc get cm ${RELEASE}-config -n $NS -o yaml > vault-config-cm.yaml   # standalone or HA config
oc get statefulset,pvc,route,svc -n $NS
```

### 2.2 Vault status, version and storage type

```bash
oc exec -n $NS ${RELEASE}-0 -- vault status
```

Record these fields:

| Field | Why it matters |
|---|---|
| `Version` | Should be `1.15.2`. The target is `2.2.1` (see §3) |
| `Storage Type` | `raft` means Path A. `file` means Path B |
| `Seal Type` | `shamir` is expected. If it is `awskms`, `azurekeyvault`, `gcpckms` or similar, copy the **same `seal` stanza** to the VMs, which must be able to reach that KMS |
| `HA Enabled` | Informational |

If the storage type is Raft:

```bash
oc exec -n $NS ${RELEASE}-0 -- sh -c 'VAULT_TOKEN=<token> vault operator raft list-peers'
```

### 2.3 Inventory of the logical content (baseline for later comparison)

Run these from your workstation through a port-forward:

```bash
oc port-forward -n $NS svc/${RELEASE} 8200:8200 &
export VAULT_ADDR=https://127.0.0.1:8200   # or http:// if TLS is disabled in the chart
export VAULT_SKIP_VERIFY=true              # only for this port-forward session
export VAULT_TOKEN=<root-or-admin-token>

mkdir -p baseline && cd baseline
vault secrets list -detailed -format=json  > secrets.json
vault auth list -detailed -format=json     > auth.json
vault policy list                          > policies.txt
for p in $(vault policy list); do vault policy read "$p" > "policy_$p.hcl"; done
vault audit list -detailed -format=json    > audit.json 2>/dev/null || true
vault list -format=json auth/token/accessors > accessors.json
# For each transit mount (usually "transit/"):
vault list -format=json transit/keys       > transit_keys.json
for k in $(vault list -format=json transit/keys | jq -r '.[]'); do
  vault read -format=json transit/keys/$k  > "transit_key_$k.json"
done
```

### 2.4 Inventory of the downstream tokens

For each downstream Vault, look up the token from its `seal "transit"` stanza:

```bash
vault token lookup <downstream-transit-token>
```

Record the `accessor`, `ttl`, `period`, `renewable`, `orphan` and **`policies`** fields. The policies matter for §3.3.

> ⚠️ Running downstream Vaults **renew their transit token against this instance**. The only exception is a seal configured with `disable_renewal = "true"`. Renewals that happen on the old instance after the final snapshot are lost. The token then keeps the TTL it had **at snapshot time**. Make sure the remaining TTL is well above the planned cutover window. Periodic tokens are ideal.

### 2.5 Things that break outside OpenShift

- **Audit devices**: if `audit.json` shows a `file` audit device (for example `/vault/audit/audit.log`), create **the same path** on every VM and make it writable by `vault`. Otherwise Vault can fail to unseal after the restore. **2.2.1 also has stricter audit rules; see §3.2.**
- **The Kubernetes auth method** (`auth/kubernetes`): it stops working when Vault runs outside the cluster. Plan to reconfigure it (`kubernetes_host`, `token_reviewer_jwt`, CA) or remove it if nothing uses it.
- **Custom plugins**: copy the plugin binaries and set `plugin_directory`. Check that each plugin is compatible with 2.2.1.
- **The downstream `address`**: note whether the downstream Vaults reach this instance through an **OpenShift Route** (`*.apps.<cluster>`), a Service, or a custom DNS name. This decides how the cutover works (see §7).

---

## 3. Phase 2: Version compatibility (1.15.2 → 2.2.1)

### 3.0 Key facts

| Topic | What it means here |
|---|---|
| **Is a direct jump supported?** | Vault upgrades in place and automatically migrates internal data **on the first unseal** of the new version. Restoring a 1.15.2 snapshot on 2.2.1, or migrating 1.15.2 file data with a 2.2.1 binary, is the same kind of upgrade. HashiCorp does **not** publish a required stepping path. Instead it asks you to read the change tracker for every version you skip, and to **test on an isolated copy**. That is the purpose of §3.1–§3.5 and the mandatory rehearsal (§5). |
| **Downgrade** | HashiCorp gives **no backward-compatibility guarantee** for the data store. Once 2.2.1 has unsealed the data, it **cannot** go back to 1.15.2. The rollback is the **untouched OpenShift 1.15.2 instance** (§8). Never modify, and never restore a 2.2.1 snapshot into, the old instance. |
| **Transit engine and transit seal** | The transit API that the downstream Vaults use (`transit/encrypt`, `transit/decrypt`, token renew) did not change in a breaking way between these versions. Your downstream Vaults stay on their current version. The transit seal is a **client** of this cluster. |
| **What can actually break the unseal role** | 1. A **policy** attached to the downstream tokens that 2.2.1 rejects (§3.3). 2. An **audit device** that blocks unseal or blocks requests (§3.2). 3. A missing **`disable_mlock`** on Raft (§3.4). All three can be detected before the cutover. |

### 3.1 Breaking changes between 1.15.2 and 2.2.1 that matter here

| Change | Version | Impact on `vault-unseal` | Action |
|---|---|---|---|
| Duplicate attributes in HCL **policies** and config are **no longer parsed** | Deprecated 1.20, **removed 2.0.4** | 🔴 **Critical.** If a policy has a duplicate attribute (for example `capabilities` twice in one `path` block), Vault **errors when creating a token with that policy or when using an existing token that references it**. If that policy belongs to a downstream transit token, **the downstream Vaults can no longer auto-unseal**. | §3.3 |
| File audit device hardening (CVE-2025-6000): no executable `mode`, no writing into the plugin directory, prefixes require `allow_audit_log_prefixing` | 1.20.1+; exec-mode check **enforced at unseal** from 2.0.0 | 🔴 An existing file audit device with exec bits can cause an **error at unseal**. A prefixed device needs the new config flag. | §3.2 |
| `disable_mlock` must be set explicitly with Integrated Storage | 1.20.0 | 🟠 The node won't start without it | Already set in §4.4 |
| Templated policy paths may no longer contain wildcards or globs | 2.0.1 | 🟠 Only if you use `{{identity...}}` templates | §3.3 |
| `allowed_parameters` / `denied_parameters` evaluation of list values changed | 1.21.0 | 🟡 Only if policies use them | §3.3 |
| `sys/rekey` and `sys/generate-root` require an authenticated token. Rekey and generate-root cancellation requires a nonce | 2.0.0 / 1.20.0 | 🟠 Operational: you can't create a root token "from keys only" anymore | Keep an admin token (§1). Update any rekey or generate-root runbooks |
| Vault rejects uncleaned request paths (`//`, `/./`, `/../`) | 2.0.0 | 🟡 Only affects badly built client paths | Check custom scripts. The rehearsal (§5.2) covers the transit seal |
| Duplicate attributes are no longer accepted in the **server config file** | 2.0.4 | 🟡 | The new `vault.hcl` (§4.4) is written from scratch. Don't copy the Helm config blindly |
| ACL policy cache / deny-bypass and policy-name alias security fixes (mixed-case policy names, root-policy alias via cache-key collision) | 2.0.4, 2.1.2, 2.2.1 | 🟡 Behavioural: policy names that differ only by case, or aliases that resolve to `root`, are now refused | Check `policies.txt` for case-colliding names or tokens that rely on them. Another reason to run 2.2.1 rather than 2.1.1 |
| Plugin catalog entries are restored from Raft snapshots | 2.1.2 | 🟡 Only with custom plugins | The plugin binaries must exist on the VMs *before* the restore (§2.5) |
| Token header size limit (8 KB default, `max_token_header_size`) | 2.1.0 | 🟢 Transit tokens are small | None, unless a client sends huge JWTs |
| Official images no longer need `IPC_LOCK` | 2.0.2 | 🟢 Container only | None for VMs |
| Maximum RSA modulus of 8192 bits (CVE-2026-39829) | 2.0.2 | 🟠 Only if a PKI/transit RSA key above 8192 bits exists | Check `transit_key_*.json` for `rsa-*` types and PKI roles |

> **Verify against the official page.** The 2.x important-changes page lists duplicate-attribute rejection under **2.1.0**, while the release notes this plan was built from say **2.0.4**. Treat it as enforced on 2.2.1 either way. The 2.2.0 notes also list an AWS credential-precedence change; it does not apply to a transit-only instance unless you use the AWS auth method or secrets engine.

> Before you run the migration, re-read the official [change tracker](https://developer.hashicorp.com/vault/docs/updates/change-tracker), [important changes](https://developer.hashicorp.com/vault/docs/updates/important-changes) and [deprecation notices](https://developer.hashicorp.com/vault/docs/updates/deprecation). If a patch release after 2.2.1 is available by then, prefer it.

### 3.2 Audit devices (fix on the source, before the final snapshot)

```bash
jq -r 'to_entries[] | select(.value.type=="file") |
  "\(.key)  path=\(.value.options.file_path)  mode=\(.value.options.mode // "0600 (default)")  prefix=\(.value.options.prefix // "-")"' \
  baseline/audit.json
```

| Finding | Fix |
|---|---|
| `mode` has **any executable bit** (for example `0755` or `0777`) | On the source, `vault audit disable <path>`, then re-enable it with `mode=0600` (or `0640`) |
| `prefix` is set | Either remove it (disable, then re-enable without `prefix`) **or** add `allow_audit_log_prefixing = true` to the new `vault.hcl` |
| `file_path` is inside a plugin directory | Move it (disable, then re-enable with a new path) |
| `file_path` is `stdout` or `discard` | No action |

> Simplest option if the audit device isn't needed during the cutover: **disable the file audit devices on the source right before the final snapshot** and re-enable them on the new cluster once it is healthy. If you have **no** working audit device at that moment, Vault doesn't block requests. If an enabled audit device fails to write, Vault **blocks requests**, including the downstream `transit/decrypt` calls.

### 3.3 Policies (fix on the source, before the final snapshot)

The most important policies are the ones attached to the **downstream transit tokens** (§2.4). Check all of them anyway.

1. **Duplicate attributes, local pre-check.** Download the 2.2.1 CLI to your workstation (the `vault` binary works as a client too) and parse every exported policy with it:

   ```bash
   mkdir -p policy-check && cp baseline/policy_*.hcl policy-check/
   for f in policy-check/*.hcl; do
     ./vault-2.2.1 policy fmt "$f" >/dev/null 2>&1 || echo "PARSE ERROR: $f"
   done
   ```

   A duplicate looks like this:

   ```hcl
   path "transit/decrypt/autounseal" {
     capabilities = ["update"]
     capabilities = ["update"]     # ← duplicate attribute: fatal on 2.0.4+
   }
   ```

   This is a **quick pre-check only**. The authoritative test is the rehearsal, where the real tokens call the real policies on 2.2.1 (§5.2).

2. **Templated policies with globs**:

   ```bash
   grep -l '{{' baseline/policy_*.hcl
   ```

   For each file listed, make sure the templated `path` doesn't produce `*` or `+`.

3. **List parameters**:

   ```bash
   grep -lE 'allowed_parameters|denied_parameters' baseline/policy_*.hcl
   ```

   Review each file listed against the 1.21 behavior change.

4. **Fix on the source (1.15.2)** with `vault policy write <name> fixed.hcl`. Tokens reference policies **by name**, so no token needs to be reissued. Then export the baseline again (§2.3).

### 3.4 Config differences for 2.2.1 (already applied in §4.4)

- `disable_mlock = true`: **mandatory** with Raft since 1.20.
- `allow_audit_log_prefixing = true`: only if you kept a prefixed file audit device (§3.2).
- No duplicate keys anywhere in `vault.hcl`.
- `enable_unauthenticated_access`: leave it **unset** (secure default), unless an existing automation calls rekey or generate-root without a token.

### 3.5 Fallback strategy if the rehearsal of the direct jump fails

If you hit a blocker you can't fix on the source, migrate **like-for-like**:

1. Install **1.15.2** on the VMs.
2. Do the cutover (§6–§7).
3. Upgrade **in place**, one node at a time: standbys first, then the active node after `vault operator step-down`.
   - Hop through intermediate releases that you rehearsed (for example the latest 1.17.x, 1.19.x, 1.21.x, 2.0.x, then 2.2.1).
   - Take a Raft snapshot before each hop.

This takes longer. It keeps the platform migration and the version upgrade separate, and lets you find exactly which version breaks.

### 3.6 Air-gapped preparation (do this first, on a connected host)

The VMs, the workstation that runs the CLI, and probably the OpenShift admin host have no internet access. Everything below is **downloaded once on a connected "staging" host, verified, then carried in** through your approved path (artifact repository, data diode, or removable media with a scan). Do it **before** the rehearsal; a missing file in the middle of the cutover window is the most common air-gap failure.

**1. Download and verify Vault 2.2.1** (staging host):

```bash
V=2.2.1
BASE=https://releases.hashicorp.com/vault/$V
mkdir -p stage && cd stage
curl -fLO $BASE/vault_${V}_linux_amd64.zip          # use linux_arm64 if the VMs are arm64
curl -fLO $BASE/vault_${V}_SHA256SUMS
curl -fLO $BASE/vault_${V}_SHA256SUMS.sig
# Import HashiCorp's release-signing key (fetch it from https://www.hashicorp.com/security and
# check the fingerprint against that page, not against this document):
gpg --import hashicorp.asc
gpg --verify vault_${V}_SHA256SUMS.sig vault_${V}_SHA256SUMS
sha256sum -c vault_${V}_SHA256SUMS --ignore-missing
# Optional: RPM/DEB from https://rpm.releases.hashicorp.com or https://apt.releases.hashicorp.com
# (or reposync/apt-mirror into your internal repo), plus the macOS/Linux CLI for your workstation.
```

Also check that 2.2.1 is still the newest release at the time (see the note in §3.1), and take the **same version** for every artifact below.

**2. Staging bundle checklist**

| Item | Used for |
|---|---|
| `vault_2.2.1_linux_<arch>.zip` (or RPM/DEB) + `SHA256SUMS` + `.sig` + the HashiCorp public key | VMs (§4.3), and the workstation CLI for `policy fmt` and `snapshot inspect` (§3.3, §6.2) |
| Vault binary of each **downstream** version (and its config backup) | Downstream clone test (§5.2) |
| `jq`, `unzip`, `tar`, `curl`, `sha256sum`, `chrony`; the OS packages Vault's host needs (from your OS mirror) | Scripts in this plan, NTP |
| `oc` and `helm` CLIs matching the OpenShift cluster | Discovery and backup (§2, §6.2) |
| Load balancer software/config (for example HAProxy RPM) from your OS mirror | §4.1 |
| TLS certificates and keys issued by the **internal CA**, plus the CA chain | §4.2; no Let's Encrypt or ACME in an air gap |
| **Offline copies** of the [change tracker](https://developer.hashicorp.com/vault/docs/updates/change-tracker), [important changes](https://developer.hashicorp.com/vault/docs/updates/important-changes), the upgrade docs and this runbook (PDF or Markdown) | Reference during the window, since the links in this plan won't open |
| Vault CHANGELOG for 1.15.2 → 2.2.1 | Review of skipped releases (§3.1) |

**3. Internal infrastructure that must work without the internet**

- [ ] Internal **NTP**, **DNS** (all five names in §4.2) and an internal **CA**
- [ ] Vault never needs to call out: no telemetry, no plugin downloads, no ACME, no cloud KMS seal. If the source seal is a cloud KMS (§2.2), the VMs must reach it through an approved internal route, or you must **seal-migrate** instead (a different plan)
- [ ] OS package updates come only from an internal mirror; **pin and hold** the Vault package (§4.3)
- [ ] Firewall rules between the OpenShift admin host, the staging host, the VMs and the LB are open before the window
- [ ] A transfer path from OpenShift to VM 1 for the snapshot (§6.3): an allowed jump host or approved media, with the sha256 checked on both ends

**4. Verify on the target, offline**

```bash
sha256sum vault_2.2.1_linux_amd64.zip          # compare with the recorded value from the verified SHA256SUMS
/usr/local/bin/vault version                   # Vault v2.2.1 (...)
sudo -u vault vault operator diagnose -config=/etc/vault.d/vault.hcl -skip=storage
```

**5. Dry-run the carry-in.** Before the rehearsal, confirm that a VM can install from the staged bundle with no network at all (disconnect or block egress), so that missing dependencies show up now.

---

## 4. Phase 3: Build the target platform

### 4.1 Target architecture

```
                 downstream Vaults (seal "transit")
                               │
                https://vault-unseal.example.com:8200
                               │
                    ┌──────────┴──────────┐
                    │ Load balancer (TCP) │  health: /v1/sys/health?standbyok=true
                    └──┬────────┬────────┬┘
                       │        │        │
                  vault-unseal-1  -2     -3   (Vault 2.2.1, Raft, 8200 API / 8201 cluster)
```

- A transit seal accepts **one** `address`. That address must be a **load balancer or VIP** in front of the 3 nodes. Without one, HA gives you nothing.
- In CE, standby nodes **forward** requests to the active node. The LB may therefore send traffic to any unsealed node.
- LB health check: `GET /v1/sys/health?standbyok=true` returns `200` for the active node and unsealed standbys, and `503` for sealed nodes. Use **TCP or TLS passthrough** so that TLS terminates on Vault.

### 4.2 VM prerequisites (all 3 nodes)

- [ ] 3 VMs, ideally in separate failure domains (hypervisor hosts, racks or AZs), running a supported Linux on **amd64** or **arm64**
- [ ] Sizing: 2 vCPU, 4–8 GB RAM and 20–50 GB of **SSD** for `/opt/vault/data` is plenty for an unseal-only cluster
- [ ] **Swap disabled or encrypted**: the Raft backend uses `disable_mlock = true`
- [ ] NTP synchronised
- [ ] DNS: `vault-unseal-1/2/3.example.com`, plus `vault-unseal.example.com` pointing to the LB
- [ ] Firewall:
  - `8200/tcp`: clients, the LB and the other nodes
  - `8201/tcp`: node to node only
- [ ] TLS certificate(s) signed by a CA the downstream Vaults trust. Use **SHA-256 or stronger signatures** and RSA keys of **8192 bits at most** (2.0.2+ rejects larger RSA moduli). SANs: `vault-unseal.example.com`, `vault-unseal-{1,2,3}.example.com`, the node IPs and `127.0.0.1`. If you plan to **reuse the old hostname** (§7, option 1), add it to the SANs as well.
- [ ] Downstream Vaults: their Vault version and TLS client stack must accept the new cert. If a downstream Vault is very old, test it in the rehearsal (§5.2).

### 4.3 Install Vault 2.2.1 (pinned, offline)

The VMs have no internet access, so **do not use the online repository commands** from the vendor docs. Use the artifacts staged in §3.6 (Option A: package from your internal mirror, or Option B: the zip binary).

**Option A: offline package (internal mirror or copied RPM/DEB)**

```bash
# RHEL/Rocky/Alma: from the staged directory or an internal repo
sudo dnf install -y ./vault-2.2.1-1.x86_64.rpm
sudo dnf install -y 'dnf-command(versionlock)' && sudo dnf versionlock add vault   # plugin must be in your internal repo
# Debian/Ubuntu
sudo apt install -y ./vault_2.2.1-1_amd64.deb && sudo apt-mark hold vault
vault version        # must print Vault v2.2.1
```

**Option B: zip binary** (when no package is allowed). The zip contains only the binary, so you create the user, directories and unit file yourself:

```bash
sudo unzip vault_2.2.1_linux_amd64.zip -d /usr/local/bin && sudo chmod 755 /usr/local/bin/vault
sudo useradd --system --home /opt/vault --shell /usr/sbin/nologin vault
sudo mkdir -p /etc/vault.d /opt/vault/data /opt/vault/tls
sudo chown -R vault:vault /opt/vault && sudo chmod 750 /etc/vault.d
sudo tee /etc/systemd/system/vault.service >/dev/null <<'EOF'
[Unit]
Description=HashiCorp Vault
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=full
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
```

> Pin the version so that an unattended OS update can't move a node to a different Vault version. With the zip, nothing updates it automatically, but record the sha256 of the binary in your CMDB.

The package (Option A) creates the `vault` user, `/etc/vault.d/`, `/opt/vault/data` and `vault.service`.

<details><summary>Original online instructions (only where internet access exists)</summary>

RHEL/Rocky/Alma:

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y vault-2.2.1
sudo dnf install -y 'dnf-command(versionlock)' && sudo dnf versionlock add vault
vault version        # must print Vault v2.2.1
```

Debian/Ubuntu:

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && apt list -a vault | head      # check the exact package string for 2.2.1
sudo apt install -y vault=2.2.1-1 && sudo apt-mark hold vault
```

</details>

Then, on every node:

```bash
sudo mkdir -p /opt/vault/tls
sudo cp vault.crt vault.key ca.pem /opt/vault/tls/
sudo chown -R vault:vault /opt/vault
sudo chmod 640 /opt/vault/tls/vault.key
# If a file audit device stays enabled (see §3.2), for example:
sudo mkdir -p /vault/audit && sudo chown vault:vault /vault/audit && sudo chmod 750 /vault/audit
```

### 4.4 `/etc/vault.d/vault.hcl` (example for node 1; change `node_id`, `api_addr` and `cluster_addr` on each node)

```hcl
ui            = true
disable_mlock = true            # MANDATORY with Integrated Storage since Vault 1.20
cluster_name  = "vault-unseal"

# Only if you kept a file audit device with a "prefix" option (see §3.2):
# allow_audit_log_prefixing = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-unseal-1"

  retry_join {
    leader_api_addr     = "https://vault-unseal-1.example.com:8200"
    leader_ca_cert_file = "/opt/vault/tls/ca.pem"
  }
  retry_join {
    leader_api_addr     = "https://vault-unseal-2.example.com:8200"
    leader_ca_cert_file = "/opt/vault/tls/ca.pem"
  }
  retry_join {
    leader_api_addr     = "https://vault-unseal-3.example.com:8200"
    leader_ca_cert_file = "/opt/vault/tls/ca.pem"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/opt/vault/tls/vault.crt"
  tls_key_file    = "/opt/vault/tls/vault.key"
  tls_min_version = "tls12"
}

api_addr     = "https://vault-unseal-1.example.com:8200"
cluster_addr = "https://vault-unseal-1.example.com:8201"

# Only if the source uses a KMS auto-unseal: copy its seal "..." stanza here unchanged.
# Only if custom plugins exist:
# plugin_directory = "/etc/vault.d/plugins"
```

Check the file before you start the service. Duplicate keys are a hard error on 2.2.1:

```bash
sudo -u vault vault operator diagnose -config=/etc/vault.d/vault.hcl -skip=storage 2>&1 | tail -30
```

> Do **not** start or initialise any node yet. Keep `vault.service` **disabled and stopped** on all nodes until the rehearsal (§5) or the cutover (§6).

On every node:

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=/opt/vault/tls/ca.pem
```

---

## 5. Phase 4: Rehearsal (MANDATORY because of the version jump)

Run **all of the cutover (§6.2–§6.8)** on the 2.2.1 VMs **without** stopping the OpenShift instance and **without** touching the production downstream Vaults.

- For Path A, take a snapshot while the source is running. For Path B, use a PVC snapshot or clone, or a short maintenance window, to get a consistent copy.
- **Isolate the rehearsal cluster** from the production downstream Vaults. Don't point DNS or the LB at it yet. HashiCorp recommends testing upgrades in a fully isolated network so that the copy can't talk to production.

### 5.1 Upgrade checks on the first unseal

```bash
sudo journalctl -u vault --since "-30min" | grep -iE "error|fail|duplicate|audit|upgrade|migrat" | less
```

- [ ] No `policy contains duplicate attributes` / HCL parse errors
- [ ] No audit device errors
- [ ] No mount or plugin errors (`failed to setup ...`)
- [ ] `vault status`: `Version 2.2.1`, `Sealed false`, `Storage Type raft`

### 5.2 Test the unseal role end to end (the go/no-go gate)

1. **Cross-check a transit key.** Encrypt on the **old** instance:

   ```bash
   # VAULT_ADDR = OpenShift port-forward
   vault write -field=ciphertext transit/encrypt/<key> plaintext=$(echo -n "migration-test" | base64) > ct.txt
   ```

   Decrypt on the **new** 2.2.1 cluster:

   ```bash
   vault write -field=plaintext transit/decrypt/<key> ciphertext=$(cat ct.txt) | base64 -d
   # Expected output: migration-test
   ```

2. **Test with each real downstream token.** This covers the policy parsing on 2.2.1:

   ```bash
   VAULT_TOKEN=<downstream-token> vault token lookup-self
   VAULT_TOKEN=<downstream-token> vault token renew-self   # only if renewable; renewing on the COPY is harmless
   VAULT_TOKEN=<downstream-token> vault write transit/encrypt/<key> plaintext=dGVzdA==
   ```

   If this fails, `vault token lookup-self` shows which policy is attached. Fix that policy **on the source** (§3.3) and run the rehearsal again.

3. **Auto-unseal a downstream clone.** Restore a backup of **one downstream Vault**, **at its current version**, onto a throwaway VM or container. Point its `seal "transit"` at the rehearsal cluster. Start it and check that it auto-unseals. **This is the only test that proves the downstream Vaults will still unseal against 2.2.1.** Repeat it for each distinct downstream Vault version you run.

### 5.3 Wipe after the rehearsal

```bash
# On all 3 VMs
sudo systemctl stop vault
sudo rm -rf /opt/vault/data/*
```

Write down how long each step took. That gives you the real cutover window.

> ✅ **Go/no-go**: go ahead with §6 only if §5.1 and §5.2 pass. Otherwise fix the problem on the source and repeat the rehearsal, or switch to the fallback in §3.5.

---

## 6. Phase 5: Cutover

### 6.1 Before the window

- [ ] Change freeze confirmed (§1)
- [ ] Remediations from §3.2 and §3.3 applied on the source, and the baseline (§2.3) exported again **after** them
- [ ] Unseal key holders **present** (enough for the threshold). They will unseal **3 nodes**.
- [ ] Remaining TTL of each downstream token checked (§2.4)
- [ ] Old instance backed up one extra time, as a PVC snapshot or VolumeSnapshot if your storage class supports it

### 6.2 Take the final backup from OpenShift

#### Path A: the source uses Raft

```bash
# Run against the ACTIVE node (vault status → "HA Mode: active")
oc exec -n $NS ${RELEASE}-0 -- sh -c \
  'VAULT_TOKEN=<token> vault operator raft snapshot save /tmp/vault-unseal.snap'
oc cp $NS/${RELEASE}-0:/tmp/vault-unseal.snap ./vault-unseal.snap
sha256sum vault-unseal.snap
# 1.15.2 has no "snapshot inspect", so check the file with the 2.2.1 CLI on your workstation:
./vault-2.2.1 operator raft snapshot inspect vault-unseal.snap
```

Then **stop the old instance** so that nobody writes to it and there is no split-brain:

```bash
oc scale statefulset/${RELEASE} -n $NS --replicas=0
```

> Scale down only. **Do not** uninstall the release or delete the PVCs. The old 1.15.2 instance is your **only** rollback, because 2.2.1 data can't be downgraded.

#### Path B: the source uses `file` storage

For a consistent copy, the data must be at rest:

```bash
oc scale statefulset/${RELEASE} -n $NS --replicas=0
oc get pvc -n $NS          # usually data-${RELEASE}-0
```

Mount the PVC in a helper pod and copy it out. **Read-only**, so the rollback copy can't change:

```yaml
# pvc-reader.yaml
apiVersion: v1
kind: Pod
metadata:
  name: vault-pvc-reader
spec:
  containers:
    - name: reader
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: data
          mountPath: /vault/data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-<release>-0
        readOnly: true
```

```bash
oc apply -n $NS -f pvc-reader.yaml
oc wait -n $NS --for=condition=Ready pod/vault-pvc-reader
oc exec -n $NS vault-pvc-reader -- tar czf /tmp/vault-data.tgz -C /vault/data .
oc cp $NS/vault-pvc-reader:/tmp/vault-data.tgz ./vault-data.tgz
sha256sum vault-data.tgz
oc delete -n $NS pod/vault-pvc-reader
```

> If `tar` is missing from the image, use `oc rsync vault-pvc-reader:/vault/data ./vault-data` instead.

### 6.3 Move the backup to VM 1

```bash
scp vault-unseal.snap  admin@vault-unseal-1:/tmp/   # Path A
scp vault-data.tgz     admin@vault-unseal-1:/tmp/   # Path B
# On VM 1, check the sha256 again
```

### 6.4 Restore on VM 1 (Vault 2.2.1)

#### Path A: forced Raft snapshot restore

1. Start node 1 and initialise it with **temporary** keys. They only exist to get an unsealed Raft node on which to run the restore.

   ```bash
   sudo systemctl enable --now vault
   vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/temp-init.json
   vault operator unseal $(jq -r '.unseal_keys_b64[0]' /tmp/temp-init.json)
   export VAULT_TOKEN=$(jq -r '.root_token' /tmp/temp-init.json)
   ```

2. Restore the 1.15.2 snapshot. `-force` is required because the snapshot comes from a different cluster with a different keyring.

   ```bash
   vault operator raft snapshot restore -force /tmp/vault-unseal.snap
   ```

3. The node now uses the **original** keyring and data. Check `vault status`. If it shows `Sealed: true`, unseal it with the **ORIGINAL** keys (threshold number of shares):

   ```bash
   vault operator unseal   # original key share 1
   vault operator unseal   # original key share 2
   vault operator unseal   # ... until the threshold is reached
   ```

   2.2.1 upgrades the internal data on this unseal. Watch the logs with `journalctl -u vault -f`.

4. Destroy the temporary material, which is now useless:

   ```bash
   shred -u /tmp/temp-init.json
   export VAULT_TOKEN=<ORIGINAL root/admin token>
   ```

#### Path B: `vault operator migrate` (file → Raft)

```bash
sudo systemctl stop vault                   # must not be running
sudo ls -A /opt/vault/data                  # must be EMPTY
sudo mkdir -p /tmp/vault-migration/data
sudo tar xzf /tmp/vault-data.tgz -C /tmp/vault-migration/data
sudo chown -R vault:vault /tmp/vault-migration
```

`/tmp/vault-migration/migrate.hcl`:

```hcl
storage_source "file" {
  path = "/tmp/vault-migration/data"
}

storage_destination "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-unseal-1"
}

cluster_addr = "https://vault-unseal-1.example.com:8201"
```

```bash
sudo -u vault vault operator migrate -config=/tmp/vault-migration/migrate.hcl
# Expected output ends with: "Success! All of the keys have been migrated."
# (migrate copies the encrypted entries as they are; the version upgrade happens on the first unseal below)

sudo systemctl enable --now vault
vault status                 # Initialized: true, Sealed: true, Storage Type: raft, Version 2.2.1
vault operator unseal        # ORIGINAL keys, repeat until the threshold is reached
export VAULT_TOKEN=<ORIGINAL root/admin token>
```

### 6.5 Check node 1 alone

```bash
vault status                        # Sealed false, Storage raft, HA Mode active, Version 2.2.1
vault operator raft list-peers      # should list ONLY vault-unseal-1
sudo journalctl -u vault --since "-15min" | grep -iE "error|fail|duplicate|audit"
```

If old peers from the OpenShift pods show up (for example `vault-0`, `vault-1` at `*.vault-internal:8201`), remove them:

```bash
vault operator raft remove-peer <old-node-id>
```

### 6.6 Join nodes 2 and 3

On **vault-unseal-2** first, then **vault-unseal-3**. They must run the **same version (2.2.1)**.

```bash
sudo systemctl enable --now vault
# retry_join finds the leader; with Shamir the node must be unsealed to finish joining
vault operator unseal        # ORIGINAL keys, repeat until the threshold is reached
vault status                 # Sealed false, HA Mode standby
```

Back on node 1:

```bash
vault operator raft list-peers
# Expect 3 nodes: 1 leader + 2 followers, all Voter=true
vault operator raft autopilot state   # Healthy: true
```

Optional: make autopilot clean up dead servers automatically:

```bash
vault operator raft autopilot set-config -cleanup-dead-servers=true -dead-server-last-contact-threshold=24h -min-quorum=3
```

### 6.7 Validate the data against the baseline (§2.3)

Run this against `https://vault-unseal.example.com:8200` (through the LB):

```bash
mkdir -p ../after && cd ../after
vault secrets list -detailed -format=json > secrets.json
vault auth list -detailed -format=json    > auth.json
vault policy list               > policies.txt
for p in $(vault policy list); do vault policy read "$p" > "policy_$p.hcl"; done
vault list -format=json transit/keys > transit_keys.json
for k in $(jq -r '.[]' transit_keys.json); do vault read -format=json transit/keys/$k > "transit_key_$k.json"; done
vault list -format=json auth/token/accessors > accessors.json

# Compare mount paths and types (2.x adds new fields to the output, so compare only the stable ones)
diff <(jq -S 'map_values({type, local, seal_wrap})' ../baseline/secrets.json) <(jq -S 'map_values({type, local, seal_wrap})' secrets.json)
diff <(jq -S 'map_values({type, local})' ../baseline/auth.json) <(jq -S 'map_values({type, local})' auth.json)
diff ../baseline/policies.txt policies.txt
for f in ../baseline/policy_*.hcl; do diff "$f" "$(basename $f)"; done
for f in ../baseline/transit_key_*.json; do
  diff <(jq -S '.data | {latest_version, min_decryption_version, keys}' "$f") \
       <(jq -S '.data | {latest_version, min_decryption_version, keys}' "$(basename $f)")
done
diff <(jq -S 'sort' ../baseline/accessors.json) <(jq -S 'sort' accessors.json)
```

The accessor list may differ slightly because of tokens that expired since the baseline and because of your own login. The **downstream token accessors must all be present**.

Checks:

- [ ] Same secret engines, auth methods and policies (with identical content)
- [ ] Same transit keys, `latest_version` and key version timestamps
- [ ] `vault token lookup -accessor <downstream-accessor>` works for **each** downstream token, and its TTL is still positive
- [ ] Encrypt round-trip with **each** downstream token through the LB:

  ```bash
  VAULT_TOKEN=<downstream-token> vault write transit/encrypt/<key> plaintext=dGVzdA==
  ```

- [ ] Re-enable any audit device that you disabled in §3.2, then check that it writes

### 6.8 HA failover test

```bash
# On the current leader
sudo systemctl stop vault
# From another node: a new leader is elected within seconds
vault operator raft list-peers
# The encrypt test through the LB still works
sudo systemctl start vault && vault operator unseal   # original keys (Shamir: manual unseal after every restart)
```

---

## 7. Phase 6: Switch the downstream Vaults to the new cluster

Pick **one** option, based on §2.5.

### Option 1: DNS switch (no downstream config change)

This works if the downstream Vaults use a hostname you control, for example `vault-unseal.example.com`.

1. Lower the DNS TTL beforehand (for example to 60s).
2. Repoint the record to the new LB.
3. The new certificate must include that hostname, and the downstream `tls_ca_cert` must trust its CA.

> The downstream Vaults use an OpenShift Route hostname (`*.apps.<cluster>`)? A specific DNS record for that FQDN overrides the wildcard, so you *can* reuse the name. This couples you to the old cluster domain, though. Prefer Option 2 and move to a neutral name.

### Option 2: update each downstream `seal "transit"` stanza

```hcl
seal "transit" {
  address         = "https://vault-unseal.example.com:8200"
  token           = "<unchanged token>"          # the token was migrated as-is
  key_name        = "<unchanged>"
  mount_path      = "transit/"                   # unchanged
  tls_ca_cert     = "/path/to/new-ca.pem"        # if the CA changed
  tls_server_name = "vault-unseal.example.com"
}
```

> Changing only `address` or the TLS settings **does not need a seal migration**. The key name and mount stay the same, so the ciphertext of the downstream root key stays valid. **Don't change the downstream Vault version at the same time.**

### Rolling restart of each downstream cluster (validates the unseal path)

1. Restart **one standby** node, and check that it **auto-unseals** (`vault status`: `Sealed false`, `Seal Type transit`).
2. Restart the remaining standbys, one at a time.
3. Step down the active node (`vault operator step-down`), then restart it.
4. Check the logs for a clean seal health check and token renewal:

   ```bash
   journalctl -u vault | grep -i -E "seal|transit|renew"
   ```

Do this for each downstream cluster. Start with the least critical one.

---

## 8. Rollback plan

> 🔴 **2.2.1 data can't be downgraded.** Rollback **always** means going back to the **untouched OpenShift 1.15.2 instance**. Never restore a snapshot taken on the new cluster into the old one.

| When | Action |
|---|---|
| Before any downstream change (§6) | Scale the old StatefulSet back up (`oc scale ... --replicas=<n>`), unseal it with the original keys, revert the DNS if it changed. No data is lost, apart from renewals made on the new cluster, which is harmless. |
| After the downstream switch (§7) | Still possible: scale the old one up and unseal it, then revert DNS or the downstream `address` and restart. **This only works while no transit key has been rotated, and no token or policy used by the downstream Vaults has been created or changed, on the new cluster.** Keep the freeze on these for the whole soak period. |

---

## 9. Phase 7: Decommission and hardening

### 9.1 Soak period (for example 2–4 weeks), then decommission

```bash
helm uninstall $RELEASE -n $NS
oc delete pvc -n $NS -l app.kubernetes.io/instance=$RELEASE   # Helm does not delete StatefulSet PVCs
oc delete route <vault-route> -n $NS
```

Archive the final 1.15.2 snapshot or tarball, encrypted and **labelled with its version**, in your backup store.

### 9.2 Hardening

- [ ] **Scheduled Raft snapshots**: CE has no automated snapshot agent, so use a systemd timer or cron on one node with a dedicated periodic token (policy: `read` on `sys/storage/raft/snapshot`):

  ```bash
  vault operator raft snapshot save /backup/vault-unseal-$(date +%F-%H%M)-v2.2.1.snap
  ```

  Ship the snapshots off-host, keep N copies, and **put the Vault version in the file name**. A snapshot should only be restored on the same version or a newer one.
- [ ] **Keep a working admin token.** From 2.0, `generate-root` and `rekey` need a valid token as well as the key shares. Store an admin token with a tightly scoped policy, protected like the unseal keys. Revoke the root token after use (`vault token revoke -self`).
- [ ] Optional **`vault operator rekey`**, to issue fresh unseal key shares to the current custodians. It needs a token and handles a nonce on 2.x. The downstream Vaults are not affected.
- [ ] **Downstream tokens**: make sure they are **periodic, orphan** tokens with a minimal policy **that has no duplicate attributes**:

  ```hcl
  path "transit/encrypt/<key>" { capabilities = ["update"] }
  path "transit/decrypt/<key>" { capabilities = ["update"] }
  ```

- [ ] **Monitoring**:
  - `/v1/sys/health`, per node and through the LB
  - Raft autopilot health
  - certificate expiry
  - alerts on a **sealed** node. With Shamir, every restart or reboot of an unseal-cluster node needs **manual unsealing**, so reboots must follow a runbook.
- [ ] **Future Vault upgrades**:
  - Take a snapshot first, and rehearse on a copy.
  - Upgrade one node at a time (standbys first, then step down the active node).
  - Read the [change tracker](https://developer.hashicorp.com/vault/docs/updates/change-tracker) for every version you skip.
  - Keep the version pinned in the package manager between upgrades.
- [ ] **OS patching**: patch one node at a time, and check `vault operator raft autopilot state` before moving to the next node.
- [ ] **Reconfigure or remove** the Kubernetes auth method (§2.5).
- [ ] Document the new endpoints, the unseal procedure and the key custodians.

---

## Appendix: cutover checklist

```
[ ] Admin/root token available on source (generate-root done on 1.15.2 if needed)
[ ] §3 compatibility checks done; policies / audit devices fixed on source
[ ] Rehearsal on 2.2.1 passed: logs clean, downstream tokens OK, downstream clone auto-unsealed
[ ] Freeze announced (no transit rotate, no downstream restarts, no policy/token changes)
[ ] Unseal key holders available
[ ] Downstream token TTLs OK
[ ] Final snapshot / data copy taken + sha256 verified
[ ] Old StatefulSet scaled to 0 (PVCs kept, untouched = rollback)
[ ] Restore/migrate on node 1 (2.2.1) → unsealed with ORIGINAL keys, logs clean
[ ] Nodes 2 & 3 (2.2.1) joined + unsealed → 3 voters, autopilot healthy
[ ] Baseline diff OK, transit key versions identical, policies identical
[ ] Downstream token lookups OK, encrypt/decrypt OK through LB
[ ] Audit device(s) re-enabled if disabled
[ ] Leader failover test OK
[ ] DNS switched / downstream config updated
[ ] Downstream rolling restarts → all auto-unsealed
[ ] Freeze lifted (except transit rotation / downstream token+policy changes until soak ends)
```

---

## References

- [Upgrade Vault](https://developer.hashicorp.com/vault/docs/upgrade)
- [Change tracker](https://developer.hashicorp.com/vault/docs/updates/change-tracker)
- [Important changes (2.x)](https://developer.hashicorp.com/vault/docs/updates/important-changes)
- [Deprecation notices](https://developer.hashicorp.com/vault/docs/updates/deprecation)
- [Release notes 2.x](https://developer.hashicorp.com/vault/docs/updates/release-notes)
- [Vault CHANGELOG](https://github.com/hashicorp/vault/blob/main/CHANGELOG.md)
- [File audit device](https://developer.hashicorp.com/vault/docs/audit/file)
