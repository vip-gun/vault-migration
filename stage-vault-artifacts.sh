#!/usr/bin/env bash
#
# stage-vault-artifacts.sh
# Run on a machine WITH internet access (ideally a clean RHEL 9 VM of the same minor release
# as the targets). Builds ONE self-contained, verified bundle for the air-gapped RHEL 9 Vault VMs
# (vault-unseal-migration.md, §3.6), including the install/configure scripts to run on the targets.
#
# Usage: ./stage-vault-artifacts.sh [options]
#   -v, --version X.Y.Z      Target Vault version                    (VAULT_VERSION, default 2.2.1)
#   -a, --arch amd64|arm64   Architecture of the target VMs          (ARCH, default amd64)
#   -d, --downstream "V ..." Extra Vault versions for the downstream-clone test (DOWNSTREAM_VERSIONS)
#   -o, --out DIR            Bundle directory                        (OUT_DIR, default ./vault-migration-bundle)
#       --rhel N             RHEL major version for the RPM          (default 9)
#       --no-rpm             Skip the Vault RPM (the zip is always included and is the fallback)
#       --os-packages "..."  RHEL packages to bundle with dependencies
#                            (default: jq unzip tar chrony firewalld python3-dnf-plugin-versionlock)
#       --os-alldeps         Bundle ALL dependencies, not just those missing on this host
#       --no-os-packages     Don't bundle OS packages (the targets have an internal mirror)
#       --with-clients       Also bundle oc, helm and jq binaries (for the admin/jump host)
#       --with-docs          Also save the Vault upgrade docs as HTML
#       --with-image         Also pull + save the hashicorp/vault image (only if you chose containers)
#       --gpg-fpr FPR        Expected HashiCorp signing-key fingerprint (HASHICORP_GPG_FPR);
#                            if omitted you confirm the printed fingerprint interactively
#   -y, --yes                Don't prompt (use together with --gpg-fpr)
#       --generate-only      Only write the install scripts (no downloads); for testing
#   -h, --help
#
# Requires: bash, curl, gpg, tar, unzip, sha256sum. Optional: dnf (OS packages), rpm, docker/podman.

set -euo pipefail

VAULT_VERSION="${VAULT_VERSION:-2.2.1}"
ARCH="${ARCH:-amd64}"
DOWNSTREAM_VERSIONS="${DOWNSTREAM_VERSIONS:-}"
OUT_DIR="${OUT_DIR:-./vault-migration-bundle}"
HASHICORP_GPG_FPR="${HASHICORP_GPG_FPR:-}"
RHEL_MAJOR="9"
WITH_RPM=1
OS_PACKAGES="jq unzip tar chrony firewalld python3-dnf-plugin-versionlock"
WITH_OS=1
OS_ALLDEPS=0
WITH_CLIENTS=0
WITH_DOCS=0
WITH_IMAGE=0
ASSUME_YES=0
GEN_ONLY=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)    VAULT_VERSION="$2"; shift 2 ;;
    -a|--arch)       ARCH="$2"; shift 2 ;;
    -d|--downstream) DOWNSTREAM_VERSIONS="$2"; shift 2 ;;
    -o|--out)        OUT_DIR="$2"; shift 2 ;;
    --rhel)          RHEL_MAJOR="$2"; shift 2 ;;
    --no-rpm)        WITH_RPM=0; shift ;;
    --os-packages)   OS_PACKAGES="$2"; shift 2 ;;
    --os-alldeps)    OS_ALLDEPS=1; shift ;;
    --no-os-packages) WITH_OS=0; shift ;;
    --with-clients)  WITH_CLIENTS=1; shift ;;
    --with-docs)     WITH_DOCS=1; shift ;;
    --with-image)    WITH_IMAGE=1; shift ;;
    --gpg-fpr)       HASHICORP_GPG_FPR="$2"; shift 2 ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    --generate-only) GEN_ONLY=1; shift ;;
    -h|--help)       usage 0 ;;
    *) warn "Unknown option: $1"; usage 1 ;;
  esac
done

[[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || die "ARCH must be amd64 or arm64"
[[ "$VAULT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Bad version: $VAULT_VERSION"
for dv in $DOWNSTREAM_VERSIONS; do [[ "$dv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Bad downstream version: $dv"; done
if [[ $GEN_ONLY -eq 0 ]]; then
  for tool in curl gpg tar unzip; do command -v "$tool" >/dev/null || die "Missing required tool: $tool"; done
fi
if command -v sha256sum >/dev/null; then SHA256="sha256sum"
elif command -v shasum >/dev/null; then SHA256="shasum -a 256"
else die "Need sha256sum or shasum"; fi

RPM_ARCH="x86_64"; [[ "$ARCH" == "arm64" ]] && RPM_ARCH="aarch64"
BASE_URL="https://releases.hashicorp.com/vault"
KEY_URL="https://www.hashicorp.com/.well-known/pgp-key.txt"
RPM_FILE="vault-${VAULT_VERSION}-1.${RPM_ARCH}.rpm"

mkdir -p "$OUT_DIR"/{vault,keys,rpm,os-packages,clients,docs,images,install,config}
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"

dl() { curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 -o "$2" "$1"; }

###############################################################################
# PART 1: DOWNLOADS
###############################################################################
if [[ $GEN_ONLY -eq 0 ]]; then

# --- 1. HashiCorp signing key ---
log "Fetching HashiCorp release-signing key"
dl "$KEY_URL" "$OUT_DIR/keys/hashicorp.asc"
gpg --batch --quiet --import "$OUT_DIR/keys/hashicorp.asc"
FPRS="$(gpg --batch --with-colons --fingerprint | awk -F: '$1=="fpr"{print $10}')"
echo "Key fingerprint(s) in the downloaded file:"; echo "$FPRS" | sed 's/^/    /'
if [[ -n "$HASHICORP_GPG_FPR" ]]; then
  want="$(echo "$HASHICORP_GPG_FPR" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  echo "$FPRS" | grep -qx "$want" || die "Fingerprint mismatch. Expected $want"
  log "Fingerprint matches the one you supplied"
elif [[ $ASSUME_YES -eq 0 ]]; then
  echo "Compare with https://www.hashicorp.com/security (through a trusted channel)."
  read -r -p "Does it match? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted: key not confirmed"
else
  warn "Proceeding without an independent fingerprint check (--yes without --gpg-fpr)"
fi

# --- 2. Vault zips: target + downstream versions ---
fetch_vault() {
  local v="$1" d="$OUT_DIR/vault/$1"
  mkdir -p "$d"
  log "Vault $v (linux_$ARCH)"
  dl "$BASE_URL/$v/vault_${v}_linux_${ARCH}.zip" "$d/vault_${v}_linux_${ARCH}.zip"
  dl "$BASE_URL/$v/vault_${v}_SHA256SUMS"        "$d/vault_${v}_SHA256SUMS"
  dl "$BASE_URL/$v/vault_${v}_SHA256SUMS.sig"    "$d/vault_${v}_SHA256SUMS.sig"
  gpg --batch --verify "$d/vault_${v}_SHA256SUMS.sig" "$d/vault_${v}_SHA256SUMS" 2>&1 | sed 's/^/    /'
  ( cd "$d" && grep " vault_${v}_linux_${ARCH}.zip\$" "vault_${v}_SHA256SUMS" | $SHA256 -c - )
}
fetch_vault "$VAULT_VERSION"
for dv in $DOWNSTREAM_VERSIONS; do fetch_vault "$dv"; done

# --- 3. Vault RPM for RHEL ---
if [[ $WITH_RPM -eq 1 ]]; then
  url="https://rpm.releases.hashicorp.com/RHEL/${RHEL_MAJOR}/${RPM_ARCH}/stable/${RPM_FILE}"
  log "Vault RPM: $url"
  if dl "$url" "$OUT_DIR/rpm/$RPM_FILE"; then
    dl "https://rpm.releases.hashicorp.com/gpg" "$OUT_DIR/keys/hashicorp-rpm.gpg" || warn "Could not fetch the RPM repo key"
    if command -v rpm >/dev/null && [[ -f "$OUT_DIR/keys/hashicorp-rpm.gpg" ]]; then
      rpmdb="$(mktemp -d)"
      rpm --dbpath "$rpmdb" --import "$OUT_DIR/keys/hashicorp-rpm.gpg"
      rpm --dbpath "$rpmdb" -K "$OUT_DIR/rpm/$RPM_FILE" | sed 's/^/    /'
      rpm --dbpath "$rpmdb" -K "$OUT_DIR/rpm/$RPM_FILE" | grep -qiE "digests signatures OK|pgp.*OK" \
        || die "RPM signature check FAILED"
      rm -rf "$rpmdb"
    else
      warn "rpm not available here: the signature is checked again on the target (20-install-vault.sh)"
    fi
  else
    warn "RPM not found at that URL. The target will fall back to the zip."
    rm -f "$OUT_DIR/rpm/$RPM_FILE"
  fi
fi

# --- 4. OS packages with dependencies (RHEL host with dnf + entitlement/mirror) ---
if [[ $WITH_OS -eq 1 ]]; then
  if command -v dnf >/dev/null && dnf download --help >/dev/null 2>&1; then
    log "Downloading OS packages: $OS_PACKAGES"
    flags=(--resolve --destdir "$OUT_DIR/os-packages" --arch "${RPM_ARCH},noarch")
    [[ $OS_ALLDEPS -eq 1 ]] && flags+=(--alldeps)
    # shellcheck disable=SC2086
    dnf download "${flags[@]}" $OS_PACKAGES \
      || warn "dnf download failed. Check the repo entitlement, or use --no-os-packages and your internal mirror."
    log "$(find "$OUT_DIR/os-packages" -name '*.rpm' | wc -l) OS RPMs downloaded"
  else
    warn "dnf (with the download plugin: dnf-plugins-core) not found here, so OS packages are NOT bundled."
    warn "Run this script on a RHEL 9 host, or use your internal mirror on the targets."
  fi
fi

# --- 5. Optional: oc, helm, jq binaries ---
if [[ $WITH_CLIENTS -eq 1 ]]; then
  log "oc (stable channel; match your cluster version manually if it differs)"
  oc_dir=x86_64; oc_sfx=""; [[ "$ARCH" == "arm64" ]] && { oc_dir=aarch64; oc_sfx="-arm64"; }
  dl "https://mirror.openshift.com/pub/openshift-v4/${oc_dir}/clients/ocp/stable/openshift-client-linux${oc_sfx}.tar.gz" \
     "$OUT_DIR/clients/openshift-client-linux.tar.gz" || warn "oc download failed"
  log "helm"
  HELM_VER="$(curl -fsSL https://get.helm.sh/helm-latest-version 2>/dev/null || true)"
  if [[ -n "$HELM_VER" ]]; then
    dl "https://get.helm.sh/helm-${HELM_VER}-linux-${ARCH}.tar.gz"            "$OUT_DIR/clients/helm-linux-${ARCH}.tar.gz"
    dl "https://get.helm.sh/helm-${HELM_VER}-linux-${ARCH}.tar.gz.sha256sum"  "$OUT_DIR/clients/helm.sha256sum"
    ( cd "$OUT_DIR/clients" && echo "$(cut -d' ' -f1 helm.sha256sum)  helm-linux-${ARCH}.tar.gz" | $SHA256 -c - )
    rm -f "$OUT_DIR/clients/helm.sha256sum"
  else
    warn "Could not determine the latest helm version"
  fi
  log "jq"
  JQ_VER="1.7.1"
  dl "https://github.com/jqlang/jq/releases/download/jq-${JQ_VER}/jq-linux-${ARCH}" "$OUT_DIR/clients/jq-linux-${ARCH}" \
    && dl "https://github.com/jqlang/jq/releases/download/jq-${JQ_VER}/sha256sum.txt" "$OUT_DIR/clients/jq.sha256sum" \
    && ( cd "$OUT_DIR/clients" && grep " jq-linux-${ARCH}\$" jq.sha256sum | $SHA256 -c - ) \
    || warn "jq download/verification failed"
  rm -f "$OUT_DIR/clients/jq.sha256sum"
fi

# --- 6. Optional: docs ---
if [[ $WITH_DOCS -eq 1 ]]; then
  log "Saving upgrade docs"
  for page in updates/change-tracker updates/important-changes updates/deprecation updates/release-notes upgrade; do
    dl "https://developer.hashicorp.com/vault/docs/$page" "$OUT_DIR/docs/$(echo "$page" | tr '/' '_').html" || warn "Could not save $page"
  done
  dl "https://raw.githubusercontent.com/hashicorp/vault/main/CHANGELOG.md" "$OUT_DIR/docs/CHANGELOG.md" || warn "Could not save CHANGELOG.md"
  warn "HashiCorp doc pages are JavaScript-heavy: check the saved HTML is readable, or print them to PDF."
fi

# --- 7. Optional: container images ---
if [[ $WITH_IMAGE -eq 1 ]]; then
  CTR="$(command -v podman || command -v docker || true)"
  [[ -n "$CTR" ]] || die "--with-image needs podman or docker"
  for v in "$VAULT_VERSION" $DOWNSTREAM_VERSIONS; do
    img="docker.io/hashicorp/vault:${v}"
    log "Pulling $img"
    "$CTR" pull --platform "linux/${ARCH}" "$img"
    "$CTR" image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null | sed 's/^/    digest: /' || true
    "$CTR" save -o "$OUT_DIR/images/vault-${v}-${ARCH}.tar" "$img"
  done
fi

fi  # end downloads

###############################################################################
# PART 2: INSTALL SCRIPTS AND CONFIG (written into the bundle, run on the targets)
###############################################################################
log "Writing install scripts"

cat > "$OUT_DIR/install/versions.env" <<EOF
VAULT_VERSION="$VAULT_VERSION"
ARCH="$ARCH"
RPM_ARCH="$RPM_ARCH"
RPM_FILE="$RPM_FILE"
DOWNSTREAM_VERSIONS="$DOWNSTREAM_VERSIONS"
OS_PACKAGES="$OS_PACKAGES"
EOF

# ---- shared helpers ----
cat > "$OUT_DIR/install/lib.sh" <<'EOF'
# Sourced by the install scripts. Do not run directly.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
BUNDLE_DIR="$(cd "$INSTALL_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$INSTALL_DIR/versions.env"
log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
check_rhel9() {
  . /etc/os-release
  [[ "${VERSION_ID%%.*}" == "9" ]] || warn "This bundle targets RHEL 9; found ${PRETTY_NAME:-unknown}."
}
EOF

# ---- 00 verify ----
cat > "$OUT_DIR/install/00-verify-bundle.sh" <<'EOF'
#!/usr/bin/env bash
# Verify the bundle integrity (manifest) and the HashiCorp signatures of the Vault zips.
# Run from the unpacked bundle. Does not need root.
source "$(dirname "$0")/lib.sh"
cd "$BUNDLE_DIR"
log "Checking MANIFEST.sha256"
sha256sum -c MANIFEST.sha256 --quiet && log "All files match the manifest"

log "Verifying HashiCorp signatures (SHA256SUMS.sig) with the bundled key"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; trap 'rm -rf "$GNUPGHOME"' EXIT; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import keys/hashicorp.asc
gpg --batch --with-colons --fingerprint | awk -F: '$1=="fpr"{print "    key fingerprint: "$10}'
for d in vault/*/; do
  v="$(basename "$d")"
  gpg --batch --verify "$d/vault_${v}_SHA256SUMS.sig" "$d/vault_${v}_SHA256SUMS" 2>&1 | sed 's/^/    /'
  ( cd "$d" && grep " vault_${v}_linux_${ARCH}.zip\$" "vault_${v}_SHA256SUMS" | sha256sum -c - )
done
log "Bundle OK. Compare the fingerprint above with the one you confirmed when you built the bundle."
EOF

# ---- 10 OS packages ----
cat > "$OUT_DIR/install/10-install-os-packages.sh" <<'EOF'
#!/usr/bin/env bash
# Install the bundled OS packages (jq, unzip, tar, chrony, firewalld, versionlock plugin) with NO repos.
# Skip this script if the node already has these packages from an internal mirror.
source "$(dirname "$0")/lib.sh"
need_root; check_rhel9
shopt -s nullglob
rpms=("$BUNDLE_DIR"/os-packages/*.rpm)
if [[ ${#rpms[@]} -eq 0 ]]; then
  warn "No RPMs in os-packages/. Install these from your internal mirror: $OS_PACKAGES"
  exit 0
fi
log "Installing ${#rpms[@]} RPMs from the bundle (repos disabled)"
dnf install -y --disablerepo='*' --setopt=install_weak_deps=False "${rpms[@]}"
EOF

# ---- 20 Vault ----
cat > "$OUT_DIR/install/20-install-vault.sh" <<'EOF'
#!/usr/bin/env bash
# Install Vault (pinned) from the bundle: RPM if present (preferred), otherwise the signed zip.
# Leaves the service DISABLED and STOPPED (the migration plan starts it only at rehearsal/cutover).
source "$(dirname "$0")/lib.sh"
need_root; check_rhel9

if [[ -f "$BUNDLE_DIR/rpm/$RPM_FILE" ]]; then
  log "Installing $RPM_FILE"
  rpm --import "$BUNDLE_DIR/keys/hashicorp-rpm.gpg"
  rpm -K "$BUNDLE_DIR/rpm/$RPM_FILE"
  dnf install -y --disablerepo='*' "$BUNDLE_DIR/rpm/$RPM_FILE"
  if rpm -q python3-dnf-plugin-versionlock >/dev/null 2>&1; then
    dnf versionlock add vault && log "Version locked"
  else
    warn "python3-dnf-plugin-versionlock missing: pin the version another way (e.g. exclude=vault in dnf.conf)"
  fi
else
  warn "No RPM in the bundle: installing the zip binary"
  zip="$BUNDLE_DIR/vault/$VAULT_VERSION/vault_${VAULT_VERSION}_linux_${ARCH}.zip"
  [[ -f "$zip" ]] || die "Missing $zip"
  unzip -o -q "$zip" -d /usr/local/bin vault
  chmod 755 /usr/local/bin/vault
  id vault >/dev/null 2>&1 || useradd --system --home /opt/vault --shell /usr/sbin/nologin vault
  install -d -o vault -g vault -m 750 /opt/vault /opt/vault/data
  install -d -o root  -g vault -m 750 /etc/vault.d
  cat > /etc/systemd/system/vault.service <<'UNIT'
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
UNIT
  systemctl daemon-reload
fi

install -d -o vault -g vault -m 750 /opt/vault/tls /opt/vault/data
systemctl disable --now vault 2>/dev/null || true

got="$(vault version)"; echo "    $got"
[[ "$got" == "Vault v${VAULT_VERSION}"* ]] || die "Installed version is not $VAULT_VERSION"
log "Vault $VAULT_VERSION installed; service left disabled and stopped"
echo "Next: copy vault.crt, vault.key, ca.pem to /opt/vault/tls (owner vault, key mode 640), then run 30-configure-node.sh"
EOF

# ---- 30 configure ----
cat > "$OUT_DIR/config/vault.hcl.tpl" <<'EOF'
ui            = true
disable_mlock = true            # MANDATORY with Integrated Storage since Vault 1.20
cluster_name  = "vault-unseal"

# Only if you kept a file audit device with a "prefix" option (see §3.2):
# allow_audit_log_prefixing = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "@PREFIX@-@NODE@"

  retry_join {
    leader_api_addr     = "https://@PREFIX@-1.@DOMAIN@:8200"
    leader_ca_cert_file = "/opt/vault/tls/ca.pem"
  }
  retry_join {
    leader_api_addr     = "https://@PREFIX@-2.@DOMAIN@:8200"
    leader_ca_cert_file = "/opt/vault/tls/ca.pem"
  }
  retry_join {
    leader_api_addr     = "https://@PREFIX@-3.@DOMAIN@:8200"
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

api_addr     = "https://@PREFIX@-@NODE@.@DOMAIN@:8200"
cluster_addr = "https://@PREFIX@-@NODE@.@DOMAIN@:8201"

# Only if the source uses a KMS auto-unseal: copy its seal "..." stanza here unchanged.
# Only if custom plugins exist:
# plugin_directory = "/etc/vault.d/plugins"
EOF

cat > "$OUT_DIR/install/30-configure-node.sh" <<'EOF'
#!/usr/bin/env bash
# Render /etc/vault.d/vault.hcl for this node and run `vault operator diagnose`.
# Usage: 30-configure-node.sh --node 1|2|3 --domain example.com [--prefix vault-unseal]
source "$(dirname "$0")/lib.sh"
need_root
NODE=""; DOMAIN=""; PREFIX="vault-unseal"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    *) die "Unknown option $1" ;;
  esac
done
[[ "$NODE" =~ ^[123]$ ]] || die "--node must be 1, 2 or 3"
[[ -n "$DOMAIN" ]] || die "--domain is required"
for f in vault.crt vault.key ca.pem; do [[ -f /opt/vault/tls/$f ]] || die "Missing /opt/vault/tls/$f"; done
chown vault:vault /opt/vault/tls/*; chmod 640 /opt/vault/tls/vault.key

install -d -o root -g vault -m 750 /etc/vault.d
[[ -f /etc/vault.d/vault.hcl ]] && cp -p /etc/vault.d/vault.hcl "/etc/vault.d/vault.hcl.bak.$(date +%s)"
sed -e "s/@PREFIX@/$PREFIX/g" -e "s/@NODE@/$NODE/g" -e "s/@DOMAIN@/$DOMAIN/g" \
  "$BUNDLE_DIR/config/vault.hcl.tpl" > /etc/vault.d/vault.hcl
chown root:vault /etc/vault.d/vault.hcl; chmod 640 /etc/vault.d/vault.hcl

# If a file audit device stays enabled (see §3.2), create its directory:
install -d -o vault -g vault -m 750 /vault/audit

log "Running vault operator diagnose (duplicate keys are a hard error on 2.x)"
sudo -u vault vault operator diagnose -config=/etc/vault.d/vault.hcl -skip=storage 2>&1 | tail -30
log "Config written. Do NOT start Vault yet; follow the rehearsal / cutover sections of the plan."
EOF

# ---- 40 host prep ----
cat > "$OUT_DIR/install/40-host-prep.sh" <<'EOF'
#!/usr/bin/env bash
# RHEL 9 host prep: firewall ports, chrony, swap check, SELinux status.
# Usage: 40-host-prep.sh [--ntp-server ntp.example.com]
source "$(dirname "$0")/lib.sh"
need_root; check_rhel9
NTP=""
[[ "${1:-}" == "--ntp-server" ]] && NTP="${2:-}"

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=8200/tcp --add-port=8201/tcp
  firewall-cmd --reload
  log "firewalld: 8200/tcp and 8201/tcp opened (restrict 8201 to the peer nodes with a rich rule if you can)"
else
  warn "firewalld is not running: open 8200/tcp and 8201/tcp in whatever firewall you use"
fi

if [[ -n "$NTP" ]]; then
  sed -i '/^pool /d;/^server /d' /etc/chrony.conf
  echo "server $NTP iburst" >> /etc/chrony.conf
fi
systemctl enable --now chronyd && chronyc tracking | sed 's/^/    /' || warn "chronyd not available"

if [[ -n "$(swapon --show --noheadings)" ]]; then
  warn "Swap is enabled. Vault runs with disable_mlock=true, so disable swap or use encrypted swap."
fi
echo "    SELinux: $(getenforce 2>/dev/null || echo unknown). After the first start, check: ausearch -m avc -ts recent"
EOF

# ---- 50 downstream versions ----
cat > "$OUT_DIR/install/50-install-downstream-versions.sh" <<'EOF'
#!/usr/bin/env bash
# Unpack the Vault binaries of the DOWNSTREAM versions into /opt/vault-downstream/<version>/vault
# for the rehearsal's downstream-clone test (§5.2). Run on a throwaway/rehearsal VM, not on the production nodes.
source "$(dirname "$0")/lib.sh"
need_root
[[ -n "$DOWNSTREAM_VERSIONS" ]] || { warn "No downstream versions were staged (-d)."; exit 0; }
for v in $DOWNSTREAM_VERSIONS; do
  d="/opt/vault-downstream/$v"
  install -d -m 755 "$d"
  unzip -o -q "$BUNDLE_DIR/vault/$v/vault_${v}_linux_${ARCH}.zip" -d "$d"
  echo "    $("$d/vault" version)  ->  $d/vault"
done
log "Run a clone with e.g.: /opt/vault-downstream/<version>/vault server -config=<clone.hcl>  (seal \"transit\" -> rehearsal cluster)"
EOF

# ---- 60 clients ----
cat > "$OUT_DIR/install/60-install-clients.sh" <<'EOF'
#!/usr/bin/env bash
# Install oc, helm and jq into /usr/local/bin (for the ADMIN / JUMP host that talks to OpenShift).
source "$(dirname "$0")/lib.sh"
need_root
shopt -s nullglob
c="$BUNDLE_DIR/clients"
if [[ -f "$c/openshift-client-linux.tar.gz" ]]; then tar xzf "$c/openshift-client-linux.tar.gz" -C /usr/local/bin oc kubectl; fi
for t in "$c"/helm-linux-*.tar.gz; do tar xzf "$t" -C /usr/local/bin --strip-components=1 "linux-${ARCH}/helm"; done
for j in "$c"/jq-linux-*; do install -m 755 "$j" /usr/local/bin/jq; done
for b in oc helm jq; do command -v $b >/dev/null && echo "    $b: $($b version --client 2>/dev/null | head -1 || $b --version)" || warn "$b not installed"; done
EOF

# ---- 65 images ----
cat > "$OUT_DIR/install/65-load-images.sh" <<'EOF'
#!/usr/bin/env bash
# Load saved container images (only exists in the bundle if built with --with-image).
# The default plan runs Vault natively, so this normally does nothing.
source "$(dirname "$0")/lib.sh"
need_root
shopt -s nullglob
imgs=("$BUNDLE_DIR"/images/*.tar)
[[ ${#imgs[@]} -gt 0 ]] || { log "No images in the bundle (native install). Nothing to do."; exit 0; }
CTR="$(command -v podman || command -v docker || true)"
[[ -n "$CTR" ]] || die "podman or docker is needed to load images (dnf install podman from your mirror)"
for i in "${imgs[@]}"; do log "Loading $i"; "$CTR" load -i "$i"; done
EOF

# ---- 70 snapshot timer ----
cat > "$OUT_DIR/install/70-install-snapshot-timer.sh" <<'EOF'
#!/usr/bin/env bash
# Scheduled Raft snapshots (plan §9.2): systemd timer + script. Run on ONE node after the cluster is healthy.
# Put a periodic token (policy: read on sys/storage/raft/snapshot) in /etc/vault.d/snapshot.token (mode 600).
# Usage: 70-install-snapshot-timer.sh [--dir /backup/vault] [--keep 14] [--schedule daily]
source "$(dirname "$0")/lib.sh"
need_root
DIR=/backup/vault; KEEP=14; SCHEDULE=daily
while [[ $# -gt 0 ]]; do
  case "$1" in --dir) DIR="$2"; shift 2;; --keep) KEEP="$2"; shift 2;; --schedule) SCHEDULE="$2"; shift 2;; *) die "Unknown option $1";; esac
done
install -d -o vault -g vault -m 700 "$DIR"

cat > /usr/local/sbin/vault-raft-snapshot.sh <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
export VAULT_ADDR="\${VAULT_ADDR:-https://127.0.0.1:8200}"
export VAULT_CACERT="\${VAULT_CACERT:-/opt/vault/tls/ca.pem}"
export VAULT_TOKEN="\$(cat /etc/vault.d/snapshot.token)"
ver="\$(vault version | awk '{print \$2}')"          # e.g. v${VAULT_VERSION}
out="$DIR/vault-unseal-\$(date +%F-%H%M)-\${ver}.snap"
vault operator raft snapshot save "\$out"
sha256sum "\$out" > "\$out.sha256"
ls -1t $DIR/*.snap | tail -n +$((KEEP+1)) | xargs -r -I{} sh -c 'rm -f "{}" "{}.sha256"'
SCRIPT
chmod 750 /usr/local/sbin/vault-raft-snapshot.sh; chown root:vault /usr/local/sbin/vault-raft-snapshot.sh

cat > /etc/systemd/system/vault-raft-snapshot.service <<UNIT
[Unit]
Description=Vault Raft snapshot
[Service]
Type=oneshot
User=vault
ExecStart=/usr/local/sbin/vault-raft-snapshot.sh
UNIT
cat > /etc/systemd/system/vault-raft-snapshot.timer <<UNIT
[Unit]
Description=Vault Raft snapshot schedule
[Timer]
OnCalendar=$SCHEDULE
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
if [[ -f /etc/vault.d/snapshot.token ]]; then
  chown vault:vault /etc/vault.d/snapshot.token; chmod 600 /etc/vault.d/snapshot.token
  systemctl enable --now vault-raft-snapshot.timer
else
  warn "Create /etc/vault.d/snapshot.token, then: systemctl enable --now vault-raft-snapshot.timer"
fi
warn "Ship the snapshots off-host ($DIR); a snapshot should only be restored on the same or a newer Vault version."
EOF

# ---- README ----
cat > "$OUT_DIR/README.txt" <<EOF
Vault $VAULT_VERSION air-gapped install bundle (RHEL $RHEL_MAJOR, $ARCH)
================================================================
Built: $(date -u +%FT%TZ)    Plan: vault-unseal-migration.md (§3.6, §4)

Unpack, then on EACH target VM (as root unless noted):

  install/00-verify-bundle.sh            (no root) manifest + HashiCorp signature check
  install/10-install-os-packages.sh      jq, unzip, chrony, firewalld ... (skip if you have an internal mirror)
  install/20-install-vault.sh            Vault $VAULT_VERSION, pinned, service left stopped
  (copy vault.crt, vault.key, ca.pem into /opt/vault/tls)
  install/30-configure-node.sh --node N --domain example.com
  install/40-host-prep.sh [--ntp-server HOST]

Extra, where needed in the migration:
  install/50-install-downstream-versions.sh   rehearsal VM: downstream Vault binaries (§5.2)
  install/60-install-clients.sh               admin/jump host: oc, helm, jq (§2, §6.2)
  install/65-load-images.sh                   only if built with --with-image
  install/70-install-snapshot-timer.sh        after cutover, on one node (§9.2)

Workstation CLI for 'policy fmt' / 'snapshot inspect': unzip vault/$VAULT_VERSION/vault_${VAULT_VERSION}_linux_${ARCH}.zip
Nothing here starts Vault. Starting, unsealing and restoring follow the plan (§5, §6).
EOF

chmod +x "$OUT_DIR"/install/*.sh

if [[ $GEN_ONLY -eq 1 ]]; then
  log "Generated install scripts only (--generate-only) in $OUT_DIR"
  exit 0
fi

###############################################################################
# PART 3: MANIFEST + BUNDLE
###############################################################################
rmdir "$OUT_DIR"/{rpm,os-packages,clients,docs,images} 2>/dev/null || true
log "Writing manifest"
( cd "$OUT_DIR" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 $SHA256 > MANIFEST.sha256 )

BUNDLE="$(dirname "$OUT_DIR")/$(basename "$OUT_DIR")-vault-${VAULT_VERSION}-rhel${RHEL_MAJOR}-${ARCH}.tar.gz"
log "Creating $BUNDLE"
tar -C "$(dirname "$OUT_DIR")" -czf "$BUNDLE" "$(basename "$OUT_DIR")"
$SHA256 "$BUNDLE" | tee "${BUNDLE}.sha256"

cat <<EOF

Done.
  Bundle:   $BUNDLE   (copy this to each target VM)
  Checksum: ${BUNDLE}.sha256   (send it by a different path than the bundle)

On each air-gapped RHEL $RHEL_MAJOR VM:
  sha256sum -c $(basename "$BUNDLE").sha256
  tar xzf $(basename "$BUNDLE") && cd $(basename "$OUT_DIR")
  cat README.txt
EOF
