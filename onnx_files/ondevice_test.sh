#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-${REPO_ROOT}/bazel-bin}"
QAIRT_SEARCH_ROOT="/home/leyinghu/Documents/rifeprototype/env/qairt"
DEFAULT_QAIRT_ROOT="${QAIRT_SEARCH_ROOT}/2.46.0.260424"
MIN_QNN_SYSTEM_API_MINOR=10

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [--cpu] [--log-file PATH] <model.tflite>

Options:
  --cpu, --accelerator=cpu   Run on CPU only (no NPU dispatch/compiler plugins)

Environment:
  BAZEL_BIN           Path to bazel-bin (default: \${REPO_ROOT}/bazel-bin)
  REPO_ROOT           LiteRT checkout root (default: parent of onnx_files/)
  LOG_FILE            Output log path (default: onnx_files/ondevice_test_<vendor>_<model>_<timestamp>.log)
  LITERT_QAIRT_SDK    Path to unzipped QAIRT SDK (Qualcomm only; or set QAIRT)
  QAIRT               Alias for QAIRT SDK root (Qualcomm only)
                      Auto-selects newest QAIRT >= 2.46 (QNN System API 1.10+)
                      from ${QAIRT_SEARCH_ROOT} or the Bazel-downloaded SDK
  LITERT_USE_CPU      Enable CPU for non-delegated ops (default: true)
  LITERT_REQUIRE_FULL_DELEGATION
                      Fail if any op stays on CPU (default: false; YOLO-style
                      models often delegate only part of the graph)
EOF
  exit 1
}

normalize_qairt_root() {
  local root="$1"
  if [[ -d "${root}/lib/aarch64-android" ]]; then
    echo "${root}"
  elif [[ -d "${root}/latest/lib/aarch64-android" ]]; then
    echo "${root}/latest"
  fi
}

qairt_system_api_minor() {
  local root="$1"
  local header="${root}/include/QNN/System/QnnSystemCommon.h"
  local minor=""

  if [[ ! -f "${header}" ]]; then
    return 1
  fi
  minor="$(awk '/QNN_SYSTEM_API_VERSION_MINOR/ { print $3; exit }' "${header}")"
  [[ -n "${minor}" ]] || return 1
  echo "${minor}"
}

qairt_is_compatible() {
  local root="$1"
  local minor=""

  minor="$(qairt_system_api_minor "${root}")" || return 1
  (( minor >= MIN_QNN_SYSTEM_API_MINOR ))
}

collect_qairt_candidates() {
  local candidate normalized dir

  for candidate in \
    "${LITERT_QAIRT_SDK:-}" \
    "${QAIRT:-}" \
    "${DEFAULT_QAIRT_ROOT}"; do
    [[ -n "${candidate}" ]] || continue
    normalized="$(normalize_qairt_root "${candidate}" || true)"
    [[ -n "${normalized}" ]] && echo "${normalized}"
  done

  while IFS= read -r candidate; do
    candidate="$(dirname "$(dirname "${candidate}")")"
    [[ -n "${candidate}" ]] && echo "${candidate}"
  done < <(find "${REPO_ROOT}/.cache/bazel" -path '*/external/qairt/lib/aarch64-android' -print 2>/dev/null)

  if [[ -d "${QAIRT_SEARCH_ROOT}" ]]; then
    while IFS= read -r dir; do
      normalized="$(normalize_qairt_root "${dir}" || true)"
      [[ -n "${normalized}" ]] && echo "${normalized}"
    done < <(find "${QAIRT_SEARCH_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort -V -r)
  fi
}

resolve_qairt_root() {
  local root minor

  while IFS= read -r root; do
    if qairt_is_compatible "${root}"; then
      minor="$(qairt_system_api_minor "${root}")"
      echo "Selected QAIRT SDK with QNN System API 1.${minor}.0: ${root}" >&2
      echo "${root}"
      return 0
    fi
    if minor="$(qairt_system_api_minor "${root}" 2>/dev/null)"; then
      echo "Skipping QAIRT SDK with QNN System API 1.${minor}.x (need >= 1.${MIN_QNN_SYSTEM_API_MINOR}.0): ${root}" >&2
    fi
  done < <(collect_qairt_candidates | awk '!seen[$0]++')
  return 1
}

push_qairt_libs() {
  local qairt_root android_lib hexagon_lib htp_tag stub_lib skel_lib lib

  if ! qairt_root="$(resolve_qairt_root)"; then
    cat >&2 <<EOF
Error: Qualcomm NPU requires QAIRT runtime libraries on device (libQnnSystem.so, etc.).

LiteRT requires QNN System API >= 1.${MIN_QNN_SYSTEM_API_MINOR}.0 (QAIRT 2.46+).
Your installed SDKs under ${QAIRT_SEARCH_ROOT} are too old (2.43.0 is API 1.7.0).

Download QAIRT 2.46.0.260424 or newer, then either:
  export LITERT_QAIRT_SDK=/path/to/qairt/2.46.0.260424
  ./onnx_files/ondevice_test.sh model.tflite

Or build any Qualcomm target once so Bazel downloads QAIRT into:
  ${REPO_ROOT}/.cache/bazel/.../external/qairt

Manual push for ${SOC_MODEL} (HTP ${QCOM_HTP_VERSION}):
  adb push \${QAIRT}/lib/aarch64-android/libQnnSystem.so ${TEST_FOLDER}/
  adb push \${QAIRT}/lib/aarch64-android/libQnnHtp.so ${TEST_FOLDER}/
  adb push \${QAIRT}/lib/aarch64-android/libQnnHtpPrepare.so ${TEST_FOLDER}/
  adb push \${QAIRT}/lib/aarch64-android/libQnnIr.so ${TEST_FOLDER}/
  adb push \${QAIRT}/lib/aarch64-android/libQnnSaver.so ${TEST_FOLDER}/
  adb push \${QAIRT}/lib/aarch64-android/libQnnHtpV${QCOM_HTP_VERSION}Stub.so ${TEST_FOLDER}/
  adb push \${QAIRT}/lib/hexagon-v${QCOM_HTP_VERSION}/unsigned/libQnnHtpV${QCOM_HTP_VERSION}Skel.so ${TEST_FOLDER}/

See litert/vendors/qualcomm/doc/BUILD_INSTRUCTIONS.md
EOF
    exit 1
  fi

  android_lib="${qairt_root}/lib/aarch64-android"
  hexagon_lib="${qairt_root}/lib/hexagon-v${QCOM_HTP_VERSION}/unsigned"
  htp_tag="V${QCOM_HTP_VERSION}"
  stub_lib="${android_lib}/libQnnHtp${htp_tag}Stub.so"
  skel_lib="${hexagon_lib}/libQnnHtp${htp_tag}Skel.so"

  echo "Using QAIRT SDK: ${qairt_root}"
  QAIRT_ROOT="${qairt_root}"

  for lib in \
    "${android_lib}/libQnnSystem.so" \
    "${android_lib}/libQnnHtp.so" \
    "${android_lib}/libQnnHtpPrepare.so" \
    "${android_lib}/libQnnIr.so" \
    "${android_lib}/libQnnSaver.so" \
    "${stub_lib}" \
    "${skel_lib}"; do
    if [[ ! -f "${lib}" ]]; then
      echo "Error: required QAIRT library not found: ${lib}" >&2
      exit 1
    fi
    adb push "${lib}" "${TEST_FOLDER}/"
  done
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
    echo "compiler_plugin_so=${COMPILER_PLUGIN_SO}"
    if [[ "${NPU_VENDOR}" == "qualcomm" ]]; then
      echo "qcom_htp_version=${QCOM_HTP_VERSION:-}"
      echo "dsp_arch=${DSP_ARCH:-}"
      echo "qairt_root=${QAIRT_ROOT:-}"
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
CPU_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)
      CPU_ONLY=true
      shift
      ;;
    --accelerator=cpu)
      CPU_ONLY=true
      shift
      ;;
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

if [[ "${CPU_ONLY}" == "true" ]]; then
  NPU_VENDOR=cpu
else
  # Detect NPU vendor from ro.soc.model (Qualcomm: SM/SW/QCS/...; MediaTek: MT...)
  case "${SOC_MODEL}" in
    MT*) NPU_VENDOR=mediatek ;;
    SM*) NPU_VENDOR=qualcomm;;
    *)
      echo "Device detected: ${SOC_MODEL}. Unknown SoC (expected Qualcomm or MediaTek)."
      exit 1
      ;;
  esac
fi

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/ondevice_test_${NPU_VENDOR}_${MODEL_STEM}_$(date +%Y%m%d_%H%M%S).log}"

echo "Device detected: ${SOC_MODEL} (${NPU_VENDOR})"
echo "Using bazel-bin: ${BAZEL_BIN}"

if [[ "${CPU_ONLY}" == "true" ]]; then
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

Inside Docker, source the Bazel env first:
  source /setup_bazel_env.sh
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/tools:benchmark_model
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/c:libLiteRt.so
EOF
  )

  BENCHMARK_MODEL="$(require_file "litert/tools/benchmark_model" "${ANDROID_BUILD_HINT}")"
  LIB_LITERT="$(require_file "litert/c/libLiteRt.so" "${ANDROID_BUILD_HINT}")"
  DISPATCH_SO=""
  COMPILER_PLUGIN_SO=""

  adb shell mkdir -p "${TEST_FOLDER}"
  adb push "${BENCHMARK_MODEL}" "${TEST_FOLDER}/"
  adb push "${LIB_LITERT}" "${TEST_FOLDER}/"
  adb push "${MODEL_PATH}" "${TEST_FOLDER}/${MODEL_NAME}"

  BENCHMARK_COMMON_FLAGS="\
  --graph=${MODEL_NAME} \
  --use_npu=false \
  --use_cpu=true \
  --use_profiler=true \
  --num_runs=10 --warmup_runs=1"

  ADB_BENCHMARK_CMD="export LD_LIBRARY_PATH=${TEST_FOLDER} && \
cd ${TEST_FOLDER} && ./benchmark_model ${BENCHMARK_COMMON_FLAGS}"
  run_benchmark "${ADB_BENCHMARK_CMD}"
  exit $?
fi

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
case "${NPU_VENDOR}" in
  qualcomm) COMPILER_PLUGIN_TARGET="qnn_compiler_plugin_so" ;;
  mediatek) COMPILER_PLUGIN_TARGET="compiler_plugin_so" ;;
esac
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
  bazel build ${ANDROID_BUILD_FLAGS[*]} //litert/vendors/${NPU_VENDOR}/compiler:${COMPILER_PLUGIN_TARGET}

Inside Docker, source the Bazel env first:
  source /setup_bazel_env.sh
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/tools:benchmark_model
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/c:libLiteRt.so
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/vendors/${NPU_VENDOR}/dispatch:dispatch_api_so
  bazel \${EXTRA_STARTUP} build ${ANDROID_BUILD_FLAGS[*]} //litert/vendors/${NPU_VENDOR}/compiler:${COMPILER_PLUGIN_TARGET}
EOF
)

BENCHMARK_MODEL="$(require_file "litert/tools/benchmark_model" "${ANDROID_BUILD_HINT}")"
LIB_LITERT="$(require_file "litert/c/libLiteRt.so" "${ANDROID_BUILD_HINT}")"
DISPATCH_SO=""
COMPILER_PLUGIN_SO=""

case "${NPU_VENDOR}" in
  qualcomm)
    DISPATCH_REL="litert/vendors/qualcomm/dispatch/libLiteRtDispatch_Qualcomm.so"
    COMPILER_PLUGIN_REL="litert/vendors/qualcomm/compiler/libLiteRtCompilerPlugin_Qualcomm.so"
    ;;
  mediatek)
    DISPATCH_REL="litert/vendors/mediatek/dispatch/libLiteRtDispatch_MediaTek.so"
    COMPILER_PLUGIN_REL="litert/vendors/mediatek/compiler/libLiteRtCompilerPlugin_MediaTek.so"
    ;;
esac

DISPATCH_SO="$(require_file "${DISPATCH_REL}" "${ANDROID_BUILD_HINT}")"
COMPILER_PLUGIN_SO="$(require_file "${COMPILER_PLUGIN_REL}" "${ANDROID_BUILD_HINT}")"

adb shell mkdir -p "${TEST_FOLDER}"
adb push "${BENCHMARK_MODEL}" "${TEST_FOLDER}/"
adb push "${LIB_LITERT}" "${TEST_FOLDER}/"
adb push "${DISPATCH_SO}" "${TEST_FOLDER}/"
adb push "${COMPILER_PLUGIN_SO}" "${TEST_FOLDER}/"
adb push "${MODEL_PATH}" "${TEST_FOLDER}/${MODEL_NAME}"

LITERT_USE_CPU="${LITERT_USE_CPU:-true}"
LITERT_REQUIRE_FULL_DELEGATION="${LITERT_REQUIRE_FULL_DELEGATION:-false}"

BENCHMARK_COMMON_FLAGS="\
  --graph=${MODEL_NAME} \
  --use_npu=true \
  --use_cpu=${LITERT_USE_CPU} \
  --require_full_delegation=${LITERT_REQUIRE_FULL_DELEGATION} \
  --dispatch_library_path=${TEST_FOLDER} \
  --compiler_plugin_library_path=${TEST_FOLDER} \
  --compiler_cache_path=${TEST_FOLDER} \
  --use_profiler=true \
  --num_runs=10 --warmup_runs=1"

if [ "${NPU_VENDOR}" = "qualcomm" ]; then
  push_qairt_libs
  ADB_BENCHMARK_CMD="export LD_LIBRARY_PATH=${TEST_FOLDER} && export ADSP_LIBRARY_PATH=${TEST_FOLDER} && \
cd ${TEST_FOLDER} && ./benchmark_model ${BENCHMARK_COMMON_FLAGS}"
  run_benchmark "${ADB_BENCHMARK_CMD}"
  exit $?
elif [ "${NPU_VENDOR}" = "mediatek" ]; then
  MEDIATEK_EXTRA_ARGS=""
  if [ -n "${MEDIATEK_NERUN_PILOT_VERSION:-}" ]; then
    MEDIATEK_EXTRA_ARGS="--mediatek_nerun_pilot_version=${MEDIATEK_NERUN_PILOT_VERSION}"
  fi

  ADB_BENCHMARK_CMD="export LD_LIBRARY_PATH=${TEST_FOLDER} && \
cd ${TEST_FOLDER} && ./benchmark_model ${BENCHMARK_COMMON_FLAGS} ${MEDIATEK_EXTRA_ARGS}"
  run_benchmark "${ADB_BENCHMARK_CMD}"
  exit $?
fi
