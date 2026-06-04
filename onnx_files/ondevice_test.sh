#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-${REPO_ROOT}/bazel-bin}"

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [--log-file PATH] <model.tflite>

Environment:
  BAZEL_BIN   Path to bazel-bin (default: \${REPO_ROOT}/bazel-bin)
  REPO_ROOT   LiteRT checkout root (default: parent of onnx_files/)
  LOG_FILE    Output log path (default: onnx_files/ondevice_test_<vendor>_<model>_<timestamp>.log)
EOF
  exit 1
}

resolve_bazel_artifact() {
  local rel_path="$1"
  local candidate

  for candidate in \
    "${BAZEL_BIN}/${rel_path}" \
    "${REPO_ROOT}/bazel-bin/${rel_path}" \
    "${REPO_ROOT}/.cache/bazel"/*"/execroot/litert/bazel-out"/*/bin/${rel_path}; do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

require_file() {
  local rel_path="$1"
  local hint="$2"
  local resolved=""

  if ! resolved="$(resolve_bazel_artifact "${rel_path}")"; then
    echo "Error: required artifact not found: ${rel_path}" >&2
    echo "  Searched under: ${BAZEL_BIN}" >&2
    echo "${hint}" >&2
    exit 1
  fi
  echo "${resolved}"
}

write_log_header() {
  local benchmark_cmd="$1"
  {
    echo "timestamp=$(date -Iseconds)"
    echo "model=${MODEL_PATH}"
    echo "model_name=${MODEL_NAME}"
    echo "soc_model=${SOC_MODEL}"
    echo "npu_vendor=${NPU_VENDOR}"
    echo "test_folder=${TEST_FOLDER}"
    echo "bazel_bin=${BAZEL_BIN}"
    echo "benchmark_model=${BENCHMARK_MODEL}"
    echo "lib_litert=${LIB_LITERT}"
    echo "dispatch_so=${DISPATCH_SO}"
    if [[ "${NPU_VENDOR}" == "qualcomm" ]]; then
      echo "qcom_htp_version=${QCOM_HTP_VERSION:-}"
      echo "dsp_arch=${DSP_ARCH:-}"
    elif [[ "${NPU_VENDOR}" == "mediatek" ]]; then
      echo "mediatek_performance_mode=${MEDIATEK_PERFORMANCE_MODE}"
      echo "mediatek_nerun_pilot_version=${MEDIATEK_NERUN_PILOT_VERSION:-}"
    fi
    echo "benchmark_command=${benchmark_cmd}"
    echo ""
  } > "${LOG_FILE}"
}

run_benchmark() {
  local adb_cmd="$1"
  write_log_header "${adb_cmd}"

  echo "Running benchmark (logging to ${LOG_FILE})..."
  set +e
  adb shell "${adb_cmd}" 2>&1 | tee -a "${LOG_FILE}"
  local exit_code=${PIPESTATUS[0]}
  set -e

  echo "" | tee -a "${LOG_FILE}"
  echo "Log saved to ${LOG_FILE}" >&2
  return "${exit_code}"
}

LOG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-file|--log)
      [[ $# -ge 2 ]] || usage
      LOG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage
fi

MODEL_PATH="$1"
if [[ ! -f "${MODEL_PATH}" ]]; then
  echo "Error: model not found: ${MODEL_PATH}" >&2
  exit 1
fi
MODEL_NAME=$(basename "${MODEL_PATH}")
MODEL_STEM="${MODEL_NAME%.tflite}"

SOC_MODEL=$(adb shell getprop ro.soc.model | tr -d '\r')

# Detect NPU vendor from ro.soc.model (Qualcomm: SM/SW/QCS/...; MediaTek: MT...)
case "${SOC_MODEL}" in
  MT*) NPU_VENDOR=mediatek ;;
  SM*) NPU_VENDOR=qualcomm;;
  *)
    echo "Device detected: ${SOC_MODEL}. Unknown SoC (expected Qualcomm or MediaTek)."
    exit 1
    ;;
esac

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/ondevice_test_${NPU_VENDOR}_${MODEL_STEM}_$(date +%Y%m%d_%H%M%S).log}"

echo "Device detected: ${SOC_MODEL} (${NPU_VENDOR})"
echo "Using bazel-bin: ${BAZEL_BIN}"

if [ "${NPU_VENDOR}" = "qualcomm" ]; then
  if [ "$SOC_MODEL" == "SM8850" ]; then
    QCOM_HTP_VERSION=81
    SOC_ID=87
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM8845" ]; then
    QCOM_HTP_VERSION=81
    SOC_ID=97
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM8750" ]; then
    QCOM_HTP_VERSION=79
    SOC_ID=69
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM8650" ]; then
    QCOM_HTP_VERSION=75
    SOC_ID=57
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM8635" ]; then
    echo "Device detected: ${SOC_MODEL}. The SocModel doesn't support FP16..."
    exit 1
  elif [ "$SOC_MODEL" == "SM8550" ]; then
    QCOM_HTP_VERSION=73
    SOC_ID=43
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM8475" ]; then
    QCOM_HTP_VERSION=69
    SOC_ID=42
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM8450" ]; then
    QCOM_HTP_VERSION=69
    SOC_ID=36
    DSP_ARCH=v${QCOM_HTP_VERSION}
  elif [ "$SOC_MODEL" == "SM7675" ]; then
    echo "Device detected: ${SOC_MODEL}. The SocModel doesn't support FP16..."
    exit 1
  else
    echo "Qualcomm device ${SOC_MODEL} detected; using generic QAIRT push (set QAIRT paths if needed)."
    # HTP stub/skel versions vary by SoC — see litert/vendors/qualcomm/doc/BUILD_INSTRUCTIONS.md
    QCOM_HTP_VERSION="${QCOM_HTP_VERSION:-81}"
    DSP_ARCH=v${QCOM_HTP_VERSION}
  fi
elif [ "${NPU_VENDOR}" = "mediatek" ]; then
  MEDIATEK_PERFORMANCE_MODE=sustained_speed
  # MT6993 requires NeuroPilot v9; other MT* SoCs use the default (v8).
  case "${SOC_MODEL}" in
    MT6993) MEDIATEK_NERUN_PILOT_VERSION=version9 ;;
  esac
fi

TEST_FOLDER=/data/local/tmp/litert_prof
ANDROID_BUILD_FLAGS=(
  -c opt --cxxopt=--std=c++17 --nocheck_visibility --config=android_arm64
  --copt=-DABSL_FLAGS_STRIP_NAMES=0
)
ANDROID_BUILD_HINT=$(
  cat <<EOF
Build Android on-device artifacts from the repo root, then re-run:
  cd ${REPO_ROOT}
  bazel build ${ANDROID_BUILD_FLAGS[*]} //litert/tools:benchmark_model
  bazel build ${ANDROID_BUILD_FLAGS[*]} //litert/c:libLiteRt.so
  bazel build ${ANDROID_BUILD_FLAGS[*]} //litert/vendors/${NPU_VENDOR}/dispatch:dispatch_api_so

Inside Docker, source the Bazel env first:
  source /setup_bazel_env.sh
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/tools:benchmark_model
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/c:libLiteRt.so
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/vendors/${NPU_VENDOR}/dispatch:dispatch_api_so
EOF
)

BENCHMARK_MODEL="$(require_file "litert/tools/benchmark_model" "${ANDROID_BUILD_HINT}")"
LIB_LITERT="$(require_file "litert/c/libLiteRt.so" "${ANDROID_BUILD_HINT}")"
DISPATCH_SO=""

adb shell mkdir -p "${TEST_FOLDER}"
adb push "${BENCHMARK_MODEL}" "${TEST_FOLDER}/"
adb push "${LIB_LITERT}" "${TEST_FOLDER}/"

if [ "${NPU_VENDOR}" = "qualcomm" ]; then
  DISPATCH_SO="$(require_file "litert/vendors/qualcomm/dispatch/libLiteRtDispatch_Qualcomm.so" "${ANDROID_BUILD_HINT}")"
  adb push "${DISPATCH_SO}" "${TEST_FOLDER}/"
  # + QAIRT libs (libQnnHtp.so, stubs, skel, etc.) — see litert/vendors/qualcomm/doc/BUILD_INSTRUCTIONS.md
  adb push "${MODEL_PATH}" "${TEST_FOLDER}/${MODEL_NAME}"

  ADB_BENCHMARK_CMD="export LD_LIBRARY_PATH=${TEST_FOLDER} && export ADSP_LIBRARY_PATH=${TEST_FOLDER} && \
cd ${TEST_FOLDER} && ./benchmark_model \
  --graph=${MODEL_NAME} \
  --use_npu --no_cpu \
  --require_full_delegation \
  --dispatch_library_path=${TEST_FOLDER} \
  --use_profiler=true \
  --num_runs=10 --warmup_runs=1"
  run_benchmark "${ADB_BENCHMARK_CMD}"
  exit $?
elif [ "${NPU_VENDOR}" = "mediatek" ]; then
  DISPATCH_SO="$(require_file "litert/vendors/mediatek/dispatch/libLiteRtDispatch_MediaTek.so" "${ANDROID_BUILD_HINT}")"
  adb push "${DISPATCH_SO}" "${TEST_FOLDER}/"
  adb push "${MODEL_PATH}" "${TEST_FOLDER}/${MODEL_NAME}"

  MEDIATEK_EXTRA_ARGS=""
  if [ -n "${MEDIATEK_NERUN_PILOT_VERSION:-}" ]; then
    MEDIATEK_EXTRA_ARGS="--mediatek_nerun_pilot_version=${MEDIATEK_NERUN_PILOT_VERSION}"
  fi

  ADB_BENCHMARK_CMD="export LD_LIBRARY_PATH=${TEST_FOLDER} && \
cd ${TEST_FOLDER} && ./benchmark_model \
  --graph=${MODEL_NAME} \
  --use_npu --no_cpu \
  --require_full_delegation \
  --dispatch_library_path=${TEST_FOLDER} \
  --mediatek_performance_mode_type=${MEDIATEK_PERFORMANCE_MODE} \
  ${MEDIATEK_EXTRA_ARGS} \
  --use_profiler=true \
  --num_runs=10 --warmup_runs=1"
  run_benchmark "${ADB_BENCHMARK_CMD}"
  exit $?
fi
