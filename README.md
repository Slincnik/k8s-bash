# Kubernetes Node Prepare Script

A Bash script for preparing an Ubuntu server to run Kubernetes with `kubeadm`.

The script configures the host and installs the required Kubernetes components, but does not initialize or join a cluster.

It performs the following steps:

- configures required kernel modules and sysctl parameters;
- disables swap;
- installs and configures containerd;
- enables systemd cgroups;
- installs CNI plugin binaries;
- configures the official Kubernetes APT repository;
- installs `kubelet`, `kubeadm`, and `kubectl`;
- prevents Kubernetes packages from being upgraded unintentionally.

After running the script, the node is ready for:

```bash
kubeadm init
```

or:

```bash
kubeadm join ...
```

A Kubernetes network implementation such as Cilium or Calico must still be installed separately.
