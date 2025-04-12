#!/bin/bash

set -e # exit on first error

# --- Check arguments ---
USER_CONFIG=""
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --config) USER_CONFIG="$2"; shift ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done



echo "Install basic dependencies"
sudo apt-get update & apt-get install -y apt-transport-https ca-certificates curl gpg

echo "Setting up core and system parameters"

echo "Adding settings to sysctl.conf"
cat <<EOF | sudo tee /etc/sysctl.conf
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.ip_local_port_range = 10240 65535
vm.overcommit_memory = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
fs.file-max = 500000
fs.inotify.max_user_watches = 524288
kernel.sched_migration_cost_ns = 500000
kernel.sched_autogroup_enabled = 0
EOF

echo "Create k8s config"
sudo touch /etc/sysctl.d/kubernetes.conf
sudo bash -c 'cat <<EOF > /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF'

echo "Loading kernel modules"
sudo modprobe overlay 
sudo modprobe br_netfilter

echo "Enabling kernel modules"
echo "overlay" | sudo tee -a /etc/modules
echo "br_netfilter" | sudo tee -a /etc/modules

echo "Enabling ip_forwarding"
echo "1" | sudo tee -a /proc/sys/net/ipv4/ip_forward

echo "Reload sysctl"
sudo systemctl daemon-reexec
sudo sysctl \--system 

echo "Install containerd"
sudo apt-get install -y containerd

echo "Configure containerd"
sudo mkdir -p /etc/containerd

if [[ -n "$USER_CONFIG" && -f "$USER_CONFIG" ]]; then
  echo "Using user config.toml: $USER_CONFIG"
  sudo cp "$USER_CONFIG" /etc/containerd/config.toml
else
  echo "Create base config.toml..."
  sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
fi

# Важные настройки для Kubernetes:
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

echo "Install CNI plugins"
sudo mkdir -p /opt/cni/bin
wget -q https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -O /tmp/cni-plugins.tgz
sudo tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin
sudo chmod -R 0755 /opt/cni/bin
rm /tmp/cni-plugins.tgz

echo "Disable swapping"
sudo swapoff -a

echo "Restart containerd"
sudo systemctl restart containerd

echo "Install kubeadm, kubelet and kubectl"
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

sudo apt-get install -y kubelet kubeadm kubectl

echo "Check k8s status"
kubectl version --client && kubeadm version && kubelet --version


