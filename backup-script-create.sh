#!/usr/bin/env bash

namespace="devops"

kubectl -n ${namespace} delete cm backup-script
kubectl -n ${namespace} create cm backup-script --from-file backup-script.sh
