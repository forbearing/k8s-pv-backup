#!/bin/sh

# kubeconfig
mkdir -p ${HOME}/.kube
mv /k8s-pv-backup.kubeconfig ${HOME}/.kube
ln -sf ${HOME}/.kube/k8s-pv-backup.kubeconfig ${HOME}/.kube/config
mv /kubectl /usr/local/bin/
chmod 700 /usr/local/bin/kubectl

while true; do
    sleep 1000
done
