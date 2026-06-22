# Bug Description

## Summary
autoscaler对采集目标中如果有pod重启过，这次采集会跳过，这不合理。因为Autoscaler会过滤掉有过重启但是已经running的pod。

## Steps to Reproduce
1. Step 1
2. Step 2
3. ...

## Expected Behavior
对于有过重启但是已经running的pod正常采集

## Actual Behavior
What actually happened.

## Environment Details
- Kthena Version:
- Kubernetes Version:
- OS:
- Relevant Logs/Events:
