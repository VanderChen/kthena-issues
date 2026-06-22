#!/bin/bash
set -e

MS_NAME="repro-sample"
MS_YAML="issues/bugs/003-pod-recreate-when-remove-ownref-OPEN/reproduce-sample.yaml"
POD_NAME="repro-sample-0-predictor-0-0"
POD_YAML="issues/bugs/003-pod-recreate-when-remove-ownref-OPEN/manual-pod.yaml"

echo "Cleanup existing resources..."
kubectl delete modelserving $MS_NAME --ignore-not-found=true
kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true

echo "Manually creating pod without OwnerReference..."
kubectl apply -f $POD_YAML

echo "Verifying pod has NO ownerReference..."
kubectl get pod $POD_NAME -o jsonpath='{.metadata.ownerReferences}' || echo "No ownerRef"

echo "Applying ModelServing $MS_NAME..."
kubectl apply -f $MS_YAML

echo "Waiting 30s to see if controller recreates the pod..."
sleep 30

echo "Current pods status:"
kubectl get pods $POD_NAME -o wide

echo "Checking OwnerReference (if controller correctly recreated it, it should have ownerRef):"
kubectl get pod $POD_NAME -o jsonpath='{.metadata.ownerReferences}'

echo "Logs from controller manager (filtered by repro-sample):"
kubectl logs -n kthena-system -l app=kthena-controller-manager --tail=100 | grep -i "$MS_NAME" || true
