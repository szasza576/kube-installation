#!/bin/bash

if [ -z ${K8sVersion+x} ]; then K8sVersion="1.25.4-00"; fi
if [ -z ${PodCIDR+x} ]; then PodCIDR="172.16.0.0/16"; fi
if [ -z ${ServiceCIDR+x} ]; then ServiceCIDR="172.17.0.0/16"; fi
if [ -z ${IngressRange+x} ]; then IngressRange="10.10.0.200-10.10.0.220"; fi
if [ -z ${MasterIP+x} ]; then MasterIP="10.10.0.4"; fi
if [ -z ${MasterName+x} ]; then MasterName="kube-master"; fi
if [ -z ${NFSCIDR+x} ]; then NFSCIDR="10.10.0.0/24"; fi

# General update
sudo sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
sudo apt update
sudo apt upgrade -y

# Install base tools
sudo apt install -y \
    apt-transport-https \
    ca-certificates \
    gnupg2 \
    lsb-release \
    mc \
    curl \
    software-properties-common \
    net-tools \
    nfs-common \
    dstat \
    git \
    curl \
    htop \
    nano \
    bash-completion \
    vim \
    jq


# Disable Swap
sudo sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab
sudo swapoff -a

# Configure hosts file and routes
echo "$MasterIP $MasterName" | sudo tee -a /etc/hosts

# Enable kernel modules and setup sysctl
sudo modprobe overlay
sudo modprobe br_netfilter

echo overlay | sudo tee -a /etc/modules
echo br_netfilter | sudo tee -a /etc/modules

sudo tee /etc/sysctl.d/kubernetekubs.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances=524288
EOF

sudo sysctl --system

# Install containerd
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y containerd.io

# Configure containerd
sudo bash -c "containerd config default > /etc/containerd/config.toml"
sudo sed -i "s+SystemdCgroup = false+SystemdCgroup = true+g" /etc/containerd/config.toml

sudo systemctl daemon-reload 
sudo systemctl restart containerd
sudo systemctl enable containerd


# Install kubelet, kubeadm, kubectl
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt -y install kubelet=$K8sVersion kubeadm=$K8sVersion kubectl=$K8sVersion
sudo apt-mark hold kubelet kubeadm kubectl

echo 'source <(kubectl completion bash)' >> /home/*/.bashrc
echo 'source <(kubectl completion zsh)' >> /home/*/.zshrc

# Restart the node after successful base installation
sudo reboot