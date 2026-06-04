#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONNX_ROOT="${ONNX_ROOT:-${SCRIPT_DIR}}"
ONDEVICE_TEST="${SCRIPT_DIR}/ondevice_test.sh"
CPU_ONLY=false
EXTRA_ONDEVICE_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run ondevice_test.sh for all models and record a summary table with device
info, inference timings, and node-type computation breakdown.

Options:
  --cpu                         Run on CPU only (passed to ondevice_test.sh)
  -h, --help                    Show this help

Each model log is written under:
  onnx_files/batch_ondevice_logs/<run_label>/<model_name>.log

Results table:
  onnx_files/batch_ondevice_results_<run_label>_<timestamp>.txt

Examples:
  $(basename "$0")
  $(basename "$0") --cpu
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)
      CPU_ONLY=true
      EXTRA_ONDEVICE_ARGS+=(--cpu)
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      EXTRA_ONDEVICE_ARGS+=("$1")
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -x "${ONDEVICE_TEST}" ]]; then
  echo "Error: ondevice_test.sh not found or not executable: ${ONDEVICE_TEST}" >&2
  exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: adb not found in PATH" >&2
  exit 1
fi

if ! adb get-state >/dev/null 2>&1; then
  echo "Error: no adb device connected" >&2
  exit 1
fi

SOC_MODEL="$(adb shell getprop ro.soc.model | tr -d '\r')"
if [[ "${CPU_ONLY}" == "true" ]]; then
  NPU_VENDOR=cpu
  RUN_LABEL="cpu_${SOC_MODEL}"
else
  case "${SOC_MODEL}" in
    MT*) NPU_VENDOR=mediatek ;;
    SM*) NPU_VENDOR=qualcomm ;;
    *)
      echo "Error: unknown SoC ${SOC_MODEL} (expected Qualcomm SM* or MediaTek MT*)" >&2
      exit 1
      ;;
  esac
  RUN_LABEL="ondevice_${NPU_VENDOR}_${SOC_MODEL}"
fi

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${ONNX_ROOT}/batch_ondevice_logs/${RUN_LABEL}_${RUN_STAMP}"
RESULTS_FILE="${ONNX_ROOT}/batch_ondevice_results_${RUN_LABEL}_${RUN_STAMP}.txt"
mkdir -p "${LOG_DIR}"

MODELS=(
  digit_model
  excitement_model
  density_map
  highlight_model
  lolm_digit_attn_model
  lolm_excitement_model
  lolm_density_model
  lolm_highlight_model
  hpjy_yolo_noe2e
  cf_badge_model
  cf_excitement_model
  cf_highlight_model
  val_badge_model
  val_hero_icon_model
  val_excitement_model
  val_highlight_model
  deltaforce_yolo_noe2e
)

parse_log_metric() {
  local log_file="$1"
  local pattern="$2"
  grep -oP "${pattern}" "${log_file}" 2>/dev/null | tail -1 || true
}

parse_inference_metrics() {
  local log_file="$1"
  INIT_MS="$(parse_log_metric "${log_file}" 'Model initialization: \K[0-9.]+')"
  WARMUP_FIRST_MS="$(parse_log_metric "${log_file}" 'Warmup \(first\):\s+\K[0-9.]+')"
  WARMUP_AVG_MS="$(parse_log_metric "${log_file}" 'Warmup \(avg\):\s+\K[0-9.]+')"
  INFER_AVG_MS="$(parse_log_metric "${log_file}" 'Inference \(avg\):\s+\K[0-9.]+')"
  INFER_MIN_MS="$(parse_log_metric "${log_file}" 'Inference \(min\):\s+\K[0-9.]+')"
  INFER_MAX_MS="$(parse_log_metric "${log_file}" 'Inference \(max\):\s+\K[0-9.]+')"
  INFER_STD="$(parse_log_metric "${log_file}" 'Inference \(std\):\s+\K[0-9.]+')"
  THROUGHPUT_MBPS="$(parse_log_metric "${log_file}" 'Throughput:\s+\K[0-9.]+')"
  INIT_FOOTPRINT_MB="$(parse_log_metric "${log_file}" 'Init footprint:\s+\K[0-9.]+')"
  OVERALL_FOOTPRINT_MB="$(parse_log_metric "${log_file}" 'Overall footprint:\s+\K[0-9.]+')"
}

parse_node_summary() {
  local log_file="$1"
  NODE_SUMMARY="$(
    awk '
      /^=+ Summary by node type =+/ { in_block = 1; next }
      in_block && /\[Node type\]/ { next }
      in_block && /^[[:space:]]*$/ { exit }
      in_block {
        gsub(/^[[:space:]]+/, "")
        n = split($0, f, /[[:space:]]+/)
        if (n >= 4) {
          node = f[1]
          count = f[2]
          avg_pct = f[4]
          gsub(/%$/, "", avg_pct)
          if (out != "") {
            out = out " "
          }
          out = out count " " node " " avg_pct "%"
        }
      }
      END { print out }
    ' "${log_file}"
  )"
}

write_results_header() {
  {
    echo "timestamp=$(date -Iseconds)"
    echo "device=${SOC_MODEL}"
    echo "npu_vendor=${NPU_VENDOR}"
    echo "log_dir=${LOG_DIR}"
    echo "ondevice_test=${ONDEVICE_TEST}"
    if ((${#EXTRA_ONDEVICE_ARGS[@]} > 0)); then
      echo "ondevice_args=${EXTRA_ONDEVICE_ARGS[*]}"
    fi
    echo
    printf "%-24s %-8s %8s %8s %8s %8s %8s %6s %8s %s\n" \
      "model_name" "device" "init_ms" "warm_ms" "avg_ms" "min_ms" "max_ms" "std" "mem_MB" "node_breakdown"
    printf "%-24s %-8s %8s %8s %8s %8s %8s %6s %8s %s\n" \
      "------------------------" "--------" "--------" "--------" "--------" "--------" "--------" "------" "--------" "-------------"
  } | tee "${RESULTS_FILE}"
}

write_results_row() {
  local model_name="$1"
  local status="${2:-ok}"
  local mem_mb="${OVERALL_FOOTPRINT_MB:-${INIT_FOOTPRINT_MB:-}}"

  if [[ "${status}" != "ok" ]]; then
    printf "%-24s %-8s %8s %8s %8s %8s %8s %6s %8s %s\n" \
      "${model_name}" "${SOC_MODEL}" "-" "-" "-" "-" "-" "-" "-" "${status}" | tee -a "${RESULTS_FILE}"
    return
  fi

  printf "%-24s %-8s %8s %8s %8s %8s %8s %6s %8s %s\n" \
    "${model_name}" \
    "${SOC_MODEL}" \
    "${INIT_MS:-?}" \
    "${WARMUP_AVG_MS:-?}" \
    "${INFER_AVG_MS:-?}" \
    "${INFER_MIN_MS:-?}" \
    "${INFER_MAX_MS:-?}" \
    "${INFER_STD:-?}" \
    "${mem_mb:-?}" \
    "${NODE_SUMMARY:-?}" | tee -a "${RESULTS_FILE}"
}

write_results_header

failed=0
for model_name in "${MODELS[@]}"; do
  graph="${ONNX_ROOT}/${model_name}/model.tflite"
  log_file="${LOG_DIR}/${model_name}.log"

  if [[ ! -f "${graph}" ]]; then
    echo "Missing model: ${graph}" >&2
    write_results_row "${model_name}" "MISSING"
    ((failed++)) || true
    continue
  fi

  echo "Running ${model_name} on ${SOC_MODEL} (${NPU_VENDOR})..." >&2
  set +e
  "${ONDEVICE_TEST}" "${EXTRA_ONDEVICE_ARGS[@]}" --log-file "${log_file}" "${graph}"
  test_exit=$?
  set -e

  if (( test_exit != 0 )); then
    echo "ondevice_test failed for ${model_name} (exit ${test_exit})" >&2
    write_results_row "${model_name}" "FAILED"
    ((failed++)) || true
    continue
  fi

  parse_inference_metrics "${log_file}"
  parse_node_summary "${log_file}"

  if [[ -z "${INFER_AVG_MS}" ]]; then
    echo "Could not parse inference metrics from ${log_file}" >&2
    write_results_row "${model_name}" "NO_RESULT"
    ((failed++)) || true
    continue
  fi

  write_results_row "${model_name}" "ok"
done

echo >&2
echo "Logs saved under ${LOG_DIR}" >&2
echo "Results saved to ${RESULTS_FILE}" >&2
if (( failed > 0 )); then
  echo "${failed} model(s) failed or missing." >&2
  exit 1
fi
