#!/bin/bash

if [ -z ${K8sVersion+x} ]; then K8sVersion="v1.28"; fi
if [ -z ${PodCIDR+x} ]; then PodCIDR="172.16.0.0/16"; fi
if [ -z ${ServiceCIDR+x} ]; then ServiceCIDR="172.17.0.0/16"; fi
if [ -z ${IngressRange+x} ]; then IngressRange="192.168.0.140-192.168.0.149"; fi
if [ -z ${MasterIP+x} ]; then MasterIP="192.168.0.128"; fi
if [ -z ${MasterName+x} ]; then MasterName="kube-master"; fi
if [ -z ${NFSCIDR+x} ]; then NFSCIDR="192.168.0.128/29"; fi

# Install Helm
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

# Configure master node
sudo systemctl enable kubelet
sudo kubeadm config images pull

cat << EOF > kubeadm.conf
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta3
kubernetesVersion: $K8sVersion
networking:
  dnsDomain: cluster.local
  serviceSubnet: $ServiceCIDR
  podSubnet: $PodCIDR
controlPlaneEndpoint: $MasterName
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
ipvs:
  strictARP: true
EOF

sudo kubeadm init --config kubeadm.conf

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Waiting for the K8s API server to come up
test=$(kubectl get pods -A 2>&1)
while ( echo $test | grep -q "refuse\|error" ); do echo "API server is still down..."; sleep 5; test=$(kubectl get pods -A 2>&1); done

kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Configre Calico as network plugin
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/tigera-operator.yaml

curl https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/custom-resources.yaml -s -o /tmp/custom-resources.yaml
sed -i "s+192.168.0.0/16+$PodCIDR+g" /tmp/custom-resources.yaml
sed -i "s+blockSize: 26+blockSize: 24+g" /tmp/custom-resources.yaml
kubectl create -f /tmp/custom-resources.yaml
rm /tmp/custom-resources.yaml

# Configure MetalLB
helm repo add metallb https://metallb.github.io/metallb

kubectl create ns metallb-system
kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged
kubectl label namespace metallb-system pod-security.kubernetes.io/audit=privileged
kubectl label namespace metallb-system pod-security.kubernetes.io/warn=privileged
kubectl label namespace metallb-system app=metallb
helm install metallb metallb/metallb -n metallb-system --wait \
  --set crds.validationFailurePolicy=Ignore

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - $IngressRange
EOF

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: advertizer
  namespace: metallb-system
EOF

# Setup NFS share if needed
sudo apt install -y nfs-kernel-server
sudo mkdir -p /mnt/k8s-pv-data
sudo chown -R nobody:nogroup /mnt/k8s-pv-data/
sudo chmod 777 /mnt/k8s-pv-data/

sudo tee -a /etc/exports<<EOF
/mnt/k8s-pv-data  ${NFSCIDR}(rw,sync,no_subtree_check)
EOF

sudo exportfs -a
sudo systemctl restart nfs-kernel-server

# Install NFS-provisioner
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    -n kube-system \
    --set nfs.server=$MasterIP \
    --set nfs.path=/mnt/k8s-pv-data \
    --set storageClass.name=default \
    --set storageClass.defaultClass=true

# Install Metrics Server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server \
    --set args={--kubelet-insecure-tls} \
    --set hostNetwork.enabled=true \
    -n kube-system

## Install NVIDIA device plugin
#sudo apt install -y nvidia-driver-510 nvidia-cuda-toolkit

#kubectl create -f https://github.com/kubernetes/kubernetes/raw/master/cluster/addons/device-plugins/nvidia-gpu/daemonset.yaml
#kubectl label nodes kubemaster cloud.google.com/gke-accelerator=gpu
