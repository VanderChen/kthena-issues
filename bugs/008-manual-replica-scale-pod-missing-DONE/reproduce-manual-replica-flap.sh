#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-replica-flap-008}"
MS="${MS:-manual-replica-flap}"
HIGH="${HIGH:-5}"
LOW="${LOW:-1}"
ROLES="${ROLES:-prefill decode}"
ITERATIONS="${ITERATIONS:-30}"
SETTLE_SECONDS="${SETTLE_SECONDS:-45}"
DELAY_SECONDS_LIST="${DELAY_SECONDS_LIST:-0 0.1 0.3 0.7 1.5}"
STABLE_READS="${STABLE_READS:-3}"

selector="modelserving.volcano.sh/name=${MS}"
read -r -a role_array <<<"${ROLES}"
expected_pod_count=$((HIGH * ${#role_array[@]}))

pod_count() {
  kubectl get pods -n "${NS}" -l "${selector}" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

pod_names() {
  kubectl get pods -n "${NS}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
}

status_line() {
  kubectl get modelserving -n "${NS}" "${MS}" -o jsonpath='spec={.spec.replicas} status={.status.replicas}/{.status.availableReplicas} observedGeneration={.status.observedGeneration} generation={.metadata.generation}' 2>/dev/null || true
}

missing_expected() {
  local missing=()
  local existing
  existing="$(pod_names)"
  for ((group = 0; group < HIGH; group++)); do
    for role in ${ROLES}; do
      local pod="${MS}-${group}-${role}-0-0"
      if ! grep -qx "${pod}" <<<"${existing}"; then
        missing+=("${pod}")
      fi
    done
  done
  printf '%s\n' "${missing[@]}"
}

observed_generation() {
  kubectl get modelserving -n "${NS}" "${MS}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true
}

wait_for_final_high_state() {
  local target_generation="$1"
  local deadline=$((SECONDS + SETTLE_SECONDS))
  local stable=0
  while (( SECONDS < deadline )); do
    local observed
    observed="$(observed_generation)"
    local missing
    missing="$(missing_expected)"
    if [[ "${observed}" == "${target_generation}" && "$(pod_count)" == "${expected_pod_count}" && -z "${missing}" ]]; then
      stable=$((stable + 1))
      if (( stable >= STABLE_READS )); then
        return 0
      fi
    else
      stable=0
    fi
    sleep 1
  done
  return 1
}

kubectl apply -f "$(dirname "$0")/reproduce-kind-manual-replica-flap.yaml"
initial_generation="$(kubectl patch modelserving -n "${NS}" "${MS}" --type merge -p "{\"spec\":{\"replicas\":${HIGH}}}" -o jsonpath='{.metadata.generation}')"

echo "initial: waiting for ${HIGH} replicas"
if ! wait_for_final_high_state "${initial_generation}"; then
  echo "initial high count not reached"
  status_line
  pod_names
  exit 1
fi

for ((i = 1; i <= ITERATIONS; i++)); do
  for delay in ${DELAY_SECONDS_LIST}; do
    echo "iteration=${i} delay=${delay}: scale ${HIGH}->${LOW}->${HIGH}"
    kubectl patch modelserving -n "${NS}" "${MS}" --type merge -p "{\"spec\":{\"replicas\":${LOW}}}" >/dev/null
    sleep "${delay}"
    target_generation="$(kubectl patch modelserving -n "${NS}" "${MS}" --type merge -p "{\"spec\":{\"replicas\":${HIGH}}}" -o jsonpath='{.metadata.generation}')"

    if ! wait_for_final_high_state "${target_generation}"; then
      echo "FAIL iteration=${i} delay=${delay}"
      status_line
      echo "pod_count=$(pod_count)"
      echo "existing:"
      pod_names
      echo "missing:"
      missing_expected
      exit 2
    fi
  done
done

echo "PASS: ${ITERATIONS} iterations across delays (${DELAY_SECONDS_LIST}) maintained expected pod objects"
status_line
pod_names
