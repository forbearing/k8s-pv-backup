#!/usr/bin/env bash

kubectl -n kube-backup delete cm script; kubectl -n kube-backup create cm script --from-file script
kubectl -n kube-backup delete cm restic; kubectl -n kube-backup create cm restic --from-file restic
