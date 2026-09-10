#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

K8S_VERSION="v1.37"
CNI_VERSION="v1.9.1"

USER_CONFIG=""
SKIP_CNI=false

CONTAINERD_CONFIG="/etc/containerd/config.toml"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --k8s-version <vX.Y>      Kubernetes minor version
                            Default: ${K8S_VERSION}

  --cni-version <vX.Y.Z>    CNI plugins version
                            Default: ${CNI_VERSION}

  --config <path>           Custom containerd config.toml

  --skip-cni                Skip installation of CNI plugin binaries

  -h, --help                Show this help
EOF
}

require_value() {
  local option="$1"
  local value="${2-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for ${option}" >&2
    exit 1
  fi
}

cleanup() {
  rm -rf "${TMP_DIR:-}"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this script as root or with sudo." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script requires an apt-based Linux distribution." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --k8s-version)
      require_value "$1" "${2-}"
      K8S_VERSION="$2"
      shift 2
      ;;

    --cni-version)
      require_value "$1" "${2-}"
      CNI_VERSION="$2"
      shift 2
      ;;

    --config)
      require_value "$1" "${2-}"
      USER_CONFIG="$2"
      shift 2
      ;;

    --skip-cni)
      SKIP_CNI=true
      shift
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    *)
      echo "Unknown option: $1" >&2
      echo
      usage >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Validate arguments
# -----------------------------------------------------------------------------

if [[ ! "$K8S_VERSION" =~ ^v[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid Kubernetes version: ${K8S_VERSION}" >&2
  echo "Expected format: v1.37" >&2
  exit 1
fi

if [[ ! "$CNI_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid CNI version: ${CNI_VERSION}" >&2
  echo "Expected format: v1.9.1" >&2
  exit 1
fi

if [[ -n "$USER_CONFIG" && ! -f "$USER_CONFIG" ]]; then
  echo "Containerd config not found: ${USER_CONFIG}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Architecture
# -----------------------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
  amd64)
    CNI_ARCH="amd64"
    ;;

  arm64)
    CNI_ARCH="arm64"
    ;;

  armhf)
    CNI_ARCH="arm"
    ;;

  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

K8S_URL="https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb"

TMP_DIR="$(mktemp -d)"
trap cleanup EXIT

echo "============================================================"
echo " Kubernetes node bootstrap"
echo "============================================================"
echo "Kubernetes: ${K8S_VERSION}"
echo "CNI:        ${CNI_VERSION}"
echo "Arch:       ${ARCH}"
echo

# -----------------------------------------------------------------------------
# Base dependencies
# -----------------------------------------------------------------------------

echo "==> Installing base dependencies"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  gpg \
  containerd

# -----------------------------------------------------------------------------
# Kernel modules
# -----------------------------------------------------------------------------

echo "==> Configuring kernel modules"

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# -----------------------------------------------------------------------------
# sysctl
# -----------------------------------------------------------------------------

echo "==> Configuring sysctl"

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null

# -----------------------------------------------------------------------------
# Swap
# -----------------------------------------------------------------------------

echo "==> Disabling swap"

swapoff -a

if [[ ! -f /etc/fstab.k8s-bash.bak ]]; then
  cp -a /etc/fstab /etc/fstab.k8s-bash.bak
fi

sed -ri \
  '/[[:space:]]swap[[:space:]]/ s/^#?/#/' \
  /etc/fstab

# -----------------------------------------------------------------------------
# containerd
# -----------------------------------------------------------------------------

echo "==> Configuring containerd"

install -d -m 0755 /etc/containerd

if [[ -n "$USER_CONFIG" ]]; then
  echo "Using custom containerd config: ${USER_CONFIG}"

  SOURCE_CONFIG="$(readlink -f "$USER_CONFIG")"
  TARGET_CONFIG="$(readlink -f "$CONTAINERD_CONFIG" 2>/dev/null || true)"

  if [[ "$SOURCE_CONFIG" != "$TARGET_CONFIG" ]]; then
    install -m 0644 \
      "$USER_CONFIG" \
      "$CONTAINERD_CONFIG"
  fi

elif [[ ! -s "$CONTAINERD_CONFIG" ]]; then
  echo "Generating default containerd config"

  containerd config default > "$CONTAINERD_CONFIG"

else
  echo "Existing containerd config found"
fi

# CRI must not be disabled.
if grep -Eq \
  'disabled_plugins[[:space:]]*=.*"cri"' \
  "$CONTAINERD_CONFIG"
then
  echo "containerd CRI plugin is disabled." >&2

  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo "This node already appears to be part of a Kubernetes cluster." >&2
    echo "Refusing to replace containerd config automatically." >&2
    exit 1
  fi

  echo "Backing up old config and generating a clean one"

  cp -a \
    "$CONTAINERD_CONFIG" \
    "${CONTAINERD_CONFIG}.bak"

  containerd config default > "$CONTAINERD_CONFIG"
fi

# Kubernetes should use systemd cgroups.
if grep -Eq \
  '^[[:space:]]*SystemdCgroup[[:space:]]*=[[:space:]]*false' \
  "$CONTAINERD_CONFIG"
then
  sed -ri \
    's/^([[:space:]]*SystemdCgroup[[:space:]]*=[[:space:]]*)false/\1true/' \
    "$CONTAINERD_CONFIG"
fi

if ! grep -Eq \
  '^[[:space:]]*SystemdCgroup[[:space:]]*=[[:space:]]*true' \
  "$CONTAINERD_CONFIG"
then
  echo "Could not configure SystemdCgroup=true." >&2
  echo "Config: ${CONTAINERD_CONFIG}" >&2
  exit 1
fi

echo "Validating containerd config"

containerd config dump >/dev/null

systemctl enable --now containerd
systemctl restart containerd

# -----------------------------------------------------------------------------
# CNI plugin binaries
# -----------------------------------------------------------------------------

if [[ "$SKIP_CNI" == false ]]; then
  echo "==> Installing CNI plugins"

  CNI_ARCHIVE="cni-plugins-linux-${CNI_ARCH}-${CNI_VERSION}.tgz"

  CNI_BASE_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}"

  CNI_VERSION_FILE="/opt/cni/bin/.k8s-bash-cni-version"

  if [[ -f "$CNI_VERSION_FILE" ]] \
    && [[ "$(cat "$CNI_VERSION_FILE")" == "${CNI_VERSION}/${CNI_ARCH}" ]]
  then
    echo "CNI plugins ${CNI_VERSION} (${CNI_ARCH}) already installed"

  else
    curl \
      -fL \
      --retry 3 \
      --retry-delay 2 \
      "${CNI_BASE_URL}/${CNI_ARCHIVE}" \
      -o "${TMP_DIR}/${CNI_ARCHIVE}"

    curl \
      -fL \
      --retry 3 \
      --retry-delay 2 \
      "${CNI_BASE_URL}/${CNI_ARCHIVE}.sha256" \
      -o "${TMP_DIR}/${CNI_ARCHIVE}.sha256"

    echo "Verifying CNI checksum"

    (
      cd "$TMP_DIR"
      sha256sum -c "${CNI_ARCHIVE}.sha256"
    )

    install -d -m 0755 /opt/cni/bin

    tar \
      -xzf "${TMP_DIR}/${CNI_ARCHIVE}" \
      -C /opt/cni/bin

    printf '%s\n' \
      "${CNI_VERSION}/${CNI_ARCH}" \
      > "$CNI_VERSION_FILE"
  fi
else
  echo "==> Skipping CNI plugin installation"
fi

# -----------------------------------------------------------------------------
# Kubernetes repository
# -----------------------------------------------------------------------------

echo "==> Configuring Kubernetes repository"

install -d -m 0755 /etc/apt/keyrings

curl \
  -fsSL \
  "${K8S_URL}/Release.key" \
  | gpg \
      --dearmor \
      --yes \
      -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

chmod 0644 \
  /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_URL}/ /
EOF

apt-get update

# -----------------------------------------------------------------------------
# Kubernetes components
# -----------------------------------------------------------------------------

echo "==> Installing Kubernetes components"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  kubelet \
  kubeadm \
  kubectl

echo "==> Holding Kubernetes packages"

apt-mark hold \
  kubelet \
  kubeadm \
  kubectl

systemctl enable kubelet

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

echo
echo "============================================================"
echo " Installation complete"
echo "============================================================"

printf 'containerd: '
containerd --version

printf 'kubectl:    '
kubectl version \
  --client \
  --output=yaml \
  | awk '/gitVersion:/ { print $2; exit }'

printf 'kubeadm:   '
kubeadm version -o short

printf 'kubelet:   '
kubelet --version

echo
echo "Node is ready for kubeadm."
echo
echo "Next steps:"
echo "  Control plane:"
echo "    kubeadm init ..."
echo
echo "  Worker:"
echo "    kubeadm join ..."
echo
echo "NOTE:"
echo "  This script installs CNI plugin binaries only."
echo "  You still need a Kubernetes network implementation"
echo "  such as Cilium or Calico after kubeadm init."
