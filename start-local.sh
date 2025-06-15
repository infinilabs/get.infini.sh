#!/bin/sh
#
# Script to run INFINI Console and INFINI Easysearch locally via Docker.
# Inspired by Elastic's start-local.sh script but tailored for INFINI Labs.
# All operational files (.env, docker-compose.yml) and persisted data
# will be stored under a common base directory.
#
# Version: 1.0.0
#
# Usage: ./start-local.sh [COMMAND] [OPTIONS] [SERVICE_NAMES...]

# Strict mode
set -e # -u removed as it can be problematic with uninitialized vars in pure sh if not careful, rely on ${VAR:-default}
# set -u # Re-enable if all variable accesses are guarded or known to be set.

# --- Configuration: Readonly Constants ---
SCRIPT_BASENAME_ACTUAL=$(basename "$0")
SCRIPT_VERSION="1.0.0"
RECOMMENDED_SCRIPT_FILENAME="start-local.sh"
SCRIPT_DOWNLOAD_URL="https://get.infini.cloud/start-local"
ERROR_LOG_FILENAME="start-local-error.log"

MIN_DOCKER_COMPOSE_V1_VERSION="1.29.0"
MIN_DOCKER_COMPOSE_V2_WAIT_VERSION="2.1.1"
MIN_REQUIRED_DISK_SPACE_GB=1

DEFAULT_CONSOLE_IMAGE="infinilabs/console"
DEFAULT_EASYSEARCH_IMAGE="infinilabs/easysearch"
DEFAULT_EASYSEARCH_NODES=1
DEFAULT_CLUSTER_NAME="ezs-local-dev"
DEFAULT_ADMIN_PASSWORD="ShouldChangeme123."
DEFAULT_SERVICES_TO_START_STR="console easysearch" # Changed from array

CACHE_SUBDIR=".cache"
VERSION_CACHE_FILE="latest_versions.json"
LATEST_VERSIONS_URL="https://release.infinilabs.com/.latest"

DEFAULT_WORK_DIR="startlocal"

# --- Global Variables (Mutable) ---
CONSOLE_IMAGE="$DEFAULT_CONSOLE_IMAGE"
EASYSEARCH_IMAGE="$DEFAULT_EASYSEARCH_IMAGE"
EASYSEARCH_NODES=$DEFAULT_EASYSEARCH_NODES
EASYSEARCH_CLUSTER_NAME="$DEFAULT_CLUSTER_NAME"
CONSOLE_VERSION_TAG=""
EASYSEARCH_VERSION_TAG=""
INITIAL_ADMIN_PASSWORD="$DEFAULT_ADMIN_PASSWORD"
ENABLE_METRICS_AGENT="false" # Use string "true"/"false" for sh
USER_SPECIFIED_WORK_DIR="$DEFAULT_WORK_DIR"
SERVICES_TO_RUN="" # Changed from array

DOCKER_CLI="docker"
DOCKER_COMPOSE_EXEC=""
DOCKER_COMPOSE_UP_CMD=""
DOCKER_COMPOSE_DOWN_NORMAL=""
DOCKER_COMPOSE_LOGS_CMD=""
DOCKER_COMPOSE_DOWN_VOLUMES=""

OS_FAMILY=""
OS_ARCH=""
ABS_WORK_DIR=""
SCRIPT_INVOCATION_CMD=""
IS_LOGGING_ACTIVE="false" # Use string "true"/"false"

# --- Default Values FOR .env content AND for script internal use ---
CONSOLE_CONTAINER_NAME_DEFAULT="infini-console"
CONSOLE_CFG_PATH_IN_CONTAINER="/config"
CONSOLE_DATA_PATH_IN_CONTAINER="/data"
CONSOLE_LOGS_PATH_IN_CONTAINER="/log"
CONSOLE_HOST_CFG_RELPATH="console/config"
CONSOLE_HOST_DATA_RELPATH="console/data"
CONSOLE_HOST_LOGS_RELPATH="console/logs"
CONSOLE_PORT_HOST_DEFAULT=9000
CONSOLE_PORT_CONTAINER_DEFAULT=9000

EASYSEARCH_HTTP_PORT_HOST_DEFAULT=9200
EASYSEARCH_TRANSPORT_PORT_HOST_DEFAULT=9300
EASYSEARCH_INTERNAL_HTTP_PORT_DEFAULT=9200
EASYSEARCH_INTERNAL_TRANSPORT_PORT_DEFAULT=9300
EASYSEARCH_BASE_PATH_IN_CONTAINER="/app/easysearch"
EASYSEARCH_HOST_NODES_BASE_RELPATH="easysearch"
EASYSEARCH_PLUGINS_SUBPATH_IN_CONTAINER="plugins"
EASYSEARCH_CFG_SUBPATH_IN_CONTAINER="config"
EASYSEARCH_DATA_SUBPATH_IN_CONTAINER="data"
EASYSEARCH_LOGS_SUBPATH_IN_CONTAINER="logs"
ES_JAVA_OPTS_DEFAULT="-Xms512m -Xmx512m"

APP_NETWORK_NAME_DEFAULT="infini-local-net"

# --- Helper Functions ---
_log_prefix() {
  level_icon="$1" level_text="$2"
  printf "%s [%s] [%s] [%s]" \
    "${level_icon}" "${level_text}" \
    "${SCRIPT_BASENAME_ACTUAL:-start-local.sh}" \
    "$(date "+%Y-%m-%d %H:%M:%S %Z")"
}
log() { _log_prefix "✅" "INFO" && printf " %s\n" "$*"; }
warn() { _log_prefix "⚠️" "WARN" && printf " %s\n" "$*" >&2; }
error() {
  _log_prefix "❌" "ERROR" && printf " %s\n" "$*" >&2
  services_to_log_csv=""
  actual_svc_names_str=""
  if [ -n "$SERVICES_TO_RUN" ]; then
    _old_ifs="$IFS"; IFS=' '
    set -- $SERVICES_TO_RUN
    IFS="$_old_ifs"
    for svc_in_err in "$@"; do
      if [ "$svc_in_err" = "easysearch" ]; then
        num_nodes_err=${EASYSEARCH_NODES:-$DEFAULT_EASYSEARCH_NODES}
        _i_err=0
        while [ "$_i_err" -lt "$num_nodes_err" ]; do
          actual_svc_names_str="${actual_svc_names_str} easysearch-${_i_err}"
          _i_err=$((_i_err + 1))
        done
      elif [ "$svc_in_err" = "console" ]; then
        actual_svc_names_str="${actual_svc_names_str} ${CONSOLE_CONTAINER_NAME_DEFAULT}"
      else
        actual_svc_names_str="${actual_svc_names_str} $svc_in_err"
      fi
    done
    actual_svc_names_str=$(echo "$actual_svc_names_str" | sed 's/^ *//;s/ *$//') # Trim
    if [ -n "$actual_svc_names_str" ]; then
      services_to_log_csv=$(echo "$actual_svc_names_str" | tr ' ' ',')
    fi
  fi
  if [ -z "$services_to_log_csv" ]; then services_to_log_csv="${CONSOLE_CONTAINER_NAME_DEFAULT},easysearch-0"; fi
  generate_diagnostic_log "$*" "$services_to_log_csv"
  exit 1
}

available() { command -v "$1" >/dev/null 2>&1; }

detect_os_arch() {
  case "$(uname -s)" in
    Linux*) OS_FAMILY="linux";; Darwin*) OS_FAMILY="macos";;
    CYGWIN*|MINGW*|MSYS*) OS_FAMILY="windows";; *) OS_FAMILY="unknown"; warn "Unknown OS: $(uname -s)";;
  esac
  case "$(uname -m)" in
    x86_64) OS_ARCH="amd64";; arm64|aarch64) OS_ARCH="arm64";; *) OS_ARCH="unknown"; warn "Unknown arch: $(uname -m)";;
  esac
  log "OS: ${OS_FAMILY}, Arch: ${OS_ARCH}"
}

compare_versions() {
  v1=$1 v2=$2 old_ifs="$IFS"; IFS='.'
  set -- $v1; v1_major=${1:-0} v1_minor=${2:-0} v1_patch=${3:-0}
  set -- $v2; v2_major=${1:-0} v2_minor=${2:-0} v2_patch=${3:-0}
  IFS="$old_ifs"
  if [ "$v1_major" -lt "$v2_major" ]; then echo "lt"; return; fi; if [ "$v1_major" -gt "$v2_major" ]; then echo "gt"; return; fi
  if [ "$v1_minor" -lt "$v2_minor" ]; then echo "lt"; return; fi; if [ "$v1_minor" -gt "$v2_minor" ]; then echo "gt"; return; fi
  if [ "$v1_patch" -lt "$v2_patch" ]; then echo "lt"; return; fi; if [ "$v1_patch" -gt "$v2_patch" ]; then echo "gt"; return; fi
  echo "eq"
}

detect_and_set_docker_compose_cmds() {
  local compose_v1_ver compose_v2_ver
  if docker compose version --short >/dev/null 2>&1; then # V2 plugin
    DOCKER_COMPOSE_EXEC="docker compose"; compose_v2_ver=$(docker compose version --short)
    log "Found Docker Compose V2 (plugin): $DOCKER_COMPOSE_EXEC, version $compose_v2_ver"
    if [ "$(compare_versions "$compose_v2_ver" "$MIN_DOCKER_COMPOSE_V2_WAIT_VERSION")" != "lt" ]; then
      DOCKER_COMPOSE_UP_CMD="$DOCKER_COMPOSE_EXEC up --wait --remove-orphans"
      log "Compose V2 supports --wait. UP_CMD: $DOCKER_COMPOSE_UP_CMD"
    else
      DOCKER_COMPOSE_UP_CMD="$DOCKER_COMPOSE_EXEC up -d --remove-orphans"
      log "Compose V2 ($compose_v2_ver) < $MIN_DOCKER_COMPOSE_V2_WAIT_VERSION. No --wait. UP_CMD: $DOCKER_COMPOSE_UP_CMD"
    fi
  elif available docker-compose; then # V1 standalone
    DOCKER_COMPOSE_EXEC="docker-compose"
    compose_v1_ver_line=$(docker-compose --version | head -n 1)
    # Try to extract version using sed (more portable than grep -o)
    compose_v1_ver=$(echo "$compose_v1_ver_line" | sed -n 's/.*\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p' || echo "0.0.0")
    if [ "$compose_v1_ver" = "0.0.0" ]; then # Fallback if sed failed
        compose_v1_ver=$(echo "$compose_v1_ver_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {print $i; exit}}' || echo "0.0.0")
    fi
    log "Found Docker Compose V1 (standalone): $DOCKER_COMPOSE_EXEC, version $compose_v1_ver"
    if [ "$(compare_versions "$compose_v1_ver" "$MIN_DOCKER_COMPOSE_V1_VERSION")" = "lt" ]; then
      error "Compose V1 ($compose_v1_ver) < $MIN_DOCKER_COMPOSE_V1_VERSION. Upgrade."; fi
    DOCKER_COMPOSE_UP_CMD="$DOCKER_COMPOSE_EXEC up -d --remove-orphans"
  else error "Docker Compose not found. Please install it."; fi
  DOCKER_COMPOSE_DOWN_NORMAL="$DOCKER_COMPOSE_EXEC down --remove-orphans"
  DOCKER_COMPOSE_LOGS_CMD="$DOCKER_COMPOSE_EXEC logs -f --tail=100"
  DOCKER_COMPOSE_DOWN_VOLUMES="$DOCKER_COMPOSE_EXEC down -v --remove-orphans"
  log "Configured Docker Compose executable: '$DOCKER_COMPOSE_EXEC'"
}

generate_diagnostic_log() {
  error_summary="$1" services_csv="${2:-}" diag_file_path=""
  _work_dir_check="$ABS_WORK_DIR"
  if [ -z "$_work_dir_check" ]; then _work_dir_check="$USER_SPECIFIED_WORK_DIR"; fi

  if [ -n "$_work_dir_check" ]; then
      # Try to create if it's an absolute path or relative from PWD
      _target_diag_dir="$_work_dir_check"
      if ! ( echo "$_target_diag_dir" | grep -q '^/' ) && ! ( echo "$_target_diag_dir" | grep -q '^[A-Za-z]:' ); then
          _target_diag_dir="$PWD/$_target_diag_dir"
      fi
      mkdir -p "$_target_diag_dir" >/dev/null 2>&1
      if [ -w "$_target_diag_dir" ]; then
          diag_file_path="${_target_diag_dir}/${ERROR_LOG_FILENAME}"
      fi
  fi
  if [ -z "$diag_file_path" ]; then
      if [ -w "." ]; then diag_file_path="./${ERROR_LOG_FILENAME}"; else diag_file_path="/tmp/${ERROR_LOG_FILENAME}"; fi
  fi

  # Check SERVICES_TO_RUN existence for display (not critical path)
  _services_run_disp_check="(unknown)"
  if [ -n "${SERVICES_TO_RUN+set}" ]; then # Check if var is set
    if [ -n "$SERVICES_TO_RUN" ]; then
        _services_run_disp_check=$(echo "$SERVICES_TO_RUN" | tr ' ' ',')
    else
        _services_run_disp_check="(empty)"
    fi
  fi

  # Use a temporary file for initial content, then append logs
  # This helps avoid issues with subshells and variable scope for Docker Compose logs
  _diag_tmp_file="${diag_file_path}.tmp"

  { echo "--- Diagnostic Log ($SCRIPT_BASENAME_ACTUAL v$SCRIPT_VERSION) ---"; echo "Date: $(date)"; echo "Error Summary: $error_summary"; echo "";
    echo "--- System Information ---"; echo "OS Family: ${OS_FAMILY:-N/A}, Arch: ${OS_ARCH:-N/A}"; (uname -a || echo "uname -a failed");
    if [ -f /etc/os-release ]; then ( . /etc/os-release && echo "OS Name: ${NAME:-N/A}, Version: ${VERSION_ID:-N/A}" ); fi; echo "";
    echo "--- Docker Information ---"; ($DOCKER_CLI --version || echo "docker --version failed");
    if [ -n "$DOCKER_COMPOSE_EXEC" ]; then ($DOCKER_COMPOSE_EXEC version || echo "$DOCKER_COMPOSE_EXEC version failed"); else echo "Compose exec not set."; fi;
    ($DOCKER_CLI info || echo "docker info failed"); echo "";
    echo "--- Script Configuration ---"; echo "USER_SPECIFIED_WORK_DIR: $USER_SPECIFIED_WORK_DIR"; echo "ABS_WORK_DIR: ${ABS_WORK_DIR:-Not Set}";
    echo "CONSOLE_IMAGE: $CONSOLE_IMAGE:$CONSOLE_VERSION_TAG"; echo "EASYSEARCH_IMAGE: $EASYSEARCH_IMAGE:$EASYSEARCH_VERSION_TAG";
    echo "EASYSEARCH_NODES: $EASYSEARCH_NODES"; echo "INITIAL_ADMIN_PASSWORD: (hidden)"; echo "ENABLE_METRICS_AGENT: $ENABLE_METRICS_AGENT";
    echo "SERVICES_TO_RUN (meta-names): $_services_run_disp_check"; echo "Services for logs in report: ${services_csv:-all available}"; echo "";
  } > "$_diag_tmp_file"

  if [ -n "$services_csv" ] && [ -n "$DOCKER_COMPOSE_EXEC" ] && [ -n "$ABS_WORK_DIR" ] && [ -f "${ABS_WORK_DIR}/docker-compose.yml" ]; then
    echo "--- Docker Compose Logs (last 200 lines) ---" >> "$_diag_tmp_file";
    orig_pwd_diag=$(pwd)
    if cd "$ABS_WORK_DIR"; then
      _old_ifs_diag="$IFS"; IFS=','
      set -- $services_csv # $services_csv must not contain globs
      # DOCKER_COMPOSE_EXEC can be "docker compose" or "docker-compose"
      # DOCKER_COMPOSE_LOGS_CMD has other options too
      # Simplest robust way for execution:
      _cmd_part1=$(echo "$DOCKER_COMPOSE_EXEC" | awk '{print $1}')
      _cmd_part2=$(echo "$DOCKER_COMPOSE_EXEC" | awk '{print $2}') # empty if V1
      if [ -z "$_cmd_part2" ]; then
          eval "$_cmd_part1 logs --no-color --timestamps --tail=\"200\" \"\$@\" >> \"$_diag_tmp_file\" 2>&1" || echo "Failed logs: $services_csv" >> "$_diag_tmp_file"
      else
          eval "$_cmd_part1 \"$_cmd_part2\" logs --no-color --timestamps --tail=\"200\" \"\$@\" >> \"$_diag_tmp_file\" 2>&1" || echo "Failed logs: $services_csv" >> "$_diag_tmp_file"
      fi
      IFS="$_old_ifs_diag"
      cd "$orig_pwd_diag" || warn "Could not cd back from $ABS_WORK_DIR (diag logs)";
    else echo "Could not cd to $ABS_WORK_DIR for diag logs." >> "$_diag_tmp_file"; fi
  elif [ -n "$services_csv" ]; then echo "Skipping Docker Compose logs: Requirements not met." >> "$_diag_tmp_file"; fi

  mv "$_diag_tmp_file" "$diag_file_path" 2>/dev/null || cp "$_diag_tmp_file" "$diag_file_path" 2>/dev/null || rm "$_diag_tmp_file"
  log "Diagnostic log generated at: $diag_file_path"
}


# --- Signal and Exit Handlers ---
handle_signal() {
  signal_name="$1"
  warn "Received signal $signal_name."
  if [ "$IS_LOGGING_ACTIVE" = "true" ] && [ "$signal_name" = "INT" ]; then
    log "Ctrl+C during 'logs': Exiting log view only."
    # Do not call cmd_down here for logs interruption
  elif [ -n "$DOCKER_COMPOSE_EXEC" ] && [ -n "$ABS_WORK_DIR" ] && [ -d "$ABS_WORK_DIR" ]; then
    log "Signal ($signal_name) received. Attempting to stop services via cmd_down..."
    cmd_down # This can be problematic if called from within a trap that itself is part of cmd_down implicitly.
             # However, cmd_down is mostly calling docker-compose, which should be fine.
  else
    log "Signal ($signal_name) received. Cannot perform Docker cleanup (Compose/ABS_WORK_DIR not ready)."
  fi
  log "Exiting due to $signal_name."
  trap - "$signal_name" # Remove this specific trap
  kill -s "$signal_name" "$$" # Re-send signal to self for default shell exit code
}
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

handle_final_script_exit() {
  final_status=$?
  IS_LOGGING_ACTIVE="false" # Ensure flag is reset

  if [ $final_status -ne 0 ]; then
    if [ $final_status -eq 130 ]; then _log_prefix "🏁" "EXIT" && printf " Script interrupted by user (SIGINT), exit status %d.\n" "$final_status";
    elif [ $final_status -eq 143 ]; then _log_prefix "🏁" "EXIT" && printf " Script terminated by signal (SIGTERM), exit status %d.\n" "$final_status";
    else _log_prefix "⁉️" "EXIT" && printf " Script exited with error, status %d. Diagnostic log may exist.\n" "$final_status"; fi
  else _log_prefix "🏁" "EXIT" && printf " Script finished successfully.\n"; fi
}
trap 'handle_final_script_exit' EXIT


# --- Version Fetching and Processing ---
process_version_tag() { v="$1"; echo "$v" | sed 's/-[0-9]*$//'; }

load_or_fetch_default_product_versions() {
  local cache_base_dir versions_data src_msg fetched_console_ver fetched_es_ver curl_data cache_file
  cache_base_dir=""
  versions_data="" src_msg="" fetched_console_ver="" fetched_es_ver=""

  if [ -n "$ABS_WORK_DIR" ]; then cache_base_dir="$ABS_WORK_DIR";
  else
    case "$USER_SPECIFIED_WORK_DIR" in
      /* | [A-Za-z]:*) cache_base_dir="$USER_SPECIFIED_WORK_DIR" ;;
      *) cache_base_dir="$PWD/$USER_SPECIFIED_WORK_DIR" ;;
    esac
  fi
  mkdir -p "${cache_base_dir}/${CACHE_SUBDIR}" || warn "Could not create cache dir."
  cache_file="${cache_base_dir}/${CACHE_SUBDIR}/${VERSION_CACHE_FILE}"

  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then versions_data=$(cat "$cache_file"); src_msg="local cache"; log "Versions from $src_msg: $cache_file"; fi
  if [ -z "$versions_data" ]; then
    log "Fetching latest versions from ${LATEST_VERSIONS_URL}..."
    if curl_data=$(curl -fsSL "$LATEST_VERSIONS_URL"); then
      versions_data="$curl_data"; src_msg="network (${LATEST_VERSIONS_URL})"
      if [ -n "$versions_data" ]; then
        if mkdir -p "$(dirname "$cache_file")" && [ -w "$(dirname "$cache_file")" ]; then echo "$versions_data" > "$cache_file"; log "Versions cached: $cache_file";
        else warn "Cache directory $(dirname "$cache_file") not writable. Not caching."; fi
      else warn "Fetched empty version data. Not caching."; fi
    else warn "Failed to fetch versions. Curl exit: $?. Source: $src_msg"; src_msg="network (failed)"; fi
  fi
  if [ -n "$versions_data" ]; then
    if available jq; then
      fetched_console_ver=$(echo "$versions_data" | jq -r '.console // empty')
      fetched_es_ver=$(echo "$versions_data" | jq -r '.easysearch // empty')
    else
      warn "jq not found. Using sed for parsing versions.";
      fetched_console_ver=$(echo "$versions_data" | sed -n 's/.*"console": *"\([^"]*\)".*/\1/p')
      fetched_es_ver=$(echo "$versions_data" | sed -n 's/.*"easysearch": *"\([^"]*\)".*/\1/p')
    fi
  fi
  fetched_console_ver=${fetched_console_ver:-"1.29.5"}; fetched_console_ver=$(process_version_tag "$fetched_console_ver")
  fetched_es_ver=${fetched_es_ver:-"1.12.3"}; fetched_es_ver=$(process_version_tag "$fetched_es_ver")
  log "Defaults determined (source: $src_msg): Console=$fetched_console_ver, Easysearch=$fetched_es_ver"
  if [ -z "$CONSOLE_VERSION_TAG" ]; then CONSOLE_VERSION_TAG="$fetched_console_ver"; log "Global CONSOLE_VERSION_TAG set: $CONSOLE_VERSION_TAG"; fi
  if [ -z "$EASYSEARCH_VERSION_TAG" ]; then EASYSEARCH_VERSION_TAG="$fetched_es_ver"; log "Global EASYSEARCH_VERSION_TAG set: $EASYSEARCH_VERSION_TAG"; fi
}

ensure_product_versions() {
  log "Ensuring product versions are set..."
  if [ -z "$CONSOLE_VERSION_TAG" ] || [ -z "$EASYSEARCH_VERSION_TAG" ]; then
    log "Version tags empty/partial. Loading/fetching defaults..."
    load_or_fetch_default_product_versions
  else
    log "User versions: Console=${CONSOLE_VERSION_TAG}, Easysearch=${EASYSEARCH_VERSION_TAG}. Processing."
    CONSOLE_VERSION_TAG=$(process_version_tag "$CONSOLE_VERSION_TAG")
    EASYSEARCH_VERSION_TAG=$(process_version_tag "$EASYSEARCH_VERSION_TAG")
  fi
  CONSOLE_VERSION_TAG=${CONSOLE_VERSION_TAG:-"1.29.5"} # Final fallback
  EASYSEARCH_VERSION_TAG=${EASYSEARCH_VERSION_TAG:-"1.12.3"}
  log "Final versions for use: Console=${CONSOLE_VERSION_TAG}, Easysearch=${EASYSEARCH_VERSION_TAG}"
}

# --- File Generation and Configuration ---
copy_initial_data_from_image() {
  service_name="$1" image_full_name="$2" container_src_path="$3" host_target_path="$4"
  extra_env="${5:-}" init_cmd="${6:-}"
  host_uid=$(id -u); host_gid=$(id -g)

  log "Copying initial '$service_name' config: $image_full_name ($container_src_path) -> $host_target_path"
  [ -n "$extra_env" ] && log "  With env: $extra_env"; [ -n "$init_cmd" ] && log "  With init cmd: $init_cmd"

  host_target_parent=$(dirname "$host_target_path")
  if ! mkdir -p "$host_target_parent" 2>/dev/null; then
    if ! sudo mkdir -p "$host_target_parent" || ! sudo chown "$host_uid:$host_gid" "$host_target_parent"; then
      error "Failed to create/chown parent dir '$host_target_parent' for '$host_target_path'."
    fi; log "Created/chowned parent dir '$host_target_parent' via sudo."; fi

  tmp_dir_in_container="/tmp/cfg_extract_$$"; target_basename=$(basename "$host_target_path")
  cmd_in_ctr="set -e; mkdir -p '${tmp_dir_in_container}'; "
  [ -n "$init_cmd" ] && cmd_in_ctr="${cmd_in_ctr}${init_cmd} && "
  cmd_in_ctr="${cmd_in_ctr}cp -a '${container_src_path}/.' '${tmp_dir_in_container}/' && "
  cmd_in_ctr="${cmd_in_ctr}chown -R ${host_uid}:${host_gid} '${tmp_dir_in_container}' && "
  cmd_in_ctr="${cmd_in_ctr}find '${tmp_dir_in_container}' -type d -exec chmod 755 {} + && "
  cmd_in_ctr="${cmd_in_ctr}find '${tmp_dir_in_container}' -type f -exec chmod 644 {} + && "
  cmd_in_ctr="${cmd_in_ctr}mkdir -p '/work_mount/${target_basename}' && cp -a '${tmp_dir_in_container}/.' '/work_mount/${target_basename}/' && rm -rf '${tmp_dir_in_container}'"

  _docker_run_args=""
  platform_arg=""
  # Check image_full_name contains infinilabs/
  case "$image_full_name" in
    *infinilabs/*)
      if [ "$OS_FAMILY" = "windows" ]; then
        if [ "$OS_ARCH" = "arm64" ]; then platform_arg="linux/arm64"; else platform_arg="linux/amd64"; fi
        log "  On Windows, using --platform $platform_arg for $image_full_name"
        _docker_run_args="$_docker_run_args --platform $platform_arg"
      fi
      ;;
  esac
  if [ -n "$extra_env" ]; then _docker_run_args="$_docker_run_args -e \"$extra_env\""; fi

  log "  Attempting copy for '$service_name' via temp container..."
  # Using eval for complex command construction with variable arguments
  # Ensure variables in cmd_in_ctr are properly quoted if they could contain shell metacharacters (they are paths here, should be safe)
  # Use unquoted $DOCKER_CLI for word splitting if it's e.g. "sudo docker"
  eval "$DOCKER_CLI run --rm --user root $_docker_run_args -v \"${host_target_parent}:/work_mount\" --entrypoint sh \"$image_full_name\" -c \"$cmd_in_ctr\""
  _copy_status=$?

  if [ "$_copy_status" -ne 0 ]; then
    warn "  Failed to copy '$service_name' config. App may use defaults or fail."
    if ! mkdir -p "$host_target_path"; then sudo mkdir -p "$host_target_path" || true; fi; return 1; fi
  log "  Successfully copied '$service_name' config to '$host_target_path'."
  return 0
}

prepare_initial_data() {
  log "Preparing initial configurations in $ABS_WORK_DIR..."
  # Check if "console" is in SERVICES_TO_RUN string
  case " $SERVICES_TO_RUN " in
    *" console "*)
      console_cfg_rel="$CONSOLE_HOST_CFG_RELPATH"
      console_cfg_abs="${ABS_WORK_DIR}/${console_cfg_rel}"
      if [ ! -d "$console_cfg_abs" ]; then
        log "Console cfg dir '$console_cfg_abs' missing. Copying..."
        copy_initial_data_from_image "Console" "${CONSOLE_IMAGE}:${CONSOLE_VERSION_TAG}" \
          "$CONSOLE_CFG_PATH_IN_CONTAINER" "$console_cfg_abs" "" "" || warn "Console config copy failed."
      else log "Console cfg dir '$console_cfg_abs' exists."; fi
    ;;
  esac

  # Check if "easysearch" is in SERVICES_TO_RUN string
  case " $SERVICES_TO_RUN " in
    *" easysearch "*)
      es_nodes_base_rel="$EASYSEARCH_HOST_NODES_BASE_RELPATH"

      es_cfg_subpath_rel="$EASYSEARCH_CFG_SUBPATH_IN_CONTAINER"
      es_data_subpath_rel="$EASYSEARCH_DATA_SUBPATH_IN_CONTAINER"
      es_plugins_subpath_rel="$EASYSEARCH_PLUGINS_SUBPATH_IN_CONTAINER"

      es_cfg_in_image_abs="${EASYSEARCH_BASE_PATH_IN_CONTAINER}/${es_cfg_subpath_rel}"
      es_data_in_image_abs="${EASYSEARCH_BASE_PATH_IN_CONTAINER}/${es_data_subpath_rel}"
      es_plugins_in_image_abs="${EASYSEARCH_BASE_PATH_IN_CONTAINER}/${es_plugins_subpath_rel}"

      es_init_cmd_str="bin/initialize.sh -s >/dev/null 2>&1"
      es_cp_env_str="EASYSEARCH_INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD}"

      if [ "$EASYSEARCH_NODES" -eq 1 ]; then
        es1_cfg_abs="${ABS_WORK_DIR}/${es_nodes_base_rel}/${es_cfg_subpath_rel}"
        node0_env_abs="${ABS_WORK_DIR}/${es_nodes_base_rel}/easysearch-node-0.env"
        if [ ! -d "$es1_cfg_abs" ]; then
          log "EZS (1-node) cfg dir '$es1_cfg_abs' missing. Copying..."
          copy_initial_data_from_image "EZS (1-node)" "${EASYSEARCH_IMAGE}:${EASYSEARCH_VERSION_TAG}" \
            "$es_cfg_in_image_abs" "$es1_cfg_abs" "$es_cp_env_str" "$es_init_cmd_str" || warn "EZS (1-node) config copy failed."
        else log "EZS (1-node) cfg dir '$es1_cfg_abs' exists."; fi
        if [ ! -f "$node0_env_abs" ]; then mkdir -p "$(dirname "$node0_env_abs")"; echo "node.name=easysearch-0" > "$node0_env_abs"; fi
      else # Multi-node
        tmp_base_es_cfg_abs="${ABS_WORK_DIR}/${es_nodes_base_rel}/_base_config_temp_from_image"
        base_cfg_src_for_nodes=""
        any_node_cfg_miss="false"
        _i=0; _limit=$((EASYSEARCH_NODES - 1))
        while [ "$_i" -le "$_limit" ]; do
          if [ ! -d "${ABS_WORK_DIR}/${es_nodes_base_rel}/easysearch-${_i}/${es_cfg_subpath_rel}" ]; then any_node_cfg_miss="true"; break; fi
          _i=$((_i + 1))
        done

        if [ "$any_node_cfg_miss" = "true" ]; then
          log "At least one EZS node cfg missing. Preparing base from image..."
          if [ ! -d "$tmp_base_es_cfg_abs" ]; then
            if copy_initial_data_from_image "EZS (base multi)" "${EASYSEARCH_IMAGE}:${EASYSEARCH_VERSION_TAG}" \
              "$es_cfg_in_image_abs" "$tmp_base_es_cfg_abs" "$es_cp_env_str" "$es_init_cmd_str"; then
              base_cfg_src_for_nodes="$tmp_base_es_cfg_abs"
            else
              error "Failed to prepare base EZS config from image."
            fi
          else log "Temp base EZS cfg '$tmp_base_es_cfg_abs' exists."; base_cfg_src_for_nodes="$tmp_base_es_cfg_abs"; fi
          if [ -z "$base_cfg_src_for_nodes" ]; then error "Base EZS config source invalid."; fi

          _i=0
          while [ "$_i" -le "$_limit" ]; do
            node_dir_name="node-${_i}"
            node_cfg_abs="${ABS_WORK_DIR}/${es_nodes_base_rel}/easysearch-${_i}/${es_cfg_subpath_rel}"
            node_env_abs="${ABS_WORK_DIR}/${es_nodes_base_rel}/easysearch-${node_dir_name}.env"
            if [ ! -d "$node_cfg_abs" ]; then
              if [ -n "$base_cfg_src_for_nodes" ] && [ -d "$base_cfg_src_for_nodes" ]; then
                log "EZS node-$_i cfg '$node_cfg_abs' missing. Copying from '$base_cfg_src_for_nodes'..."
                mkdir -p "$(dirname "$node_cfg_abs")"
                # Use cp -Rp for better portability than -a
                if ! cp -Rp "$base_cfg_src_for_nodes/." "$node_cfg_abs/" 2>/dev/null; then
                  warn "  cp for node-$_i failed. Retrying with sudo...";
                  if ! sudo cp -Rp "$base_cfg_src_for_nodes/." "$node_cfg_abs/"; then error "  sudo cp for node-$_i to '$node_cfg_abs' failed."; fi
                  log "  Copied for node-$_i with sudo." && warn "  Node-$_i cfg files now root-owned.";
                else log "  Copied for node-$_i without sudo."; fi
              else warn "  Base cfg '$base_cfg_src_for_nodes' N/A for node-$_i. Ensuring dir '$node_cfg_abs' exists."; mkdir -p "$node_cfg_abs"; fi
            else log "EZS node-$_i cfg '$node_cfg_abs' exists."; fi
            if [ ! -f "$node_env_abs" ]; then mkdir -p "$(dirname "$node_env_abs")"; echo "node.name=easysearch-${_i}" > "$node_env_abs"; fi
            _i=$((_i + 1))
          done
        fi
      fi
    ;;
  esac
}

generate_env_file() {
  log "Generating .env file at ${ABS_WORK_DIR}/.env ... ⚙️"
  metrics_server_val=""
  if [ "$ENABLE_METRICS_AGENT" = "true" ]; then
    metrics_server_val="http://\${CONSOLE_CONTAINER_NAME}:\${CONSOLE_PORT_CONTAINER}"
  fi

  cat > "${ABS_WORK_DIR}/.env" <<-EOF
# Generated by $SCRIPT_BASENAME_ACTUAL v$SCRIPT_VERSION in ${ABS_WORK_DIR}
RUNNER_OS_FAMILY=${OS_FAMILY}
RUNNER_HOST_ARCH=${OS_ARCH}
WORK_DIR_ABS=${ABS_WORK_DIR}
APP_NETWORK_NAME=${APP_NETWORK_NAME_DEFAULT}
CONSOLE_IMAGE=${CONSOLE_IMAGE}
CONSOLE_VERSION_TAG=${CONSOLE_VERSION_TAG}
CONSOLE_CONTAINER_NAME=${CONSOLE_CONTAINER_NAME_DEFAULT}
CONSOLE_PORT_HOST=${CONSOLE_PORT_HOST_DEFAULT}
CONSOLE_PORT_CONTAINER=${CONSOLE_PORT_CONTAINER_DEFAULT}
CONSOLE_HOST_CONFIG_SUBPATH_REL=${CONSOLE_HOST_CFG_RELPATH}
CONSOLE_HOST_DATA_SUBPATH_REL=${CONSOLE_HOST_DATA_RELPATH}
CONSOLE_HOST_LOGS_SUBPATH_REL=${CONSOLE_HOST_LOGS_RELPATH}
CONSOLE_CONTAINER_CONFIG_PATH=${CONSOLE_CFG_PATH_IN_CONTAINER}
CONSOLE_CONTAINER_DATA_PATH=${CONSOLE_DATA_PATH_IN_CONTAINER}
CONSOLE_CONTAINER_LOGS_PATH=${CONSOLE_LOGS_PATH_IN_CONTAINER}
EASYSEARCH_IMAGE=${EASYSEARCH_IMAGE}
EASYSEARCH_VERSION_TAG=${EASYSEARCH_VERSION_TAG}
EASYSEARCH_NODES=${EASYSEARCH_NODES}
EASYSEARCH_CLUSTER_NAME=${EASYSEARCH_CLUSTER_NAME}
EASYSEARCH_INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD}
EASYSEARCH_HTTP_PORT_HOST=${EASYSEARCH_HTTP_PORT_HOST_DEFAULT}
EASYSEARCH_TRANSPORT_PORT_HOST=${EASYSEARCH_TRANSPORT_PORT_HOST_DEFAULT}
EASYSEARCH_INTERNAL_HTTP_PORT=${EASYSEARCH_INTERNAL_HTTP_PORT_DEFAULT}
EASYSEARCH_INTERNAL_TRANSPORT_PORT=${EASYSEARCH_INTERNAL_TRANSPORT_PORT_DEFAULT}
ES_JAVA_OPTS_DEFAULT="${ES_JAVA_OPTS_DEFAULT}"
EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL=${EASYSEARCH_HOST_NODES_BASE_RELPATH}
EASYSEARCH_BASE_PATH_IN_CONTAINER=${EASYSEARCH_BASE_PATH_IN_CONTAINER}
EASYSEARCH_CONTAINER_CONFIG_SUBPATH=${EASYSEARCH_CFG_SUBPATH_IN_CONTAINER}
EASYSEARCH_CONTAINER_DATA_SUBPATH=${EASYSEARCH_DATA_SUBPATH_IN_CONTAINER}
EASYSEARCH_CONTAINER_LOGS_SUBPATH=${EASYSEARCH_LOGS_SUBPATH_IN_CONTAINER}
METRICS_WITH_AGENT=${ENABLE_METRICS_AGENT}
METRICS_CONFIG_SERVER=${metrics_server_val}
EOF
  log ".env file generated at ${ABS_WORK_DIR}/.env 📄"
}

generate_docker_compose_file() {
  log "Generating docker-compose.yml at ${ABS_WORK_DIR}/docker-compose.yml ... ⚙️"
  num_es_nodes=$EASYSEARCH_NODES
  es_discovery_seeds="" es_initial_masters=""

  case " $SERVICES_TO_RUN " in
    *" easysearch "*)
      if [ "$num_es_nodes" -gt 0 ]; then
        _i=0; _limit=$((num_es_nodes - 1))
        while [ "$_i" -le "$_limit" ]; do
          es_node_svc_name_iter="easysearch-${_i}"
          if [ -z "$es_discovery_seeds" ]; then es_discovery_seeds="${es_node_svc_name_iter}:\${EASYSEARCH_INTERNAL_TRANSPORT_PORT}"; else es_discovery_seeds="${es_discovery_seeds},${es_node_svc_name_iter}:\${EASYSEARCH_INTERNAL_TRANSPORT_PORT}"; fi
          if [ -z "$es_initial_masters" ]; then es_initial_masters="${es_node_svc_name_iter}"; else es_initial_masters="${es_initial_masters},${es_node_svc_name_iter}"; fi
          _i=$((_i + 1))
        done
      fi
    ;;
  esac

  cat > "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
# Generated by $SCRIPT_BASENAME_ACTUAL (v$SCRIPT_VERSION)

x-easysearch-node-common: &easysearch-node-common
  image: \${EASYSEARCH_IMAGE}:\${EASYSEARCH_VERSION_TAG}
  environment:
    - cluster.name=\${EASYSEARCH_CLUSTER_NAME}
    - discovery.seed_hosts=${es_discovery_seeds}
    - cluster.initial_master_nodes=${es_initial_masters}
    - http.port=\${EASYSEARCH_INTERNAL_HTTP_PORT}
    - transport.port=\${EASYSEARCH_INTERNAL_TRANSPORT_PORT}
    - "ES_JAVA_OPTS=\${ES_JAVA_OPTS_DEFAULT}"
    - EASYSEARCH_INITIAL_ADMIN_PASSWORD=\${EASYSEARCH_INITIAL_ADMIN_PASSWORD}
  ulimits: { memlock: { soft: -1, hard: -1 }, nofile: { soft: 65536, hard: 65536 } }
  networks: [ "\${APP_NETWORK_NAME}" ]
  healthcheck:
    test: ["CMD-SHELL", "curl -sIk https://admin:\${EASYSEARCH_INITIAL_ADMIN_PASSWORD}@localhost:\${EASYSEARCH_INTERNAL_HTTP_PORT}/_cluster/health?local=true 2>&1 || exit 1"]
    interval: 15s
    timeout: 10s
    retries: 20
    start_period: 60s

services:
EOF

  case " $SERVICES_TO_RUN " in
    *" console "*)
    cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
  console:
    image: \${CONSOLE_IMAGE}:\${CONSOLE_VERSION_TAG}
    container_name: \${CONSOLE_CONTAINER_NAME}
    ports: ["\${CONSOLE_PORT_HOST}:\${CONSOLE_PORT_CONTAINER}"]
    volumes:
      - "./\${CONSOLE_HOST_CONFIG_SUBPATH_REL}:\${CONSOLE_CONTAINER_CONFIG_PATH}"
      - "./\${CONSOLE_HOST_DATA_SUBPATH_REL}:\${CONSOLE_CONTAINER_DATA_PATH}"
      - "./\${CONSOLE_HOST_LOGS_SUBPATH_REL}:\${CONSOLE_CONTAINER_LOGS_PATH}"
    networks: [ "\${APP_NETWORK_NAME}" ]
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -qS -t1 --timeout=3 http://localhost:\${CONSOLE_PORT_CONTAINER}/health 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
EOF
    case " $SERVICES_TO_RUN " in
      *" easysearch "*)
        if [ "$num_es_nodes" -gt 0 ]; then
          cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
    depends_on:
EOF
          _i=0; _limit=$((num_es_nodes - 1))
          while [ "$_i" -le "$_limit" ]; do
            cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
      easysearch-${_i}:
        condition: service_healthy
EOF
            _i=$((_i + 1))
          done
        fi
        ;;
    esac
    echo "" >> "${ABS_WORK_DIR}/docker-compose.yml"
    ;;
  esac

  case " $SERVICES_TO_RUN " in
    *" easysearch "*)
      if [ "$num_es_nodes" -gt 0 ]; then
        _i=0; _limit=$((num_es_nodes - 1))
        while [ "$_i" -le "$_limit" ]; do
          es_node_svc_name="easysearch-${_i}"
          es_node_env_file_rel_path="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/easysearch-node-${_i}.env"
          es_vol_cfg_src_rel="" es_vol_data_src_rel="" es_vol_logs_src_rel=""
          if [ "$num_es_nodes" -eq 1 ]; then
            es_vol_cfg_src_rel="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/\${EASYSEARCH_CONTAINER_CONFIG_SUBPATH}"
            es_vol_data_src_rel="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/\${EASYSEARCH_CONTAINER_DATA_SUBPATH}"
            es_vol_logs_src_rel="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/\${EASYSEARCH_CONTAINER_LOGS_SUBPATH}"
          else
            es_vol_cfg_src_rel="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/${es_node_svc_name}/\${EASYSEARCH_CONTAINER_CONFIG_SUBPATH}"
            es_vol_data_src_rel="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/${es_node_svc_name}/\${EASYSEARCH_CONTAINER_DATA_SUBPATH}"
            es_vol_logs_src_rel="./\${EASYSEARCH_HOST_NODES_BASE_SUBPATH_REL}/${es_node_svc_name}/\${EASYSEARCH_CONTAINER_LOGS_SUBPATH}"
          fi
          cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
  ${es_node_svc_name}:
    <<: *easysearch-node-common
    container_name: ${es_node_svc_name}
    env_file: [ "${es_node_env_file_rel_path}" ]
    volumes:
      - "${es_vol_cfg_src_rel}:\${EASYSEARCH_BASE_PATH_IN_CONTAINER}/\${EASYSEARCH_CONTAINER_CONFIG_SUBPATH}"
      - "${es_vol_data_src_rel}:\${EASYSEARCH_BASE_PATH_IN_CONTAINER}/\${EASYSEARCH_CONTAINER_DATA_SUBPATH}"
      - "${es_vol_logs_src_rel}:\${EASYSEARCH_BASE_PATH_IN_CONTAINER}/\${EASYSEARCH_CONTAINER_LOGS_SUBPATH}"
EOF
          if [ $_i -eq 0 ]; then cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
    ports:
      - "\${EASYSEARCH_HTTP_PORT_HOST}:\${EASYSEARCH_INTERNAL_HTTP_PORT}"
      - "\${EASYSEARCH_TRANSPORT_PORT_HOST}:\${EASYSEARCH_INTERNAL_TRANSPORT_PORT}"
EOF
          fi
          if [ "$ENABLE_METRICS_AGENT" = "true" ]; then cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF
    environment:
      - METRICS_WITH_AGENT=\${METRICS_WITH_AGENT}
      - METRICS_CONFIG_SERVER=\${METRICS_CONFIG_SERVER}
EOF
          fi; echo "" >> "${ABS_WORK_DIR}/docker-compose.yml"
          _i=$((_i + 1))
        done
      fi
      ;;
  esac

  cat >> "${ABS_WORK_DIR}/docker-compose.yml" <<-EOF

networks:
  ${APP_NETWORK_NAME}: # Use var directly as key is also fine
    driver: bridge
    name: \${APP_NETWORK_NAME}
EOF
  log "Generated docker-compose.yml at ${ABS_WORK_DIR}/docker-compose.yml 📄"
}


# --- System Prerequisite Checks ---
check_system_requirements() {
  df_target_dir="${1:-$PWD}"
  log "Checking system requirements (disk space target: $df_target_dir)..."
  log "  Checking disk space (min ${MIN_REQUIRED_DISK_SPACE_GB}GB)..."
  local available_gb_df df_out
  if available df && available awk; then
    df_out=$(df -k "$df_target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if echo "$df_out" | grep -qE '^[0-9]+$'; then available_gb_df=$((df_out / 1024 / 1024));
      if [ "$available_gb_df" -lt "$MIN_REQUIRED_DISK_SPACE_GB" ]; then warn "  Disk space (${available_gb_df}GB) < recommended (${MIN_REQUIRED_DISK_SPACE_GB}GB).";
      else log "  Disk space OK (${available_gb_df}GB)."; fi
    else warn "  Could not parse 'df' output: $df_out"; fi
  else warn "  'df' or 'awk' not found. Skipping disk space check."; fi
  available curl || error "curl is required."; log "  Command curl found."
  available "$DOCKER_CLI" || error "Docker CLI ($DOCKER_CLI) required."; log "  Command $DOCKER_CLI found."
  if ! "$DOCKER_CLI" info > /dev/null 2>&1; then error "Docker daemon not running/responsive."; fi; log "  Docker daemon responsive."
  detect_and_set_docker_compose_cmds
  log "All system requirements checks passed."
}


# --- Command Implementations ---
cmd_up() {
  log "Ensuring product versions are set..."
  ensure_product_versions
  log "Starting services: $SERVICES_TO_RUN in $ABS_WORK_DIR... 🚀"

  if [ -d "$ABS_WORK_DIR" ] && [ -f "${ABS_WORK_DIR}/docker-compose.yml" ]; then
    warn "Existing installation in '$ABS_WORK_DIR'. Forcing stop and removal..."
    cmd_down
  fi

  original_pwd_up=$(pwd)
  if ! cd "$ABS_WORK_DIR"; then error "Cannot cd to '$ABS_WORK_DIR'"; fi
  log "Working directory: $(pwd)"

  generate_env_file

  if [ -f "./.env" ]; then
    log "Sourcing .env file: $PWD/.env"
    # For `sh`, `set -a` (allexport) is generally available. `-u` was disabled globally for sh.
    set -a; . "./.env"; set +a;
  else warn ".env not found at $PWD/.env for sourcing."; fi

  prepare_initial_data
  generate_docker_compose_file

  log "Host directories for persistence (under $PWD):"
  case " $SERVICES_TO_RUN " in
    *" console "*)
      log "  Console Config: ./$CONSOLE_HOST_CFG_RELPATH"
      log "  Console Data:   ./$CONSOLE_HOST_DATA_RELPATH"
      log "  Console Logs:   ./$CONSOLE_HOST_LOGS_RELPATH"
    ;;
  esac
  case " $SERVICES_TO_RUN " in
    *" easysearch "*)
      if [ "$EASYSEARCH_NODES" -eq 1 ]; then
          log "  Easysearch (1-node) Config: ./$EASYSEARCH_HOST_NODES_BASE_RELPATH/$EASYSEARCH_CFG_SUBPATH_IN_CONTAINER"
      else
          _i=0; _limit=$((EASYSEARCH_NODES-1))
          while [ "$_i" -le "$_limit" ]; do
              log "  Easysearch Node $_i Config: ./$EASYSEARCH_HOST_NODES_BASE_RELPATH/node-${_i}/$EASYSEARCH_CFG_SUBPATH_IN_CONTAINER"
              _i=$((_i + 1))
          done
      fi
    ;;
  esac

  log "Starting Docker Compose services from $(pwd) using: $DOCKER_COMPOSE_UP_CMD"
  # Execute DOCKER_COMPOSE_UP_CMD. It can be "docker-compose up ..." or "docker compose up ..."
  # eval is safer here to handle "docker compose" properly if DOCKER_COMPOSE_EXEC contains spaces
  if ! eval "$DOCKER_COMPOSE_UP_CMD"; then
    svcs_log_up_err_csv=""
    actual_svcs_up_err_str=""
    if [ -n "$SERVICES_TO_RUN" ]; then
        _old_ifs="$IFS"; IFS=' '
        set -- $SERVICES_TO_RUN
        IFS="$_old_ifs"
        for s_name_err_up in "$@"; do
            if [ "$s_name_err_up" = "easysearch" ]; then
                _i_err_up=0; _limit_err_up=$((EASYSEARCH_NODES-1))
                while [ "$_i_err_up" -le "$_limit_err_up" ]; do
                    actual_svcs_up_err_str="${actual_svcs_up_err_str} easysearch-${_i_err_up}"
                    _i_err_up=$((_i_err_up + 1))
                done
            elif [ "$s_name_err_up" = "console" ]; then
                actual_svcs_up_err_str="${actual_svcs_up_err_str} ${CONSOLE_CONTAINER_NAME_DEFAULT}"
            else
                actual_svcs_up_err_str="${actual_svcs_up_err_str} $s_name_err_up"
            fi
        done
        actual_svcs_up_err_str=$(echo "$actual_svcs_up_err_str" | sed 's/^ *//')
        svcs_log_up_err_csv=$(echo "$actual_svcs_up_err_str" | tr ' ' ',')
    else
        # Default if SERVICES_TO_RUN was empty (should not happen if 'up' defaults it)
        _default_nodes_limit=$((DEFAULT_EASYSEARCH_NODES-1))
        _default_ezs_nodes_str=""
        _j=0
        while [ "$_j" -le "$_default_nodes_limit" ]; do
            _item=$(printf "easysearch-%s" "$_j")
            if [ -z "$_default_ezs_nodes_str" ]; then _default_ezs_nodes_str="$_item"; else _default_ezs_nodes_str="${_default_ezs_nodes_str},$_item"; fi
            _j=$((_j+1))
        done
        svcs_log_up_err_csv="${CONSOLE_CONTAINER_NAME_DEFAULT},${_default_ezs_nodes_str}"
    fi
    error "'$DOCKER_COMPOSE_UP_CMD' failed! Services targeted: $svcs_log_up_err_csv"
  fi

  if ! cd "$original_pwd_up"; then warn "Could not cd back to '$original_pwd_up'"; fi
  log "Environment started successfully! 🎉"

  case " $SERVICES_TO_RUN " in *" console "*) log "INFINI Console: http://localhost:${CONSOLE_PORT_HOST_DEFAULT} 🖥️";; esac
  case " $SERVICES_TO_RUN " in *" easysearch "*) if [ "$EASYSEARCH_NODES" -gt 0 ]; then log "INFINI Easysearch (node 0): https://localhost:${EASYSEARCH_HTTP_PORT_HOST_DEFAULT} 🔍 (User: admin, Pass: ${INITIAL_ADMIN_PASSWORD})"; fi;; esac

  _no_wait="true"
  case "$DOCKER_COMPOSE_UP_CMD" in *"--wait"*) _no_wait="false";; esac
  if [ "$_no_wait" = "true" ]; then log "Services started. May take moments for full availability. Use '${SCRIPT_INVOCATION_CMD} logs'.";
  else log "Services should be healthy (due to --wait & healthchecks)."; fi
  log "To stop services & remove data volumes: ${SCRIPT_INVOCATION_CMD} down"
  log "For full cleanup (includes work dir): ${SCRIPT_INVOCATION_CMD} clean"
}

cmd_down() {
  log "Stopping services, removing containers, networks, and volumes from $ABS_WORK_DIR... 🛑"
  if [ ! -f "${ABS_WORK_DIR}/docker-compose.yml" ]; then
    warn "No docker-compose.yml in ${ABS_WORK_DIR}. Nothing to stop/remove."; return; fi
  original_pwd_down=$(pwd)
  if ! cd "$ABS_WORK_DIR"; then error "Failed to cd to $ABS_WORK_DIR for 'down'."; fi
  log "Executing: $DOCKER_COMPOSE_DOWN_VOLUMES from $(pwd)"
  if ! eval "$DOCKER_COMPOSE_DOWN_VOLUMES"; then error "'$DOCKER_COMPOSE_DOWN_VOLUMES' failed!"; fi
  if ! cd "$original_pwd_down"; then warn "Failed to cd back from $ABS_WORK_DIR after 'down'."; fi
  log "Environment fully stopped and Docker resources removed. 😴";
}

cmd_logs() {
  IS_LOGGING_ACTIVE="true"
  services_to_log_cmd_str="" # This will hold the service names for 'docker compose logs'
  specified_services_for_check="" # This will hold the meta-names like "console" or "easysearch" for `ps` check

  # Populate services_to_log_cmd_str (actual container/service names for docker-compose logs)
  # and specified_services_for_check (meta names like "console", "easysearch" or specific like "easysearch-0")
  if [ -n "$SERVICES_TO_RUN" ]; then # SERVICES_TO_RUN comes from parse_and_dispatch_command
      _old_ifs="$IFS"; IFS=' '
      set -- $SERVICES_TO_RUN
      IFS="$_old_ifs"
      for svc_input in "$@"; do
          if [ "$svc_input" = "easysearch" ]; then
              specified_services_for_check="${specified_services_for_check} easysearch" # For ps check later
              _nodes_for_logs=${EASYSEARCH_NODES:-$DEFAULT_EASYSEARCH_NODES} # Get current/default nodes
              _i=0; _limit=$((_nodes_for_logs-1))
              while [ "$_i" -le "$_limit" ]; do
                  services_to_log_cmd_str="${services_to_log_cmd_str} easysearch-${_i}"
                  _i=$((_i + 1))
              done
          elif [ "$svc_input" = "console" ]; then
              specified_services_for_check="${specified_services_for_check} console"
              services_to_log_cmd_str="${services_to_log_cmd_str} ${CONSOLE_CONTAINER_NAME_DEFAULT}"
          else # Specific service names like easysearch-0 or infini-console
              case "$svc_input" in
                  "$CONSOLE_CONTAINER_NAME_DEFAULT" | easysearch-[0-9]*)
                      specified_services_for_check="${specified_services_for_check} $svc_input"
                      services_to_log_cmd_str="${services_to_log_cmd_str} $svc_input" ;;
                  *) warn "Unrecognized service '$svc_input' for logs. Ignoring." ;;
              esac
          fi
      done
      services_to_log_cmd_str=$(echo "$services_to_log_cmd_str" | sed 's/^ *//;s/ *$//')
      specified_services_for_check=$(echo "$specified_services_for_check" | sed 's/^ *//;s/ *$//')
  fi

  display_services_for_logging="(all services)"
  if [ -n "$services_to_log_cmd_str" ]; then
    display_services_for_logging="$services_to_log_cmd_str"
  fi

  if [ ! -f "${ABS_WORK_DIR}/docker-compose.yml" ]; then
    IS_LOGGING_ACTIVE="false" # Reset before error
    error "No docker-compose.yml in ${ABS_WORK_DIR}.
    Run '${SCRIPT_INVOCATION_CMD} up' first."
  fi

  original_pwd_logs=$(pwd)
  if ! cd "$ABS_WORK_DIR"; then
    IS_LOGGING_ACTIVE="false" # Reset before error
    error "Failed to cd to $ABS_WORK_DIR for 'logs'."
  fi

  # Check if any services are running
  log "Checking status of services in ${ABS_WORK_DIR}..."
  running_services_output=""
  # Use eval for DOCKER_COMPOSE_EXEC which might be "docker compose"
  if ! running_services_output=$(eval "$DOCKER_COMPOSE_EXEC ps --services --filter status=running" 2>/dev/null) && \
     ! running_services_output=$(eval "$DOCKER_COMPOSE_EXEC ps --services --filter status=restarting" 2>/dev/null); then # Also check restarting
      # If ps command itself fails, it's an issue
      warn "Could not query running services using 'docker compose ps'. Proceeding to view logs anyway."
  fi

  if [ -z "$running_services_output" ]; then
    IS_LOGGING_ACTIVE="false" # Reset before message
    log "No services appear to be running in ${ABS_WORK_DIR}."
    log "You can try starting them with: ${SCRIPT_INVOCATION_CMD} up"
    # Script will then exit via the EXIT trap with success (as no error occurred here)
    # If you want this to be an error, then call:
    # error "No services appear to be running. Run '${SCRIPT_INVOCATION_CMD} up' first."
    cd "$original_pwd_logs" || warn "Could not cd back from $ABS_WORK_DIR after 'logs' (no services running)."
    return 0 # Or return 1 if you use error above
  fi

  # If specific services were requested for logs, check if *those* are running
  all_requested_are_running="true"
  if [ -n "$specified_services_for_check" ]; then
      _old_ifs="$IFS"; IFS=' '
      set -- $specified_services_for_check # Check meta names like "console", "easysearch" or specific "easysearch-0"
      IFS="$_old_ifs"

      actual_running_service_names=$(echo "$running_services_output" | awk '{print $1}')

      for requested_meta_svc in "$@"; do
          found_match_for_meta="false"
          if [ "$requested_meta_svc" = "console" ]; then
              if echo "$actual_running_service_names" | grep -qxF "$CONSOLE_CONTAINER_NAME_DEFAULT"; then
                  found_match_for_meta="true"
              fi
          elif [ "$requested_meta_svc" = "easysearch" ]; then
              # Check if *any* easysearch-N node is running
              if echo "$actual_running_service_names" | grep -qE "^easysearch-[0-9]+$"; then
                  found_match_for_meta="true"
              fi
          elif echo "$actual_running_service_names" | grep -qxF "$requested_meta_svc"; then # Specific service name check
              found_match_for_meta="true"
          fi

          if [ "$found_match_for_meta" = "false" ]; then
              all_requested_are_running="false"
              warn "Requested service '$requested_meta_svc' (or its components) does not appear to be running."
          fi
      done
      set -- # Clear positional params

      if [ "$all_requested_are_running" = "false" ]; then
          IS_LOGGING_ACTIVE="false"
          log "Not all requested services are running. Current running services from 'docker compose ps':"
          eval "$DOCKER_COMPOSE_EXEC ps" # Show full ps output
          log "You can try starting them with: ${SCRIPT_INVOCATION_CMD} up"
          cd "$original_pwd_logs" || warn "Could not cd back from $ABS_WORK_DIR after 'logs' (some services not running)."
          return 0 # Or 1 if considered an error
      fi
  fi

  log "Following logs for: ${display_services_for_logging} from ${ABS_WORK_DIR}... (Press Ctrl+C to stop)"
  _full_cmd_to_execute="$DOCKER_COMPOSE_LOGS_CMD"
  if [ -n "$services_to_log_cmd_str" ]; then # services_to_log_cmd_str contains actual service names for compose
    _full_cmd_to_execute="$_full_cmd_to_execute $services_to_log_cmd_str"
  fi

  log "Executing from $(pwd): $_full_cmd_to_execute"
  # The INT trap will handle Ctrl+C. If logs command finishes naturally (e.g. services stop), it continues.
  eval "$_full_cmd_to_execute"
  _log_cmd_status=$? # Capture exit status of logs command

  # This part is reached if logs are not followed (-f was not part of DOCKER_COMPOSE_LOGS_CMD),
  # or if the services stop, or if 'docker compose logs' itself fails for some reason other than Ctrl+C.
  # If Ctrl+C is pressed, the INT trap's 'exit' command will terminate the script before this line,
  # unless the trap logic changes.
  # However, with `sh`, the trap might allow the script to continue here after the signal is handled.

  # If logs exited due to Ctrl+C (SIGINT, status 130), IS_LOGGING_ACTIVE might still be true
  # but the handle_signal would have printed "Exiting log view only."
  # If handle_signal calls `exit`, then this part isn't reached.
  # If handle_signal does *not* call `exit` for logs interruption, then this code runs.

  if [ "$IS_LOGGING_ACTIVE" = "true" ]; then # Check if still in "logging mode" (i.e., not exited by trap)
      if [ $_log_cmd_status -eq 130 ]; then # 130 is often from SIGINT
          log "Log viewing interrupted by user (Ctrl+C)."
      elif [ $_log_cmd_status -ne 0 ]; then
          warn "Log command finished with status $_log_cmd_status. Services might have stopped or an error occurred."
      else
          log "Finished viewing logs. Services might have stopped."
      fi
  fi
  # IS_LOGGING_ACTIVE is reset in the EXIT trap or if handle_signal calls exit.
  # For robustness, reset it here too if the log command finished without script exit.
  IS_LOGGING_ACTIVE="false"

  if ! cd "$original_pwd_logs"; then warn "Failed to cd back from $ABS_WORK_DIR after 'logs'."; fi
}

cmd_clean() {
  log "Initiating FULL cleanup: services, volumes, and WORK_DIR ('$ABS_WORK_DIR')... 🧹"
  cmd_down

  if [ -d "$ABS_WORK_DIR" ]; then
    log "Attempting to remove directory: $ABS_WORK_DIR 🗑️"
    if rm -rf "$ABS_WORK_DIR" 2>/dev/null; then log "Removed $ABS_WORK_DIR without sudo. 💯";
    else
      log "Failed rm $ABS_WORK_DIR without sudo. Retrying with sudo..."
      if sudo rm -rf "$ABS_WORK_DIR"; then log "Removed $ABS_WORK_DIR with sudo. 💯";
      else error "Failed to remove $ABS_WORK_DIR even with sudo."; fi
    fi
  else log "Directory '$ABS_WORK_DIR' not found. Skipping filesystem removal."; fi
  log "Full cleanup complete! ✨"
}

_get_current_shell_name() {
    # Try with $0 first
    _shell_path_basename=$(basename "$0")
    case "$_shell_path_basename" in
        bash|-bash|sh|-sh) echo "$_shell_path_basename" ; return ;;
    esac
    # Fallback to ps if available, this is less portable
    if command -v ps >/dev/null 2>&1; then
        ps -p $$ -o comm= 2>/dev/null || ps -p $$ -o command= 2>/dev/null | awk '{print $1}' | sed 's#.*/##' || echo "unknown"
    else
        echo "unknown"
    fi
}

print_usage() {
  local invocation_cmd_for_help
  invocation_cmd_for_help=""
  if [ -n "$SCRIPT_INVOCATION_CMD" ]; then invocation_cmd_for_help="$SCRIPT_INVOCATION_CMD";
  else
    _current_shell=$(_get_current_shell_name)
    case "$0" in # $0 can be complex when sourced or piped
        bash|sh|*/bash|*/sh) # Being executed as "bash script_content" or "sh script_content" or piped
            _shell_for_pipe="sh" # Default to sh for pipe
            if [ "$_current_shell" = "bash" ] || [ "$_current_shell" = "-bash" ]; then
                _shell_for_pipe="bash"
            fi
            invocation_cmd_for_help="curl -fsSL ${SCRIPT_DOWNLOAD_URL} | $_shell_for_pipe -s --";
        ;;
        *) # Executed as a file
            if [ -f "$0" ] && case "$0" in */*) true;; *) false;; esac; then invocation_cmd_for_help="$0";
            elif [ -f "$0" ]; then invocation_cmd_for_help="./$0";
            elif available "$SCRIPT_BASENAME_ACTUAL"; then invocation_cmd_for_help="$SCRIPT_BASENAME_ACTUAL";
            else invocation_cmd_for_help="./${RECOMMENDED_SCRIPT_FILENAME}"; fi
        ;;
    esac
  fi

  if [ -z "${CONSOLE_VERSION_TAG:-}" ] || [ -z "${EASYSEARCH_VERSION_TAG:-}" ] ; then
      ensure_product_versions
  fi

  cat <<EOF
    __ _  __ ____ __ _  __ __
   / // |/ // __// // |/ // /
  / // || // _/ / // || // /
 /_//_/|_//_/  /_//_/|_//_/

©INFINI.LTD, All Rights Reserved.

🚀 Usage: ${invocation_cmd_for_help} [COMMAND] [OPTIONS] [SERVICE_NAMES...]
   Version: $SCRIPT_VERSION

   Manages local dev environment for INFINI Console & Easysearch using Docker.
   Operational files & data stored in: '${USER_SPECIFIED_WORK_DIR}' (default: '${DEFAULT_WORK_DIR}', customizable with -wd).

Commands:
  up                🏗️  Create/start services (default: $DEFAULT_SERVICES_TO_START_STR).
  down              🛑  Stop services, remove containers, networks, and associated data volumes.
  logs              📜  Follow service logs. Ctrl+C to stop viewing (services keep running).
  clean             🧹  Full cleanup: performs 'down' and then removes the working directory.
  help              ❓  Show this help message.

Options (primarily for the 'up' command):
  -cv, --console-version TAG  INFINI Console image tag (default: ${CONSOLE_VERSION_TAG:-fetching...}).
  -ev, --easysearch-version TAG INFINI Easysearch image tag (default: ${EASYSEARCH_VERSION_TAG:-fetching...}).
  -n, --nodes N               Number of Easysearch nodes (default: $DEFAULT_EASYSEARCH_NODES).
  -p, --password P            Initial admin password for Easysearch (default: "$DEFAULT_ADMIN_PASSWORD").
  --services s1[,s2..]      Comma-separated services for 'up' (console,easysearch).
  --metrics-agent             Enable Easysearch metrics collection via agent.
  -wd, --work-dir PATH        Custom working directory (default: ${DEFAULT_WORK_DIR}).
  -h, --help                  Show this help message.

Examples:
  ${invocation_cmd_for_help} up
  ${invocation_cmd_for_help} up --nodes 3 --password 'MyPass!123'
  ${invocation_cmd_for_help} logs console easysearch-0
  ${invocation_cmd_for_help} clean

Direct web execution:
  curl -fsSL ${SCRIPT_DOWNLOAD_URL} | sh -s -- up  # (or bash -s --)

Local execution:
  curl -fsSL ${SCRIPT_DOWNLOAD_URL} -o ${RECOMMENDED_SCRIPT_FILENAME} && chmod +x ${RECOMMENDED_SCRIPT_FILENAME}
  ./${RECOMMENDED_SCRIPT_FILENAME} up
EOF
  exit 0
}

# Helper for parse_and_dispatch_command
_add_to_services_to_run() {
    _service_val_trimmed=$(echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _cmd_context="$2" # "up" or "logs"

    _is_valid_service="false"
    if [ "$_service_val_trimmed" = "console" ] || [ "$_service_val_trimmed" = "easysearch" ]; then
        _is_valid_service="true"
    elif [ "$_cmd_context" = "logs" ]; then
        case "$_service_val_trimmed" in
            "$CONSOLE_CONTAINER_NAME_DEFAULT" | easysearch-[0-9]*) _is_valid_service="true" ;;
        esac
    fi

    if [ "$_is_valid_service" = "true" ]; then
        case " $SERVICES_TO_RUN " in
            *" $_service_val_trimmed "*) ;; # already there
            *) SERVICES_TO_RUN="$SERVICES_TO_RUN $_service_val_trimmed" ;;
        esac
    elif [ -n "$_service_val_trimmed" ]; then
         warn "Unknown service '$_service_val_trimmed' in --services or positional arg. Ignored for '$_cmd_context'."
    fi
}


# --- Main Argument Parsing and Command Dispatch ---
parse_and_dispatch_command() {
  CONSOLE_IMAGE="${DEFAULT_CONSOLE_IMAGE}"; EASYSEARCH_IMAGE="${DEFAULT_EASYSEARCH_IMAGE}"
  EASYSEARCH_NODES=$DEFAULT_EASYSEARCH_NODES; EASYSEARCH_CLUSTER_NAME="$DEFAULT_CLUSTER_NAME"
  CONSOLE_VERSION_TAG=""; EASYSEARCH_VERSION_TAG=""
  INITIAL_ADMIN_PASSWORD="$DEFAULT_ADMIN_PASSWORD"; ENABLE_METRICS_AGENT="false"
  USER_SPECIFIED_WORK_DIR="$DEFAULT_WORK_DIR"; SERVICES_TO_RUN=""

  _current_shell_name=$(_get_current_shell_name)
  _shell_for_pipe_cmd="sh" # Default
  if [ "$_current_shell_name" = "bash" ] || [ "$_current_shell_name" = "-bash" ]; then
    _shell_for_pipe_cmd="bash"
  fi

  case "$0" in
      bash|sh|*/bash|*/sh) SCRIPT_INVOCATION_CMD="curl -fsSL ${SCRIPT_DOWNLOAD_URL} | ${_shell_for_pipe_cmd} -s --";;
      *) # Executed as a file
        if [ -f "$0" ] && case "$0" in */*) true;; *) false;; esac; then SCRIPT_INVOCATION_CMD="$0";
        elif [ -f "$0" ]; then SCRIPT_INVOCATION_CMD="./$0";
        elif available "$SCRIPT_BASENAME_ACTUAL"; then SCRIPT_INVOCATION_CMD="$SCRIPT_BASENAME_ACTUAL";
        else SCRIPT_INVOCATION_CMD="./${SCRIPT_BASENAME_ACTUAL}"; fi
      ;;
  esac

  main_cmd_to_run="help"
  if [ $# -eq 0 ]; then main_cmd_to_run="up"; else
    case "$1" in
      up|down|logs|clean|help) main_cmd_to_run="$1"; shift ;;
      -*) main_cmd_to_run="up" ;; # Assume options imply 'up' if no command
      *) main_cmd_to_run="up" ;; # Assume first non-option is a service for 'up' or just default to 'up'
                                 # This will be refined; if it's 'console' or 'easysearch', it's a service for 'up'.
                                 # If it's not a known command or service, it might be an error or imply 'up'.
                                 # For now, this simple logic matches original closer.
    esac
  fi

  log "Preliminary main command: ${main_cmd_to_run}"


  _positional_args_for_services="" # Temporary store for positional args that might be services

  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--nodes) if [ -z "${2:-}" ]; then error "Option '$1' needs a value."; fi; EASYSEARCH_NODES="$2"; shift 2;;
      -p|--password) if [ -z "${2:-}" ]; then error "Option '$1' needs a value."; fi; INITIAL_ADMIN_PASSWORD="$2"; shift 2;;
      -cv|--console-version) if [ -z "${2:-}" ]; then error "Option '$1' needs a value."; fi; CONSOLE_VERSION_TAG="$2"; shift 2;;
      -ev|--easysearch-version) if [ -z "${2:-}" ]; then error "Option '$1' needs a value."; fi; EASYSEARCH_VERSION_TAG="$2"; shift 2;;
      --services)
        if [ -z "${2:-}" ]; then error "Option '$1' needs a value."; fi
        _services_input="$2"
        _old_ifs="$IFS"; IFS=','
        set -- $_services_input
        IFS="$_old_ifs"
        for s_o; do # Iterate over new positional parameters from set --
            _add_to_services_to_run "$s_o" "$main_cmd_to_run" # Assuming 'up' or 'logs' context from main_cmd_to_run
        done
        shift 2 # Shift original arguments
        ;;
      --metrics-agent) ENABLE_METRICS_AGENT="true"; shift;;
      -wd|--work-dir) if [ -z "${2:-}" ]; then error "Option '$1' needs a value."; fi; USER_SPECIFIED_WORK_DIR="$2"; shift 2;;
      -h|--help) main_cmd_to_run="help"; break;;
      --) shift; _positional_args_for_services="$_positional_args_for_services $@"; break;; # Collect all remaining
      -*) error "Unknown option: $1. Use '${SCRIPT_INVOCATION_CMD} help'";;
      *) # Positional arguments
         _is_known_cmd_at_pos="false"
         for cmd_c_p in up down logs clean help; do if [ "$1" = "$cmd_c_p" ]; then _is_known_cmd_at_pos="true"; break; fi; done

         if [ "$_is_known_cmd_at_pos" = "true" ]; then
            # This logic was complex and potentially problematic. If a command is found, it should have been $1 earlier.
            # If main_cmd_to_run is 'help' and $1 is a command, main_cmd_to_run becomes $1.
            # If main_cmd_to_run is already set (e.g. 'up') and $1 is another command (e.g. 'logs'), it's an error.
            if [ "$main_cmd_to_run" = "help" ]; then
                main_cmd_to_run="$1"
            elif [ "$main_cmd_to_run" != "$1" ]; then
                 # Allow 'up console' or 'up easysearch'
                 if ! ( [ "$main_cmd_to_run" = "up" ] && ( [ "$1" = "console" ] || [ "$1" = "easysearch" ] ) ); then
                    error "Multiple commands ('$main_cmd_to_run' and '$1') specified. Only one command is allowed."
                 fi
                 # If it was 'up console', 'console' is a service, not a new command
                 _positional_args_for_services="$_positional_args_for_services $1"
            fi
         else # Not a known command, so treat as a potential service name
            _positional_args_for_services="$_positional_args_for_services $1"
         fi
         shift;;
    esac
  done

  # Process collected positional arguments for services
  if [ -n "$_positional_args_for_services" ]; then
      if [ "$main_cmd_to_run" = "up" ] || [ "$main_cmd_to_run" = "logs" ]; then
          _old_ifs="$IFS"; IFS=' '
          set -- $_positional_args_for_services
          IFS="$_old_ifs"
          for _s_p_val; do
              _add_to_services_to_run "$_s_p_val" "$main_cmd_to_run"
          done
      elif [ "$main_cmd_to_run" != "help" ]; then # Don't warn for help command
          warn "Ignoring positional arguments for '$main_cmd_to_run': $_positional_args_for_services"
      fi
  fi

  SERVICES_TO_RUN=$(echo "$SERVICES_TO_RUN" | sed 's/^ *//;s/ *$//') # Trim spaces

  if [ "$main_cmd_to_run" = "up" ] && [ -z "$SERVICES_TO_RUN" ]; then
    SERVICES_TO_RUN="$DEFAULT_SERVICES_TO_START_STR"
    log "No services specified for 'up', using defaults: $SERVICES_TO_RUN";
  fi

  log "Raw USER_SPECIFIED_WORK_DIR from -wd or default: '$USER_SPECIFIED_WORK_DIR'"
  initial_pwd_for_abs="$PWD"
  case "$USER_SPECIFIED_WORK_DIR" in
      /* | [A-Za-z]:*) ABS_WORK_DIR="$USER_SPECIFIED_WORK_DIR" ;;
      *) norm_wd_abs=$(echo "$USER_SPECIFIED_WORK_DIR" | sed 's#^\./##') ; ABS_WORK_DIR="${initial_pwd_for_abs%/}/${norm_wd_abs}" ;;
  esac
  ABS_WORK_DIR=$(echo "$ABS_WORK_DIR" | sed 's#//#/#g')

  if ! mkdir -p "$ABS_WORK_DIR"; then error "Failed to create working directory: '$ABS_WORK_DIR'. Check permissions."; fi

  _temp_abs_dir_val=""
  if command -v realpath >/dev/null 2>&1 && realpath --version 2>/dev/null | grep -q GNU; then
      _temp_abs_dir_val=$(realpath -m "$ABS_WORK_DIR")
  elif command -v grealpath >/dev/null 2>&1; then
      _temp_abs_dir_val=$(grealpath -m "$ABS_WORK_DIR")
  elif command -v readlink >/dev/null 2>&1 && readlink --version 2>/dev/null | grep -q GNU; then
      _temp_abs_dir_val=$(readlink -f "$ABS_WORK_DIR")
  fi
  if [ -n "$_temp_abs_dir_val" ]; then
      ABS_WORK_DIR="$_temp_abs_dir_val"
  else
      log "Using 'cd && pwd' for path canonicalization of ABS_WORK_DIR."
      if _temp_abs_dir_val=$(cd "$ABS_WORK_DIR" && pwd); then ABS_WORK_DIR="$_temp_abs_dir_val";
      else warn "Could not 'cd' into '$ABS_WORK_DIR' to normalize. Using potentially unnormalized path."; fi
  fi
  log "Absolute working directory (ABS_WORK_DIR) set to: '$ABS_WORK_DIR'"

  if [ "$main_cmd_to_run" = "logs" ]; then IS_LOGGING_ACTIVE="true"; else IS_LOGGING_ACTIVE="false"; fi

  case "$main_cmd_to_run" in
      up|down|logs|clean) check_system_requirements "$ABS_WORK_DIR" ;;
  esac
  if [ "$main_cmd_to_run" = "up" ] || [ "$main_cmd_to_run" = "help" ]; then ensure_product_versions; fi

  case "$main_cmd_to_run" in
    up) cmd_up ;;
    down) cmd_down ;;
    logs) cmd_logs ;;
    clean) cmd_clean ;;
    help|*) print_usage ;;
  esac
}

# --- Script Entry Point ---
detect_os_arch
parse_and_dispatch_command "$@"
