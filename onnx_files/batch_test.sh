#!/usr/bin/env bash
set -euo pipefail

RUN_MODEL="/litert_build/bazel-bin/litert/tools/run_model"
ONNX_ROOT="/litert_build/onnx_files"
BAZEL_BIN="/litert_build/bazel-bin"
ITERATIONS=100
ACCELERATOR="cpu"
DISPATCH_LIBRARY_DIR=""
NPU_VENDOR=""
EXTRA_RUN_MODEL_ARGS=()
QUALCOMM_HTP_PERFORMANCE_MODE=""
QUALCOMM_DSP_PERFORMANCE_MODE=""
MEDIATEK_PERFORMANCE_MODE=""

# Medium performance defaults (between max perf and power saving).
QUALCOMM_MEDIUM_PERFORMANCE_MODE="balanced"
MEDIATEK_MEDIUM_PERFORMANCE_MODE="sustained_speed"

QUALCOMM_DISPATCH_SO="libLiteRtDispatch_Qualcomm.so"
MEDIATEK_DISPATCH_SO="libLiteRtDispatch_MediaTek.so"

resolve_dispatch_dir() {
  local vendor="$1"
  local so_name rel_dir
  case "${vendor}" in
    qualcomm)
      so_name="${QUALCOMM_DISPATCH_SO}"
      rel_dir="litert/vendors/qualcomm/dispatch"
      ;;
    mediatek)
      so_name="${MEDIATEK_DISPATCH_SO}"
      rel_dir="litert/vendors/mediatek/dispatch"
      ;;
    *)
      return 1
      ;;
  esac

  local candidate
  for candidate in \
    "${BAZEL_BIN}/${rel_dir}/${so_name}" \
    "/litert_build/.cache/bazel"/*"/execroot/litert/bazel-out"/*/bin/${rel_dir}/${so_name}; do
    if [[ -f "${candidate}" ]]; then
      dirname "${candidate}"
      return 0
    fi
  done
  return 1
}

dispatch_bazel_target() {
  case "$1" in
    qualcomm) echo "//litert/vendors/qualcomm/dispatch:dispatch_api_so" ;;
    mediatek) echo "//litert/vendors/mediatek/dispatch:dispatch_api_so" ;;
  esac
}

build_dispatch_library() {
  local vendor="$1"
  local target
  target="$(dispatch_bazel_target "${vendor}")"

  if [[ ! -f /setup_bazel_env.sh ]]; then
    return 1
  fi

  echo "Building ${vendor} dispatch library (${target})..." >&2
  # shellcheck disable=SC1091
  source /setup_bazel_env.sh
  bazel ${EXTRA_STARTUP} build "${target}"
}

ensure_dispatch_library() {
  local vendor="$1"
  if DISPATCH_LIBRARY_DIR="$(resolve_dispatch_dir "${vendor}")"; then
    return 0
  fi
  if build_dispatch_library "${vendor}"; then
    DISPATCH_LIBRARY_DIR="$(resolve_dispatch_dir "${vendor}")"
    [[ -n "${DISPATCH_LIBRARY_DIR}" ]]
    return
  fi
  return 1
}

apply_npu_performance_modes() {
  case "${NPU_VENDOR}" in
    qualcomm)
      QUALCOMM_HTP_PERFORMANCE_MODE="${QUALCOMM_HTP_PERFORMANCE_MODE:-${QUALCOMM_MEDIUM_PERFORMANCE_MODE}}"
      QUALCOMM_DSP_PERFORMANCE_MODE="${QUALCOMM_DSP_PERFORMANCE_MODE:-${QUALCOMM_MEDIUM_PERFORMANCE_MODE}}"
      ;;
    mediatek)
      MEDIATEK_PERFORMANCE_MODE="${MEDIATEK_PERFORMANCE_MODE:-${MEDIATEK_MEDIUM_PERFORMANCE_MODE}}"
      ;;
  esac
}

dispatch_build_hint() {
  local vendor="$1"
  case "${vendor}" in
    qualcomm)
      cat <<EOF >&2
Build the Qualcomm dispatch library inside the container:

  source /setup_bazel_env.sh
  bazel \${EXTRA_STARTUP} build //litert/vendors/qualcomm/dispatch:dispatch_api_so

Expected output: ${BAZEL_BIN}/litert/vendors/qualcomm/dispatch/${QUALCOMM_DISPATCH_SO}

Note: Qualcomm NPU inference requires an Android device with a Qualcomm NPU.
Build for the device with --config=android_arm64, push binaries via adb, and run
run_model on the phone (see litert/vendors/qualcomm/doc/BUILD_INSTRUCTIONS.md).
EOF
      ;;
    mediatek)
      cat <<EOF >&2
Build the MediaTek dispatch library inside the container:

  source /setup_bazel_env.sh
  bazel \${EXTRA_STARTUP} build //litert/vendors/mediatek/dispatch:dispatch_api_so

Expected output: ${BAZEL_BIN}/litert/vendors/mediatek/dispatch/${MEDIATEK_DISPATCH_SO}

Note: MediaTek NPU inference requires an Android device with a MediaTek SoC.
EOF
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run run_model for all models and record average inference time.

Options:
  --accelerator=cpu|gpu|npu     Hardware backend (default: cpu)
  --npu-vendor=qualcomm|mediatek
                                Select NPU vendor; sets --accelerator=npu and
                                --dispatch_library_dir to the built dispatch lib
  --dispatch_library_dir=DIR    Path to dispatch libs (required for NPU if
                                --npu-vendor is not set)
  --qualcomm-performance-mode=MODE
                                Qualcomm HTP/DSP performance mode (default for
                                --npu-vendor=qualcomm: balanced)
  --qualcomm-htp-performance-mode=MODE
                                Qualcomm HTP only (overrides --qualcomm-performance-mode)
  --qualcomm-dsp-performance-mode=MODE
                                Qualcomm DSP only (overrides --qualcomm-performance-mode)
  --mediatek-performance-mode=MODE
                                MediaTek performance mode (default for
                                --npu-vendor=mediatek: sustained_speed)
  --iterations=N                Number of inference runs (default: 100)
  -h, --help                    Show this help

Performance modes (medium = default for NPU vendor):
  Qualcomm:  balanced, default, low_balanced, high_performance, burst, power_saver, ...
  MediaTek:  sustained_speed, fast_single_answer, low_power, turbo_boost

Examples:
  $(basename "$0")
  $(basename "$0") --accelerator=npu --npu-vendor=qualcomm
  $(basename "$0") --accelerator=npu --npu-vendor=mediatek
  $(basename "$0") --accelerator=npu --npu-vendor=qualcomm --qualcomm-performance-mode=balanced
  $(basename "$0") --accelerator=npu --dispatch_library_dir=/path/to/dispatch/libs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accelerator=*)
      ACCELERATOR="${1#*=}"
      ;;
    --npu-vendor=*)
      NPU_VENDOR="${1#*=}"
      ;;
    --dispatch_library_dir=*)
      DISPATCH_LIBRARY_DIR="${1#*=}"
      ;;
    --qualcomm-performance-mode=*)
      QUALCOMM_HTP_PERFORMANCE_MODE="${1#*=}"
      QUALCOMM_DSP_PERFORMANCE_MODE="${1#*=}"
      ;;
    --qualcomm-htp-performance-mode=*)
      QUALCOMM_HTP_PERFORMANCE_MODE="${1#*=}"
      ;;
    --qualcomm-dsp-performance-mode=*)
      QUALCOMM_DSP_PERFORMANCE_MODE="${1#*=}"
      ;;
    --mediatek-performance-mode=*)
      MEDIATEK_PERFORMANCE_MODE="${1#*=}"
      ;;
    --iterations=*)
      ITERATIONS="${1#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      EXTRA_RUN_MODEL_ARGS+=("$1")
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -n "${NPU_VENDOR}" ]]; then
  ACCELERATOR="npu"
  case "${NPU_VENDOR}" in
    qualcomm|mediatek) ;;
    *)
      echo "Error: unknown --npu-vendor=${NPU_VENDOR} (use qualcomm or mediatek)" >&2
      exit 1
      ;;
  esac
  if [[ -z "${DISPATCH_LIBRARY_DIR}" ]]; then
    if ! ensure_dispatch_library "${NPU_VENDOR}"; then
      echo "Error: ${NPU_VENDOR} dispatch library not found (build failed)." >&2
      dispatch_build_hint "${NPU_VENDOR}"
      exit 1
    fi
  fi
  apply_npu_performance_modes
fi

if [[ "${ACCELERATOR}" == *npu* && -z "${DISPATCH_LIBRARY_DIR}" ]]; then
  echo "Error: --accelerator=npu requires --dispatch_library_dir or --npu-vendor" >&2
  usage >&2
  exit 1
fi

if [[ -n "${DISPATCH_LIBRARY_DIR}" ]]; then
  if [[ ! -d "${DISPATCH_LIBRARY_DIR}" ]]; then
    echo "Error: dispatch library dir not found: ${DISPATCH_LIBRARY_DIR}" >&2
    if [[ -n "${NPU_VENDOR}" ]]; then
      dispatch_build_hint "${NPU_VENDOR}"
    fi
    exit 1
  fi
  shopt -s nullglob
  dispatch_sos=("${DISPATCH_LIBRARY_DIR}"/libLiteRtDispatch_*.so)
  shopt -u nullglob
  if ((${#dispatch_sos[@]} == 0)); then
    echo "Error: no libLiteRtDispatch_*.so in ${DISPATCH_LIBRARY_DIR}" >&2
    if [[ -n "${NPU_VENDOR}" ]]; then
      dispatch_build_hint "${NPU_VENDOR}"
    fi
    exit 1
  fi
fi

RUN_LABEL="${ACCELERATOR}"
if [[ -n "${NPU_VENDOR}" ]]; then
  RUN_LABEL="${ACCELERATOR}_${NPU_VENDOR}"
fi
RESULTS_FILE="${ONNX_ROOT}/batch_test_results_${RUN_LABEL}_$(date +%Y%m%d_%H%M%S).txt"

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

if [[ ! -x "${RUN_MODEL}" ]]; then
  echo "Error: run_model not found at ${RUN_MODEL}" >&2
  exit 1
fi

build_run_model_args() {
  local -a args=(
    --graph="$1"
    --iterations="${ITERATIONS}"
    --accelerator="${ACCELERATOR}"
  )
  if [[ -n "${DISPATCH_LIBRARY_DIR}" ]]; then
    args+=(--dispatch_library_dir="${DISPATCH_LIBRARY_DIR}")
  fi
  if [[ -n "${QUALCOMM_HTP_PERFORMANCE_MODE}" ]]; then
    args+=(--qualcomm_htp_performance_mode="${QUALCOMM_HTP_PERFORMANCE_MODE}")
  fi
  if [[ -n "${QUALCOMM_DSP_PERFORMANCE_MODE}" ]]; then
    args+=(--qualcomm_dsp_performance_mode="${QUALCOMM_DSP_PERFORMANCE_MODE}")
  fi
  if [[ -n "${MEDIATEK_PERFORMANCE_MODE}" ]]; then
    args+=(--mediatek_performance_mode_type="${MEDIATEK_PERFORMANCE_MODE}")
  fi
  if ((${#EXTRA_RUN_MODEL_ARGS[@]} > 0)); then
    args+=("${EXTRA_RUN_MODEL_ARGS[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

format_run_model_command() {
  local -a args=("$@")
  local cmd="${RUN_MODEL}"
  local arg
  for arg in "${args[@]}"; do
    cmd+=" $(printf '%q' "${arg}")"
  done
  printf '%s' "${cmd}"
}

{
  echo "accelerator=${ACCELERATOR}"
  echo "iterations=${ITERATIONS}"
  if [[ -n "${NPU_VENDOR}" ]]; then
    echo "npu_vendor=${NPU_VENDOR}"
  fi
  if [[ -n "${DISPATCH_LIBRARY_DIR}" ]]; then
    echo "dispatch_library_dir=${DISPATCH_LIBRARY_DIR}"
  fi
  if [[ -n "${QUALCOMM_HTP_PERFORMANCE_MODE}" ]]; then
    echo "qualcomm_htp_performance_mode=${QUALCOMM_HTP_PERFORMANCE_MODE}"
  fi
  if [[ -n "${QUALCOMM_DSP_PERFORMANCE_MODE}" ]]; then
    echo "qualcomm_dsp_performance_mode=${QUALCOMM_DSP_PERFORMANCE_MODE}"
  fi
  if [[ -n "${MEDIATEK_PERFORMANCE_MODE}" ]]; then
    echo "mediatek_performance_mode=${MEDIATEK_PERFORMANCE_MODE}"
  fi
  for model_name in "${MODELS[@]}"; do
    example_graph="${ONNX_ROOT}/${model_name}/model.tflite"
    if [[ -f "${example_graph}" ]]; then
      mapfile -t example_args < <(build_run_model_args "${example_graph}")
      echo "run_model_command=$(format_run_model_command "${example_args[@]}")"
      break
    fi
  done
  echo
} | tee "${RESULTS_FILE}"

printf "%-30s %20s\n" "model_name" "avg_us" | tee -a "${RESULTS_FILE}"
printf "%-30s %20s\n" "----------" "------" | tee -a "${RESULTS_FILE}"

failed=0
for model_name in "${MODELS[@]}"; do
  graph="${ONNX_ROOT}/${model_name}/model.tflite"
  if [[ ! -f "${graph}" ]]; then
    printf "%-30s %20s\n" "${model_name}" "MISSING" | tee -a "${RESULTS_FILE}"
    ((failed++)) || true
    continue
  fi

  echo "Running ${model_name} (${RUN_LABEL})..." >&2
  mapfile -t run_args < <(build_run_model_args "${graph}")
  echo "Command: $(format_run_model_command "${run_args[@]}")" >&2
  output="$("${RUN_MODEL}" "${run_args[@]}" 2>&1)" || {
    printf "%-30s %20s\n" "${model_name}" "FAILED" | tee -a "${RESULTS_FILE}"
    echo "${output}" >&2
    ((failed++)) || true
    continue
  }

  avg_us="$(echo "${output}" | grep -oP 'All runs took average \K[0-9]+' | tail -1 || true)"
  if [[ -z "${avg_us}" ]]; then
    printf "%-30s %20s\n" "${model_name}" "NO_RESULT" | tee -a "${RESULTS_FILE}"
    echo "${output}" >&2
    ((failed++)) || true
    continue
  fi

  printf "%-30s %20s\n" "${model_name}" "${avg_us}" | tee -a "${RESULTS_FILE}"
done

echo >&2
echo "Results saved to ${RESULTS_FILE}" >&2
if (( failed > 0 )); then
  echo "${failed} model(s) failed or missing." >&2
  exit 1
fi
