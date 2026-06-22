# Increase Unit Test Coverage

## Objective
当前kthena-controller-manager会创建headless svc，但是相较于sts的headless svc，当前不支持通过加上pod name后通过headless svc访问特定pod。希望kthena-controller-manager会创建headless svc也支持。

## Requirements

