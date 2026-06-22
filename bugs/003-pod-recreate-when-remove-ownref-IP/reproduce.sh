#!/bin/bash
set -e

# Configuration
MS_YAML="issues/bugs/003-pod-recreate-when-remove-ownref-OPEN/reproduce-sample.yaml"
MS_NAME="repro-sample"
NAMESPACE="default"

echo "Cleanup existing resources..."
kubectl delete modelserving $MS_NAME --ignore-not-found=true
# Force delete pods if they are stuck
kubectl delete pods -l modelserving.volcano.sh/name=$MS_NAME --force --grace-period=0 --ignore-not-found=true

echo "Applying ModelServing $MS_NAME..."
kubectl apply -f $MS_YAML

echo "Waiting for pods to be created..."
for i in {1..30}; do
  POD_NAME=$(kubectl get pods -l modelserving.volcano.sh/name=$MS_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD_NAME" ]; then
    echo "Pod $POD_NAME created."
    break
  fi
  sleep 1
done

if [ -z "$POD_NAME" ]; then
  echo "Failed to create pods for $MS_NAME"
  exit 1
fi

echo "Removing OwnerReference from $POD_NAME..."
kubectl patch pod $POD_NAME --type='json' -p='[{"op": "remove", "path": "/metadata/ownerReferences"}]'

echo "Waiting 20s to see if controller recreates the pod..."
sleep 20

echo "Current pods for $MS_NAME:"
kubectl get pods -l modelserving.volcano.sh/name=$MS_NAME

echo "Checking OwnerReference of $POD_NAME (should be empty):"
kubectl get pod $POD_NAME -o jsonpath='{.metadata.ownerReferences}'

echo "Checking if a new pod was created (look for pods with different names or younger age):"
# New pod will have same name but different UID and Age
kubectl get pods -l modelserving.volcano.sh/name=$MS_NAME --sort-by=.metadata.creationTimestamp
