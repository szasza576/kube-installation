# Introduction
This guide walk you through on the standard Kubernetes installation with kubeadm and mainly focuses to [official Kubernetes documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/).

It is already assumed that you are familiar with Linux and have basic understanding about Kubernetes.

Beside the standard installation it also covers the following components:
- Install Calico as CNI plugin
- Install MetalLB as bare metal Loadbalancer
- Configure NFS share on the master node and deploys the NFS volume provisioner

The guide just gives an educational overview about the different components and can be used only for learning or lab purposes but far from production environment! Really if you found this guide via Google, don't use it to setup your production cluster!

# Compute requirements
This guide will show 1 master and 1 worker node hence it requires 2 machines. Either they are bare metal machines or virtual machines.

If you deploy VMs then follow this minimal specification per VM:
- 2 vCPU (in Azure B2s is perfect)
- 4 GB RAM
- 30 GB vHDD
- Ubuntu 22.04 LTS (go with this exact image)
- Shared subnet
- SSH access

If you deploy into a cloud provider like Azure then it is better if you deploy into a dedicated vNet so we can avoid to mess up something.

# Linux preparation
Once you have your VMs then follow the following steps to prepare them.

**Execute these steps on BOTH machines!**

1. Use your favorite SSH client (like Putty) and login to both VMs.
2. Do a network design. You have a subnet where you deployed your BMs/VMs. In my case this is 10.10.0.0/24.
   - Your BMs and VMs have their own IP address. Note them (you can also use the ```ip a``` command to get the IPs)
   - My Master node's IP is 10.10.0.4
   - My Worker node's IP is 10.10.0.5
   - We will also need some IP addresses to our exposed services. I reserve this range: 10.10.0.200 - 10.10.0.220
   - Note that if you deployed your VMs in cloud then these services won't be automatically available and won't work in the vNet but that is okay in this lesson.
3. Create environmental variables based on the IP addresses what we found out.
   - Create the "MasterIP" with the Master node's IP address
     ```bash
     MasterIP="10.10.0.4"
     ```
   - Create the "MasterName" and add a readable name for it
     ```bash
     MasterName="kube-master"
     ```
   - Create the "IngressRange" and add the IP range what we reserved to the K8s services
     ```bash
     IngressRange="10.10.0.200-10.10.0.220"
     ```
   - Create the "NFSCIDR" with the subnet CIDR
     ```bash
     NFSCIDR="10.10.0.0/24"
     ```
   - Create the "PodCIDR" with a random subnet CIDR which doesn't overlap with your network
     ```bash
     PodCIDR="172.16.0.0/16"
     ```
   - Create the "ServiceCIDR" with a random subnet CIDR which doesn't overlap with your network
     ```bash
     ServiceCIDR="172.17.0.0/16"
     ```
   - Finally create the "K8sVersion" which contains the Kubernetes version what we wish to install
     ```bash
     K8sVersion="1.25.4-00"
     ```
4. Activate auto service restart without notification and install updates on both machines:
   ```bash
   sudo sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
   sudo apt update
   sudo apt upgrade -y
   ```
5. Install basic tools
   ```bash
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
    ```
6. Kubelet doesn't properly work with memory swap and also blocks the standard installation hence we need to disable it.
   ```bash
   sudo sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab
   sudo swapoff -a
   ```
7. In production environment we would have a nice DNS but here we just update the /etc/hosts file so the nodes will be able to resolve the master node's name and IP.
   ```bash
   echo "$MasterIP $MasterName" | sudo tee -a /etc/hosts
   ```
8. For the overlay networking we need 2 kernel module what we need to load and also make it permanent hence we add them to the /etc/modules file
   ```bash
   sudo modprobe overlay
   sudo modprobe br_netfilter
   
   echo overlay | sudo tee -a /etc/modules
   echo br_netfilter | sudo tee -a /etc/modules
   ```
9. Some kernel fine-tuning is also needed to make the networking working properly.
   ```bash
   sudo tee /etc/sysctl.d/kubernetekubs.conf<<EOF
   net.bridge.bridge-nf-call-ip6tables = 1
   net.bridge.bridge-nf-call-iptables = 1
   net.ipv4.ip_forward = 1
   fs.inotify.max_user_instances=524288
   EOF

   sudo sysctl --system
   ```
At this point the Linux is prepared to install the Kubernetes cluster related components.

# Install containerd
Kubernetes supports several container runtime. This guide will install and configure containerd as one of the most widely used runtime. Containerd is free and opensource.

**Execute these steps on BOTH machines!**

1. Add the repository and install it
   ```bash
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
   
   echo \
     "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
   
   sudo apt update
   sudo apt install -y containerd.io
   ```
2. Containerd comes with a default configuration but that doesn't fully good for us. Both systemd and containerd can manage the cgroups but it is better to have a single manager. We need to leave the cgroup management to systemd and change this configuration in containerd's config file. First we generate a default config file then we change the exact parameter and then we reload the agent.
   ```bash
   sudo bash -c "containerd config default > /etc/containerd/config.toml"
   sudo sed -i "s+SystemdCgroup = false+SystemdCgroup = true+g" /etc/containerd/config.toml
   
   sudo systemctl daemon-reload 
   sudo systemctl restart containerd
   sudo systemctl enable containerd
   ```

# Install kubelet, kubeadm, kubectl
Containerd is up and running. It is time to install the Kubernetes components.

**Execute these steps on BOTH machines!**

1. Add the repository and install the 3 tools
   ```bash
   sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
   echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
   
   sudo apt update
   sudo apt -y install kubelet=$K8sVersion kubeadm=$K8sVersion kubectl=$K8sVersion
   ```
2. We also would like to avoid the accidentally updates and container restarts hence we put these tools on hold. (If you run your daily ```apt upgrade``` command then it will ignore these components. Because you run it daily, RIGHT??? :) )
   ```bash
   sudo apt-mark hold kubelet kubeadm kubectl
   ```
3. There is an auto completion tool for kubectl which is a must have. (Note one of the command will fail which is okay)
   ```bash
   echo 'source <(kubectl completion bash)' >> /home/*/.bashrc
   echo 'source <(kubectl completion zsh)' >> /home/*/.zshrc
   ```

These were the last components what we needed on all machines. Now we put the workers to the parking lane and focus on the Master node.

# Install Helm
Helm is a package manager tool what we will use for some components to the easy deployments hence we need to install it on the Master node.

**Execute these steps on only the Master node!**

1. Add the repository and install the tool.
   ```bash
   curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
   sudo apt-get update
   sudo apt-get install helm
   ```

# Install Kubernetes on the Master node
In this section we install the Kubernetes core components with the help of kubeadm.

**Execute these steps on only the Master node!**

1. Enable kubelet just to be sure (on the Worker nodes the kubeadm will restart it so it is not needed there).
   ```bash
   sudo systemctl enable kubelet
   ```
2. Pull the base images for the K8s components
3. Create a configuration file which containers the Kubernetes Version, the ServiceCIDR, the PodCIDR and sets the systemd as cgroup driver. This config file will be used only for the installation.
   ```bash
   cat << EOF > kubeadm.conf
   kind: ClusterConfiguration
   apiVersion: kubeadm.k8s.io/v1beta3
   kubernetesVersion: $(echo $K8sVersion | cut -f1 -d "-")
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
   ```
4. Initialize Kubernetes
   ```bash
   sudo kubeadm init --config kubeadm.conf
   ```
5. Copy the kubeconfig file to your own home folder
   ```bash
   mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```
6. HURRAY, K8s is installed. Let's try it out
   ```bash
   kubectl get nodes
   ```

   AHHH it is NotReady :( ... no worries we will correct it in the next chapter.
7. Kubernetes by default will taint the master node so it will run only the core containers but we also would like to use it for normal workloads too (see, I told you it is not production grade) hence we need to remove the taints. (Note, one of them might fail which is normal.)
   ```bash
   kubectl taint nodes --all node-role.kubernetes.io/master-
   kubectl taint nodes --all node-role.kubernetes.io/control-plane-
   ```

# Connect the worker to the cluster
As the Kubernetes API is already working hence we can connect the other VM to the cluster. If you check the printout of the kubeadm command then you can see that there is ```kubeadm join ...``` command. Copy it and paste it to the Worker node. Note that you need to run it as sudo.

1. If you missed the kubeadm printout then you can generate a connection token with this command. Run this on the Master node:
   ```bash
   kubeadm token create --print-join-command
   ```
2. Copy the connection command and paste it with sudo into the Worker node.
3. On the master node check the nodes.
   ```
   kubectl get nodes
   ```

   Still not ready but that is still okay.

# Install Calico as CNI plugin
A Kubernetes cluster requires a network module to give IP address to the pods. We will use Calico with a very simple configuration. Calico supports different networking methods and here we will go with a simple Overlay network.

**Execute these steps on only the Master node!**

1. Check your pods. Coredns shall be in Pending state
   ```bash
   kubectl get pods -A
   ```
2. Deploy Calico directly from the internet
   ```bash
   kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml
   ```

   Yes, correct. Calico runs on top of the Kubernetes cluster as a container and it gives the networking feature to Kubernetes. It is so much fun here :)
3. Download the default config file and modify the PodCIDR to our CIDR. Then create this CRD in Kubernetes
   ```bash
   kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml
   
   curl https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/custom-resources.yaml -s -o /tmp/custom-resources.yaml
   sed -i "s+192.168.0.0/16+$PodCIDR+g" /tmp/custom-resources.yaml
   sed -i "s+blockSize: 26+blockSize: 24+g" /tmp/custom-resources.yaml
   kubectl create -f /tmp/custom-resources.yaml
   rm /tmp/custom-resources.yaml
   ```
4. Wait until all your pods are coming to Running state.
   ```bash
   watch kubectl get pods -A
   ```
5. Check your nodes
   ```bash
   kubectl get nodes
   ```

HURRAY, your cluster and nodes are finally **Ready** It was a long run ... but still not complete.

# Install MetalLB
There are different options to expose K8s services to the external world. If we would like to use the LoadBalancer type on an on-premise environment then we need a (Software based) loadbalancer. In this case the service will get a routable IP address from the subnet.

Note that this won't work out of the box with Public Cloud environment as the IP addresses won't be registered into the vNet but that is a different story.

**Needless to say now but execute these steps on only the Master node!**

1. We can use Helm to deploy the MetalLB so add its repo
   ```bash
   helm repo add metallb https://metallb.github.io/metallb
   ```
2. We need to create and prepare its namespace with some labels
   ```bash
   kubectl create ns metallb-system
   kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged
   kubectl label namespace metallb-system pod-security.kubernetes.io/audit=privileged
   kubectl label namespace metallb-system pod-security.kubernetes.io/warn=privileged
   kubectl label namespace metallb-system app=metallb
   ```
3. Deploy MetalLB
   ```bash
   helm install metallb metallb/metallb -n metallb-system --wait
   ```
4. We also need to configure MetalLB
   ```bash
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
   kind: IPAddressPool
   metadata:
     name: local-pool
     namespace: metallb-system
   spec:
     addresses:
     - $IngressRange
   EOF
   ```

# Install NFS
This is way far from production grade as NFS doesn't provide proper authentication. The only thing is to restrict access to subnets (what we grant for the whole subnet). Nevertheless it is an easy to configure Persistent Volume driver for a lab.

We will use the Master node as the storage provider.

**Needless to say now but execute these steps on only the Master node!**

1. Install NFS server
   ```bash
   sudo apt install -y nfs-kernel-server
   ```
2. Create a local folder and set to read-writeable to anybody
   ```bash
   sudo mkdir -p /mnt/k8s-pv-data
   sudo chown -R nobody:nogroup /mnt/k8s-pv-data/
   sudo chmod 777 /mnt/k8s-pv-data/
   ```
3. Add the folder to the /etc/exports file
   ```bash
   sudo tee -a /etc/exports<<EOF
   /mnt/k8s-pv-data  ${NFSCIDR}(rw,sync,no_subtree_check)
   EOF
   ```
4. Reload the config file and restart the NFS service
   ```bash
   sudo exportfs -a
   sudo systemctl restart nfs-kernel-server
   ```
   
   With this step the folder and NFS is prepared on the node.
5. Check the StorageClasses on the K8s cluster. (Yeap it shall be empty)
   ```bash
   kubectl get sc
   ```
6. We will deploy the NFS provisioner (CSI) plugin with Helm hence we need to add the repository
   ```bash
   helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
   ```
7. Install the NFS provisioner and configure the NFS server (the Master node)
   ```bash
   helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
     -n kube-system \
     --set nfs.server=$MasterIP \
     --set nfs.path=/mnt/k8s-pv-data \
     --set storageClass.name=default \
     --set storageClass.defaultClass=true
   ```
8. Check the StorageClasses again
   ```bash
   kubectl get sc
   ```

Now you can create Persistent Volumes and then the Provisioner will automatically create a folder on the Master node and seamlessly attach it to your pods.

# Install Metrics Server
We can collect very useful metrics from the nodes and the pods but this requires a service to collect them and make it visible to use.

**Needless to say now but execute these steps on only the Master node!**

1. Add the Helm repo
   ```bash
   helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
   ```
2. Deploy it via Helm
   ```bash
   helm upgrade --install metrics-server metrics-server/metrics-server \
     --set args={--kubelet-insecure-tls} \
     -n kube-system
   ```

   Note that we need to use the --kubelet-insecure-tls extra argument because of the self-signed certificates on the Kubernetes API side.
3. It takes some time to the metrics server to catch up but in few minutes we can see some result
   ```bash
   kubectl top nodes
   ```

# Finally restart the nodes
Very likely you also installed a new kernel and we made lot of configuration hence the best is to restart both of the nodes validate that our cluster survived a restart.

Run: ```sudo reboot```