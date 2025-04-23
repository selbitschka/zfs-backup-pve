#!/bin/bash
# shellcheck disable=SC2091
# shellcheck disable=SC2086

# Release Notes
# 1.5.0
# - Skip snapshot creation by using SNAPSHOT_CREATE=false
# - Create snapshot with external tool by using SNAPSHOT_EXTERNAL_COMMAND=%COMMAND%
# - None ZFS disks will be ignored
# 1.4.0
# - Keep last backup snapshot before custom snapshots on src and destination
# 1.3.1
# - Honor VM_SNAP_DESC in snapshot description.
# - Cleanup unused functions.
# 1.3.0
# - Allow limit bandwidth by piping through cstream.
# 1.2.0
# - Add email notification support.
# - Create new logfile for each run and delete old ones.
# 1.1.0
# - Use qm for visible snapshots.
# - Create all snapshots for all datasets during one freeze.

readonly VERSION='1.5.0'

# return codes
readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_MISSING_PARAM=2
readonly EXIT_INVALID_PARAM=3
# readonly parameter
readonly ID_LENGTH=10
readonly TYPE_LOCAL=local
readonly TYPE_SSH=ssh

# ZFS commands
# we try to autodetect but in case these variables can be set
ZFS_CMD=
ZPOOL_CMD=
SSH_CMD=
MD5SUM_CMD=
ZFS_CMD_REMOTE=
ZPOOL_CMD_REMOTE=
QM_CMD=
CSTREAM_CMD=

# defaults
CONFIG_FILE=
LOG_FILE=
LOG_FILE_SEARCH=
LOG_FILE_DATE_PATTERN="%Y%m%d_%H%M%S"
LOG_FILE_KEEP=5
LOG_DATE_PATTERN="%Y-%m-%d - %H:%M:%S"
LOG_DEBUG="[DEBUG]"
LOG_INFO="[INFO]"
LOG_WARN="[WARN]"
LOG_ERROR="[ERROR]"
LOG_CMD="[COMMAND]"

SNAPSHOT_PREFIX="bkp"
SNAPSHOT_HOLD_TAG="zfsbackup"
SNAPSHOT_USE_QM="false"
SNAPSHOT_CREATE=true
SNAPSHOT_EXTERNAL_COMMAND=

ALLOW_NONE_ZFS=false

# pve
readonly PVE_NODE_NAME="$(hostname)"
readonly PVE_QEMU_DIR="qemu-server"
readonly PVE_NODES_DIR="/etc/pve/nodes"
readonly PVE_CONF_DIR="$PVE_NODES_DIR/$PVE_NODE_NAME/$PVE_QEMU_DIR"

# vm
VM_ID=
VM_DISK_PATTERN="vm-%VM_ID%-disk-"
VM_STATE=false
VM_SNAP_DESC=zfsbackup
VM_CONF_SRC=
VM_CONF_DEST=
VM_NO_FREEZE=false

# datasets
ID=
SRC_DATASETS=()
SRC_TYPE=$TYPE_LOCAL
SRC_ENCRYPTED=false
SRC_DECRYPT=false
SRC_COUNT=1
SRC_SNAPSHOTS=()
SRC_SNAPSHOT_LAST=
SRC_SNAPSHOT_LAST_SYNCED=

DST_DATASET=
DST_DATASET_CURRENT=
DST_TYPE=$TYPE_LOCAL
DST_COUNT=1
DST_SNAPSHOTS=()
DST_SNAPSHOT_LAST=
DST_PROP="readonly=on"
DST_PROP_ARRAY=()

# boolean options
RESUME=false
INTERMEDIATE=false
MOUNT=false
BOOKMARK=false
NO_OVERRIDE=false
NO_HOLD=false
NO_HOLD_DEST=false
MAKE_CONFIG=false
DEBUG=false
DRYRUN=false

# parameter
DEFAULT_SEND_PARAMETER="-Lec"
SEND_PARAMETER=
RECEIVE_PARAMETER=

# pre post scripts
ONLY_IF=
PRE_SNAPSHOT=
POST_SNAPSHOT=
PRE_RUN=
POST_RUN=

# ssh parameter
SSH_HOST=
SSH_PORT=22
SSH_USER=
SSH_KEY=
SSH_OPT="-o ConnectTimeout=10"
#SSH_OPT="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

MAIL_FROM="zfs-pve-backup@$(hostname -f)"
MAIL_TO=
MAIL_SUBJECT="[ZFS-PVE-BACKUP] - %RESULT% - %VMID% - %ID% - %DATE%"
MAIL_ON_SUCCESS=false

FIRST_RUN=false
EXECUTION_ERROR=false
LIMIT_BANDWIDTH=

# help text
readonly VM_ID_HELP="VM ID of virtual machine to backup."
readonly VM_STATE_HELP="Save VM state (RAM) during snapshot. If not present state is not saved."
readonly VM_SNAP_DESC_HELP="Description of snapshot ' ($ID)' will be appended (default: '$VM_SNAP_DESC')."
readonly VM_CONF_DEST_HELP="Destination to copy VM config to. If not set VM config is not backed up."
readonly VM_NO_FREEZE_HELP="Do not freeze VM file system before creating a snapshot. By default a fsfreeze is executed and script exits if this fails, i.e if no qemu agent is installed."

readonly SNAPSHOT_USE_QM_HELP="Use 'qm' command to create and delete snapshots instead of zfs directly. This makes snapshots visible in GUI but may interfere with replication."

readonly SRC_TYPE_HELP="Type of source dataset: '$TYPE_LOCAL' or '$TYPE_LOCAL' (default: local)."
readonly SRC_COUNT_HELP="Number (greater 0) of successful sent snapshots to keep on source side (default: 1)."
readonly DST_DATASET_HELP="Name of the receiving dataset (destination)."
readonly DST_TYPE_HELP="Type of destination dataset (default: 'local')."
readonly DST_COUNT_HELP="Number (greater 0) of successful received snapshots to keep on destination side (default: 1)."
readonly DST_PROP_HELP=("Properties to set on destination after first sync. User ',' separated list of 'property=value'" "If 'inherit' is used as value 'zfs inherit' is executed otherwise 'zfs set'." "Default: '$DST_PROP'")

readonly SSH_HOST_HELP="Host to connect to."
readonly SSH_PORT_HELP="Port to use (default: 22)."
readonly SSH_USER_HELP="User used for connection. If not set current user is used."
readonly SSH_KEY_HELP="Key to use for connection. If not set default key is used."
readonly SSH_OPT_HELP="Options used for connection (i.e: '-oStrictHostKeyChecking=accept-new')."

readonly ID_HELP=("Unique ID of backup destination (default: md5sum of destination dataset and ssh host, if present)." "Required if you use multiple destinations to identify snapshots. Maximum of $ID_LENGTH characters or numbers.")
readonly SEND_PARAMETER_HELP="Parameters used for 'zfs send' command. If set these parameters are use and all other settings (see below) are ignored."
readonly RECEIVE_PARAMETER_HELP="Parameters used for 'zfs receive' command. If set these parameters are use and all other settings (see below) are ignored."
readonly LIMIT_BANDWIDTH_HELP="Limit used bandwidth to given value in KB using cstream."

readonly BOOKMARK_HELP="Use bookmark (if supported) instead of snapshot on source dataset. Ignored if '-ss, --src-count' is greater 1. Do not use if you use PVE replication, since bookmarks are not replicated."
readonly RESUME_HELP="Make sync resume able and resume interrupted streams. User '-s' option during receive."
readonly INTERMEDIATE_HElP=("Use '-I' instead of '-i' while sending to keep intermediary snapshots." "If set, created but not send snapshots are kept, otherwise they are deleted.")
readonly NO_OVERRIDE_HElP=("By default option '-F' is used during receive to discard changes made in destination dataset." "If you use this option receive will fail if destination was changed.")
readonly DECRYPT_HElP=("By default encrypted source datasets are send in raw format using send option '-w'." "This options disables that and sends encrypted (mounted) datasets in plain.")
readonly NO_HOLD_HELP="Do not put hold tag on snapshots created by this tool."
readonly NO_HOLD_NOTE="NOTE: If you do not use bookmarks and use replication on you pve hosts disable holds on your snapshot because migrations will fail since old snapshots could not be removed."
readonly NO_HOLD_DEST_HELP="Do not put hold tag on destination snapshots."
readonly LOG_FILE_HELP="Logfile to log to, date will be appended."
readonly LOG_FILE_KEEP_HELP="Number of logfiles to keep (default: $LOG_FILE_KEEP)."
readonly DEBUG_HELP="Print executed commands and other debugging information."

readonly ONLY_IF_HELP=("Command or script to check preconditions, if command fails backup is not started." "Examples:" "check IP: [[ \\\"\\\$(ip -4 addr show wlp5s0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')\\\" =~ 192\\.168\\.2.* ]]" "check wifi: [[ \\\"\\\$(iwgetid -r)\\\" == \\\"ssidname\\\" ]]")
readonly PRE_RUN_HELP="Command or script to be executed before anything else is done (i.e. init a wireguard tunnel)."
readonly POST_RUN_HELP="Command or script to be executed after the this script is finished."
readonly PRE_SNAPSHOT_HELP="Command or script to be executed before snapshot is made (i.e. to lock databases)."
readonly POST_SNAPSHOT_HELP="Command or script to be executed after snapshot is made."

readonly MAIL_FROM_HELP="E-Mail address used in from header (default: $MAIL_FROM)."
readonly MAIL_TO_HELP="E-Mail address where notification is sent to. If not set email notifications are disabled."
readonly MAIL_SUBJECT_HELP="Subject of email (default: '$MAIL_SUBJECT'). Placeholders: %RESULT%, %VMID%, %ID% and %DATE%."
readonly MAIL_ON_SUCCESS_HELP="By default emails are only send on error, if you use --mail-on-success emails are sent on every result."

readonly NO_SNAPSHOT_HELP="Skip snapshot generation and use snapshots generated by other tools."
readonly SNAPSHOT_CMD_HELP="Create snapshot by external tool or script. The datasets to create snapshots from are used as arguments: i.e. snap.sh storage/vmdisks/vm-1201-disk-0 storage/vmdisks/vm-1201-disk-1"

readonly ALLOW_NONE_ZFS_HELP="Allow and ignore none zfs disks. In case a other disk (qcow2, raw, vmkd, ...) is found it will be ignored. If not set backup fails in this case."

usage() {
  local usage
  usage="zfs-backup-pve Version $VERSION
Usage:
------
zfs-backup-pve -vm vmid -d pool/backup -dt ssh --ssh_host 192.168.1.1 --ssh_user backup ... [--help]
zfs-backup-pve -c configFile ... [--help]
Help:
-----
zfs-backup-pve --help"
  echo "$usage"
}

help() {
  local help
  help="
Help:
=====
Parameters
----------
  -c,  --config    [file]        Config file to load parameter from.
  --create-config                Create a config file base on given commandline parameters.
                                 If a config file ('-c') is use the output is written to that file.

  -qm                            $SNAPSHOT_USE_QM_HELP

  -vm, --vmid      [id]          $VM_ID_HELP
  --vm-state                     $VM_STATE_HELP
  --vm-snap-desc   [desc]        $VM_SNAP_DESC_HELP
  --vm-conf-dest   [destination] $VM_CONF_DEST_HELP
  --vm-no-freeze                 $VM_NO_FREEZE_HELP

  -st, --src-type  [ssh|local]   $SRC_TYPE_HELP
  -ss, --src-snaps [count]       $SRC_COUNT_HELP

  -d,  --dst       [name]        $DST_DATASET_HELP
  -dt, --dst-type  [ssh|local]   $DST_TYPE_HELP
  -ds, --dst-snaps [count]       $DST_COUNT_HELP
  -dp, --dst-prop  [properties]  ${DST_PROP_HELP[0]}
                                 ${DST_PROP_HELP[1]}
                                 ${DST_PROP_HELP[2]}
  -i,  --id        [name]        ${ID_HELP[0]}
                                 ${ID_HELP[1]}
  --send-param     [parameters]  $SEND_PARAMETER_HELP
  --recv-param     [parameters]  $RECEIVE_PARAMETER_HELP
  --limit          [number]      $LIMIT_BANDWIDTH_HELP
  --bookmark                     $BOOKMARK_HELP
  --resume                       $RESUME_HELP
  --intermediary                 ${INTERMEDIATE_HElP[0]}
                                 ${INTERMEDIATE_HElP[1]}
  --no-override                  ${NO_OVERRIDE_HElP[0]}
                                 ${NO_OVERRIDE_HElP[1]}
  --decrypt                      ${DECRYPT_HElP[0]}
                                 ${DECRYPT_HElP[1]}
  --no-holds                     $NO_HOLD_HELP
  --no-holds-dest                $NO_HOLD_DEST_HELP
  --only-if        [command]     ${ONLY_IF_HELP[0]}
                                 ${ONLY_IF_HELP[1]}
                                 ${ONLY_IF_HELP[2]}
                                 ${ONLY_IF_HELP[3]}
  --pre-run        [command]     $PRE_RUN_HELP
  --post-run       [command]     $POST_RUN_HELP
  --pre-snapshot   [command]     $PRE_SNAPSHOT_HELP
  --post-snapshot  [command]     $POST_SNAPSHOT_HELP

  --no-snapshot                  $NO_SNAPSHOT_HELP
  --snapshot-cmd   [command]     $SNAPSHOT_CMD_HELP

  --allow-none-zfs               $ALLOW_NONE_ZFS_HELP

  --log-file       [file]        $LOG_FILE_HELP
  --log-file-keep  [number]      $LOG_FILE_KEEP_HELP

  -v,  --verbose                 $DEBUG_HELP
  --dryrun                       Do check inputs, dataset existence,... but do not create or destroy snapshot or transfer data.
  --version                      Print version.

Types:
------
  'local'                       Local dataset.
  'ssh'                         Traffic is streamed from/to ssh. Only source or destination can use ssh, other need to be local.

SSH Options
-----------
If you use type 'ssh' you need to specify Host, Port, etc.
 --ssh_host [hostname]          $SSH_HOST_HELP
 --ssh_port [port]              $SSH_PORT_HELP
 --ssh_user [username]          $SSH_USER_HELP
 --ssh_key  [keyfile]           $SSH_KEY_HELP
 --ssh_opt  [options]           $SSH_OPT_HELP


E-Mail Options
--------------
For email notification set following parameter
 --mail-to         [email]       $MAIL_TO_HELP
 --mail-from       [email]       $MAIL_FROM_HELP
 --mail-subject    [subject]     $MAIL_SUBJECT_HELP
 --mail-on-success               $MAIL_ON_SUCCESS_HELP

Help
----
  -h,  --help              Print this message."

  echo "$help"
}

function help_permissions_receive() {
  local current_user
  if [ "$DST_TYPE" = "$TYPE_SSH" ] && [ "$SSH_USER" != "" ]; then
    current_user=$SSH_USER
  else
    current_user=$(whoami)
  fi
  log_debug "Receiving user '$current_user' maybe has not enough rights."
  log_debug "To set right on sending side use:"
  log_debug "zfs allow -u $current_user compression,create,mount,receive $(dataset_parent $DST_DATASET)"
  log_debug "zfs allow -d -u $current_user canmount,destroy,hold,mountpoint,readonly,release $(dataset_parent $DST_DATASET)"
}

# read all parameters
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
  -c | --config)
    CONFIG_FILE="$2"
    shift
    shift
    ;;
  --create-config)
    MAKE_CONFIG=true
    shift
    ;;
  -qm)
    SNAPSHOT_USE_QM="true"
    shift
    ;;
  -vm | --vmid)
    VM_ID="$2"
    shift
    shift
    ;;
  --vm-state)
    VM_STATE=true
    shift
    ;;
  --vm-snap-desc)
    VM_SNAP_DESC="$2"
    shift
    shift
    ;;
  --vm-conf-dest)
    VM_CONF_DEST="$2"
    shift
    shift
    ;;
  --vm-no-freeze)
    VM_NO_FREEZE=true
    shift
    ;;
  -i | --id)
    ID="${2:0:$ID_LENGTH}"
    shift
    shift
    ;;
  -st | --src-type)
    SRC_TYPE="$2"
    shift
    shift
    ;;
  -ss | --src-snaps)
    SRC_COUNT="$2"
    shift
    shift
    ;;
  -d | --dst)
    DST_DATASET="$2"
    shift
    shift
    ;;
  -dt | --dst-type)
    DST_TYPE="$2"
    shift
    shift
    ;;
  -ds | --dst-snaps)
    DST_COUNT="$2"
    shift
    shift
    ;;
  -dp | --dst-prop)
    DST_PROP="$2"
    shift
    shift
    ;;
  --limit)
    LIMIT_BANDWIDTH="$2"
    shift
    shift
    ;;
  --send-param)
    if [ "${2:0:1}" = "-" ]; then
      SEND_PARAMETER="$2"
    else
      SEND_PARAMETER="-$2"
    fi
    shift
    ;;
  --recv-param)
    if [ "${2:0:1}" = "-" ]; then
      RECEIVE_PARAMETER="$2"
    else
      RECEIVE_PARAMETER="-$2"
    fi
    shift
    ;;
  --bookmark)
    BOOKMARK=true
    shift
    ;;
  --resume)
    RESUME=true
    shift
    ;;
  --intermediary)
    INTERMEDIATE=true
    shift
    ;;
  --no-override)
    NO_OVERRIDE=true
    shift
    ;;
  --decrypt)
    SRC_DECRYPT=true
    shift
    ;;
  --no-holds)
    NO_HOLD=true
    shift
    ;;
  --no-holds-desg)
    NO_HOLD_DEST=true
    shift
    ;;
  --only-if)
    ONLY_IF="$2"
    shift
    shift
    ;;
  --no-snapshot)
    SNAPSHOT_CREATE=false
    shift
    ;;
  --snapshot-cmd)
    SNAPSHOT_EXTERNAL_COMMAND="$2"
    shift
    shift
    ;;
  --pre-snapshot)
    PRE_SNAPSHOT="$2"
    shift
    shift
    ;;
  --post-snapshot)
    POST_SNAPSHOT="$2"
    shift
    shift
    ;;
  --pre-run)
    PRE_RUN="$2"
    shift
    shift
    ;;
  --post-run)
    POST_RUN="$2"
    shift
    shift
    ;;
  --allow-none-zfs)
    ALLOW_NONE_ZFS=true
    shift
    ;;
  --ssh_host)
    SSH_HOST="$2"
    shift
    shift
    ;;
  --ssh_port)
    SSH_PORT="$2"
    shift
    shift
    ;;
  --ssh_user)
    SSH_USER="$2"
    shift
    shift
    ;;
  --ssh_key)
    SSH_KEY="$2"
    shift
    shift
    ;;
  --ssh_opt)
    SSH_OPT="$2"
    shift
    shift
    ;;
  --mail-to)
    MAIL_TO="$2"
    shift
    shift
    ;;
  --mail-from)
    MAIL_FROM="$2"
    shift
    shift
    ;;
  --mail-subject)
    MAIL_SUBJECT="$2"
    shift
    shift
    ;;
  --mail-on-success)
    MAIL_ON_SUCCESS=true
    shift
    ;;
   --log-file)
    LOG_FILE="$2"
    shift
    shift
    ;;
   --log-file-keep)
    LOG_FILE_KEEP="$2"
    shift
    shift
    ;;
  -v | --verbose)
    DEBUG=true
    shift
    ;;
  --dryrun)
    DRYRUN=true
    shift
    ;;
  --version)
    echo "zfs-backup-pve $VERSION"
    exit $EXIT_OK
    ;;
  -h | --help)
    usage
    help
    exit $EXIT_OK
    ;;
  *) # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift              # past argument
    ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# print log output
# $1 log message, $2 severity pattern
function log() {
  if [ -n "$1" ]; then
    if [ -z "$LOG_FILE" ]; then
      case "$2" in
      "$LOG_INFO" | "$LOG_DEBUG")
        echo "$1"
        ;;
      "$LOG_WARN" | "$LOG_ERROR" | "$LOG_CMD")
        # log commands to stderr to do not interfere with echo results
        echo "$1" >&2
        ;;
      *)
        echo "$1"
        ;;
      esac
    else
      if [ -n "$2" ]; then
        echo "$(date +"$LOG_DATE_PATTERN") - $1" >>"$LOG_FILE"
      else
        echo "$(date +"$LOG_DATE_PATTERN") - $2 - $1" >>"$LOG_FILE"
      fi
    fi
  fi
}

function log_debug() {
  if [ "$DEBUG" = "true" ]; then
    log "$1" "$LOG_DEBUG"
  fi
}

function log_info() {
  log "$1" "$LOG_INFO"
}

function log_warn() {
  log "$1" "$LOG_WARN"
}

function log_error() {
  log "$1" "$LOG_ERROR"
}

function log_cmd() {
  if [ "$DEBUG" = "true" ]; then
    log "executing: '$1'" "$LOG_CMD"
  fi
}

# date utility functions
function date_text() {
  date +%Y%m%d_%H%M%S
}

function date_seconds() {
  date +%s
}

function date_compare() {
  local pattern="^[0-9]+$"
  if [[ "$1" != "" ]] && [[ $1 =~ $pattern ]] && [[ "$2" != "" ]] && [[ $2 =~ $pattern ]]; then
    [[ $1 > $2 ]]
  else
    false
  fi
}

function load_config() {
  if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  if [ -n "$LOG_FILE" ]; then
    LOG_FILE_SEARCH="$LOG_FILE.*"
    LOG_FILE="$LOG_FILE.$(date +"$LOG_FILE_DATE_PATTERN")"
  fi
}

# create ssh command
function ssh_cmd() {
  local cmd="$SSH_CMD"
  if [ -n "$SSH_PORT" ]; then
    cmd="$cmd -p $SSH_PORT"
  fi
  if [ -n "$SSH_KEY" ]; then
    cmd="$cmd -i $SSH_KEY"
  fi
  if [ -n "$SSH_USER" ]; then
    cmd="$cmd -l $SSH_USER"
  fi
  if [ -n "$SSH_OPT" ]; then
    cmd="$cmd $SSH_OPT"
  fi
  echo "$cmd $SSH_HOST "
}

# $1 type - 'local', 'ssh'
# $2 command to execute
function build_cmd() {
  case "$1" in
  "$TYPE_LOCAL")
    echo "$2"
    ;;
  "$TYPE_SSH")
    echo "$(ssh_cmd) $2"
    ;;
  *)
    log_error "Invalid type '$1'. Use '$TYPE_LOCAL' for local backup or '$TYPE_SSH' for remote server."
    stop $EXIT_ERROR
    ;;
  esac
}

# zpool from dataset
# $1 dataset
function zpool() {
  local split
  IFS='/' read -ra split <<<"$1"
  unset IFS
  echo "${split[0]}"
}

# command used to test if pool exists
# $1 zpool command
# $2 dataset name
function zpool_exists_cmd() {
  local pool
  pool="$(zpool "$2")"
  echo "$1 list $pool"
}

# command used to test if pool supports bookmarks
# $1 zpool command
# $2 dataset name
function zpool_bookmarks_cmd() {
  local pool
  pool="$(zpool "$2")"
  echo "$1 get -Hp -o value feature@bookmarks $pool"
}

# command used to test if pool supports encryption
# $1 zpool command
# $2 dataset name
function zpool_encryption_cmd() {
  local pool
  pool="$(zpool "$2")"
  echo "$1 get -Hp -o value feature@encryption $pool"
}

# test if pool exists
# $1 is source
# $2 dataset name
function pool_exists() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zpool_exists_cmd $ZPOOL_CMD "$2")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zpool_exists_cmd $ZPOOL_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) ]] &>/dev/null
  return
}

# test if pool supports bookmarks
# $1 is source
function pool_support_bookmarks() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zpool_bookmarks_cmd $ZPOOL_CMD "$1")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zpool_bookmarks_cmd $ZPOOL_CMD_REMOTE "$1")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) != "disabled" ]] &>/dev/null
  return
}

# test if pool supports encryption
# $1 is source
# $2 dataset name
function pool_support_encryption() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zpool_encryption_cmd $ZPOOL_CMD "$2")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zpool_encryption_cmd $ZPOOL_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) != "disabled" ]] &>/dev/null
  return
}

# command used to test if dataset exists
# $1 zfs command
# $2 dataset name
function zfs_exist_cmd() {
  echo "$1 list -H $2"
}

# command used to list available dataset
# $1 zfs command
function zfs_list_cmd() {
  echo "$1 list -H -o name"
}

# command used to get creation time
# $1 zfs command
# $2 dataset name
function zfs_creation_cmd() {
  echo "$1 get -Hp -o value creation $2"
}

# command used to get test encryption
# $1 zfs command
# $2 dataset name
function zfs_encryption_cmd() {
  echo "$1 get -Hp -o value encryption $2"
}

# command used to get a list of all snapshots
# $1 zfs command
# $2 dataset name
function zfs_snapshot_list_cmd() {
  echo "$1 list -Hp -t snapshot -o name -s creation $2"
}

# command used to get a list of all bookmarks
# $1 zfs command
# $2 dataset name
function zfs_bookmark_list_cmd() {
  echo "$1 list -Hp -t bookmark -o name -s creation $2"
}

# command used to get a list of all snapshots and bookmarks
# $1 zfs command
# $2 dataset name
function zfs_snapshot_bookmark_list_cmd() {
  echo "$1 list -Hrp -t snapshot,bookmark -o name -s creation $2"
}

# command used to create a new snapshots
# $1 zfs command
# $2 dataset name
function zfs_snapshot_create_cmd() {
  echo "$1 snapshot $2@${SNAPSHOT_PREFIX}_${ID}_$(date_text)"
}

# command used to destroy a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_destroy_cmd() {
  if [[ "$2" =~ .*[@#].* ]]; then
    echo "$1 destroy $2"
  else
    log_error "Preventing destroy command for '$2' not containing '@' or '#', since we only destroy snapshots or bookmarks."
    log_error "Abort backup."
    stop $EXIT_ERROR
  fi
}

# command used to test if snapshot has hold
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_holds_cmd() {
  echo "$1 holds -H $2"
}

# command used to hold a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_hold_cmd() {
  echo "$1 hold $SNAPSHOT_HOLD_TAG $2"
}

# command used to release a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_release_cmd() {
  echo "$1 release $SNAPSHOT_HOLD_TAG $2"
}

# command used to set property
# $1 zfs command
# $2 property=value
# $3 dataset
function zfs_set_cmd() {
  echo "$1 set $2 $3"
}

# command used to inherit property
# $1 zfs command
# $2 property
# $3 dataset
function zfs_inherit_cmd() {
  echo "$1 inherit $2 $3"
}

# command used to send a snapshot
# $1 zfs command
# $2 snapshot from name
# $3 snapshot to name
function zfs_snapshot_send_cmd() {
  local cmd
  cmd="$1 send"
  if [ -n "$SEND_PARAMETER" ]; then
    cmd="$cmd $SEND_PARAMETER"
  else
    cmd="$cmd $DEFAULT_SEND_PARAMETER"
    if [ "$FIRST_RUN" = "true" ] && [ "$SRC_DECRYPT" = "false" ]; then
      cmd="$cmd -p"
    fi
    if [ "$SRC_ENCRYPTED" = "true" ] && [ "$SRC_DECRYPT" = "false" ]; then
      cmd="$cmd -w"
    fi
  fi
  if [ -z "$2" ]; then
    cmd="$cmd $3"
  elif [ "$INTERMEDIATE" = "true" ]; then
    cmd="$cmd -I $2 $3"
  else
    cmd="$cmd -i $2 $3"
  fi
  echo "$cmd"
}

# command used to receive a snapshot
# $1 zfs command
# $2 dst dataset
# $3 is resume
function zfs_snapshot_receive_cmd() {
  local cmd
  cmd="$1 receive"
  if [ -n "$RECEIVE_PARAMETER" ]; then
    cmd="$cmd $RECEIVE_PARAMETER"
  else
    if [ "$RESUME" = "true" ]; then
      cmd="$cmd -s"
    fi
    if [ "$MOUNT" = "false" ]; then
      cmd="$cmd -u"
    fi
    if [[ -z "$3" && ("$FIRST_RUN" == "true" || "$NO_OVERRIDE" == "false") ]]; then
      cmd="$cmd -F"
    fi
  fi
  cmd="$cmd $2"
  echo "$cmd"
}

# command used to create a bookmark from snapshots
# $1 zfs command
# $2 snapshot name
function zfs_bookmark_create_cmd() {
  local bookmark
  # shellcheck disable=SC2001
  bookmark=$(sed "s/@/#/g" <<<"$2")
  echo "$1 bookmark $2 $bookmark"
}

# command used to destroy a bookmark
# $1 zfs command
# $2 bookmark name
function zfs_bookmark_destroy_cmd() {
  echo "$1 destroy $2"
}

# command used to get resume token
# $1 zfs command
# $2 dataset name
function zfs_resume_token_cmd() {
  echo "$1 get -Hp -o value receive_resume_token $2"
}

# command used to send with resume token
# $1 zfs command
# $2 resume token
function zfs_resume_send_cmd() {
  echo "$1 send -t $2"
}

# command used to freeze vm
function qm_fs_freeze_cmd() {
  echo "$QM_CMD guest cmd $VM_ID fsfreeze-freeze"
}

# command used to get freeze state of  vm
function qm_fs_state_cmd() {
  echo "$QM_CMD guest cmd $VM_ID fsfreeze-status"
}

# command used to unfreeze vm
function qm_fs_thaw_cmd() {
  echo "$QM_CMD guest cmd $VM_ID fsfreeze-thaw"
}

# command used to check vm state
function qm_state_cmd() {
  echo "$QM_CMD status $VM_ID"
}

# command used to create a snapshot
function qm_create_snapshot_cmd() {
  local cmd
  local args
  args=("$QM_CMD" "snapshot" "$VM_ID" "${SNAPSHOT_PREFIX}_${ID}_$(date_text)" "--description" "'$VM_SNAP_DESC ($ID)'")
  cmd="${args[*]}"
  if [ "$VM_STATE" = "true" ]; then
    cmd="$cmd --vmstate true"
  fi
  echo $cmd
}

# command used to delete a snapshot
# $1 snapshot name
function qm_delete_snapshot_cmd() {
  echo "$QM_CMD delsnapshot $VM_ID $1 --force true"
}

# command used to list snapshot
function qm_list_snapshots_cmd() {
  echo "$QM_CMD listsnapshot $VM_ID"
}

# remove dataset from snapshot or bookmark fully qualified name
# $1 dataset name
# $2 full name including snapshot/bookmark name
function snapshot_name() {
  if [ -n "$1" ] && [ -n "$2" ] && [ ${#2} -gt ${#1} ]; then
    echo "${2:${#1}+1}"
  fi
}

# parent from dataset
# $1 dataset
function dataset_parent() {
  local split
  local parent
  IFS='/'
  read -ra split <<<"$1"
  split=("${split[@]::${#split[@]}-1}")
  parent="${split[*]}"
  unset IFS
  echo "$parent"
}

# last node of dataset
# $1 dataset
function dataset_last_node() {
  local split
  local parent
  IFS='/'
  read -ra split <<<"$1"
  echo "${split[${#split[@]}-1]}"
}

# $1 is source
function dataset_list() {
  local cmd
  if [ "$1" = "true" ]; then
    echo "Following source datasets are available:"
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_list_cmd $ZFS_CMD)")"
  else
    echo "Following destination datasets are available:"
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_list_cmd $ZFS_CMD_REMOTE)")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 is source
# $2 dataset
function dataset_exists() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_exist_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_exist_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) ]] &>/dev/null
  return
}

# $1 is source
# $2 dataset
function dataset_encrypted() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_encryption_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_encryption_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  [[ ! $($cmd) == "off" ]] &>/dev/null
  return
}

# $1 is source
# $2 dataset
function dataset_list_snapshots() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_list_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_snapshot_list_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 is source
# $2 dataset
function dataset_list_snapshots_bookmarks() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_bookmark_list_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_snapshot_bookmark_list_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 dataset
function dataset_resume_token() {
  local cmd
  cmd="$(build_cmd "$DST_TYPE" "$(zfs_resume_token_cmd $ZFS_CMD_REMOTE "$1")")"
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 is source
# $2 snapshot name
function dataset_snapshot_holds() {
  local cmd
  cmd=
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_holds_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_holds_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 command
# $2 no dryrun
function execute() {
  log_cmd "$1"
  if [ "$DRYRUN" = "true" ] && [ -z "$2" ]; then
    log_info "dryrun ... nothing done."
    return 0
  elif [ -n "$LOG_FILE" ]; then
    eval $1 >>$LOG_FILE 2>&1
    return
  else
    eval $1
    return
  fi
}

# $1 is source
# $2 snapshot name
function execute_snapshot_hold() {
  local cmd
  cmd=
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "hold snapshot $2 ..."
  if execute "$cmd"; then
      log_debug "... snapshot $2 hold tag '$SNAPSHOT_HOLD_TAG'."
  else
      log_error "Error hold snapshot $2."
      EXECUTION_ERROR=true
  fi
  return
}


# $1 is source
# $2 snapshot name
function execute_snapshot_release() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_release_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_release_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "... release snapshot $2"
  if execute "$cmd"; then
    log_debug "... snapshot $2 released tag '$SNAPSHOT_HOLD_TAG'."
  else
    log_error "Error releasing snapshot $2."
    EXECUTION_ERROR=true
  fi
}

# $1 is source
# $2 snapshot name
function execute_snapshot_destroy() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_destroy_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_destroy_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "... destroying snapshot $2"
  if execute "$cmd"; then
    log_debug "... snapshot $2 destroyed."
  else
    log_error "Error destroying snapshot $2."
    EXECUTION_ERROR=true
  fi
}

# $1 is source
# $2 bookmark name
function execute_bookmark_destroy() {
  local cmd
  if [ "$1" = "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_bookmark_destroy_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_bookmark_destroy_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "... destroying bookmark $2 ..."
  if execute "$cmd"; then
    log_debug "... bookmark $2 destroyed."
  else
    log_error "Error destroying bookmark $2."
    EXECUTION_ERROR=true
  fi
}

# $1 snapshotname
function qm_snapshot_destroy() {
  local cmd
  local args
  local snaps
  if [ "$SNAPSHOT_USE_QM" = "true" ]; then
    cmd="$(qm_list_snapshots_cmd) | grep '$1'"
    log_cmd "$cmd"
    snaps=$(eval "$cmd")
    if [ -n "$snaps" ]; then
      cmd="$(qm_delete_snapshot_cmd "$1")"
      log_info "... destroying snapshot $1 using qm ..."
      if execute "$cmd"; then
        log_debug "... snapshot $1 destroyed."
      else
        log_error "Error destroying snapshot $1."
      fi
    else
      log_debug "... snapshot '$1' not found in qm snapshot list."
    fi
  fi
}

function distro_dependent_commands() {
  local cmd
  local zfs_remote
  local zpool_remote

  if [ -z "$SSH_CMD" ]; then
    SSH_CMD=$(command -v ssh)
  fi

  if [ -z "$MD5SUM_CMD" ]; then
    MD5SUM_CMD=$(command -v md5sum)
  fi

  if [ -z "$QM_CMD" ]; then
    QM_CMD=$(command -v qm)
  fi

  if [ -z "$CSTREAM_CMD" ]; then
    CSTREAM_CMD=$(command -v cstream)
  fi

  if [ -z "$ZFS_CMD" ]; then
    ZFS_CMD=$(command -v zfs)
  fi

  if [ -z "$ZPOOL_CMD" ]; then
    ZPOOL_CMD=$(command -v zpool)
  fi

  if [ -z "$ZFS_CMD_REMOTE" ]; then
    cmd="$(build_cmd $DST_TYPE "command -v zfs")"
    log_debug "determining destination zfs command ..."
    log_cmd "$cmd"
    zfs_remote=$($cmd)
    ZFS_CMD_REMOTE="$zfs_remote"
  fi

  if [ -z "$ZPOOL_CMD_REMOTE" ]; then
    cmd="$(build_cmd $DST_TYPE "command -v zpool")"
    log_debug "determining destination zpool command ..."
    log_cmd "$cmd"
    zpool_remote=$($cmd)
    ZPOOL_CMD_REMOTE="$zpool_remote"
  fi
}


# $1 is source
# $2 snapshot name
function release_holds_and_destroy() {
  local pattern
  local escaped_src_dataset
  local can_destroy
  local holds

  escaped_snapshot="${2//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^${escaped_snapshot}[[:space:]][[:space:]]*${SNAPSHOT_HOLD_TAG}[[:space:]].*"
  can_destroy="true"
  log_debug "getting holds ..."
  holds=$(dataset_snapshot_holds $1 $2)
  log_debug "... found holds ..."
  log_debug "$holds"
  log_debug "... filter with pattern '$pattern'"
  IFS=$'\n'
  for hold in $holds; do
    if [[ "$hold" =~ $pattern ]]; then
      log_debug "found hold with tag '$SNAPSHOT_HOLD_TAG', trying to remove ..."
      execute_snapshot_release $1 "$2"
    else
      can_destroy=false
      log_debug "... '$hold' does not match pattern."
    fi
  done
  unset IFS

  if [ "$can_destroy" = "true" ]; then
    execute_snapshot_destroy $1 "$2"
  else
    log_info "Cannot destroy snapshot '$2' because as least one other hold exists."
  fi
}

# $1 dataset name
function load_src_snapshots() {
  local pattern
  local escaped_src_dataset

  SRC_SNAPSHOTS=()
  SRC_SNAPSHOT_LAST=
  SRC_SNAPSHOT_KEEP=

  escaped_src_dataset="${1//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^${escaped_src_dataset}[#@]${SNAPSHOT_PREFIX}_${ID}.*"
  log_debug "getting source snapshot list ..."
  log_debug "... filter with pattern $pattern"
  for snap in $(dataset_list_snapshots_bookmarks true $1); do
    if [[ "$snap" =~ $pattern ]]; then
      SRC_SNAPSHOTS+=("$snap")
      log_debug "... add $snap"
    else
      log_debug "... $snap does not match pattern."
      if [ -z "$SRC_SNAPSHOT_KEEP" ] && [ ${#SRC_SNAPSHOTS[@]} -gt 0 ]; then
        SRC_SNAPSHOT_KEEP=${SRC_SNAPSHOTS[*]: -1}
        log_debug "... keep backup snapshot $SRC_SNAPSHOT_KEEP before custom snapshot $snap."
      fi
    fi
  done

  if [ ${#SRC_SNAPSHOTS[@]} -gt 0 ]; then
    SRC_SNAPSHOT_LAST=${SRC_SNAPSHOTS[*]: -1}
    log_debug "... found ${#SRC_SNAPSHOTS[@]} snapshots."
    log_debug "... last snapshot: $SRC_SNAPSHOT_LAST"
  else
    log_debug "... no snapshot found."
  fi
}

# $1 dest dataset name
# $2 src dataset name
function load_dst_snapshots() {
  local pattern
  local escaped_dst_dataset
  local dst_name
  local src_name

  DST_SNAPSHOTS=()
  DST_SNAPSHOT_LAST=
  DST_SNAPSHOT_KEEP=
  SRC_SNAPSHOT_LAST_SYNCED=

  escaped_dst_dataset="${1//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^$escaped_dst_dataset[@]${SNAPSHOT_PREFIX}_${ID}.*"
  log_debug "getting destination snapshot list ..."
  log_debug "... filter with pattern $pattern"
  for snap in $(dataset_list_snapshots false $1); do
    if [[ "$snap" =~ $pattern ]]; then
      log_debug "... add $snap"
      DST_SNAPSHOTS+=("$snap")
      if [ -n "$SRC_SNAPSHOT_KEEP" ] && [ -z "$DST_SNAPSHOT_KEEP" ]; then
        dst_name="$(snapshot_name $1 $snap)"
        src_name="$(snapshot_name $2 $SRC_SNAPSHOT_KEEP)"
        if [ "$src_name" = "$dst_name" ]; then
          DST_SNAPSHOT_KEEP=$snap
        fi
        dst_name=
        src_name=
        log_debug "... keep backup snapshot $DST_SNAPSHOT_KEEP before custom snapshot."
      fi
    else
      log_debug "... $snap does not match pattern."
    fi
  done

  if [ ${#DST_SNAPSHOTS[@]} -gt 0 ]; then
    DST_SNAPSHOT_LAST=${DST_SNAPSHOTS[*]: -1}
    log_debug "... found ${#DST_SNAPSHOTS[@]} snapshots."
    log_debug "... last snapshot: $DST_SNAPSHOT_LAST"
    dst_name="$(snapshot_name $1 $DST_SNAPSHOT_LAST)"
    for snap in "${SRC_SNAPSHOTS[@]}"; do
      src_name="$(snapshot_name $2 $snap)"
      if [ "$src_name" = "$dst_name" ]; then
        SRC_SNAPSHOT_LAST_SYNCED=$snap
      fi
    done
    log_debug "... last synced snapshot: $SRC_SNAPSHOT_LAST_SYNCED"
  else
    log_debug "... no snapshot found."
  fi
}

function load_src_datasets() {
  local cmd
  local disks
  local path
  local dataset
  local disk_pattern
  disk_pattern=${VM_DISK_PATTERN//%VM_ID%/$VM_ID}
  cmd="grep '$disk_pattern' $VM_CONF_SRC | sed 's/.*. //' | sed 's/,.*//' | sort -u"
  log_debug "getting disks attached to vm $VM_ID ..."
  log_cmd "$cmd"
  disks=$(eval "$cmd")
  for disk in $disks; do
    log_debug "... finding dataset for disk '$disk' ..."
    path=$(pvesm path "$disk")
    if [[ $path == /dev/zvol/* ]]; then
      dataset=$(pvesm path "$disk" | sed 's#/dev/zvol/##')
      log_debug "... found dataset '$dataset'"
      SRC_DATASETS+=("$dataset")
    elif [ "$ALLOW_NONE_ZFS" = "true" ]; then
      log_info "... disk '$disk' has path '$path' which is not a zfs dataset and will be ignored."
    else
      log_error "... disk '$disk' has path '$path' which is not a zfs dataset - abort."
      stop $EXIT_ERROR
    fi
  done
  log_debug "found following source datasets: ${SRC_DATASETS[*]}"
}

# Parameter validation
function validate() {
  local exit_code
  if [ -z "$VM_ID" ]; then
    log_error "Missing parameter -vm | --vmid for virtual machine to backup."
    exit_code=$EXIT_MISSING_PARAM
  fi

  # check if vm exists on this node
  if [ -f "$PVE_CONF_DIR/$VM_ID.conf" ]; then
    log_info "VM with ID $VM_ID found on current node."
    VM_CONF_SRC="$PVE_CONF_DIR/$VM_ID.conf"
  else
    log_info "VM with ID $VM_ID does not exists on this node, looking on other ..."
    for f in "$PVE_NODES_DIR/"*"/$PVE_QEMU_DIR/$VM_ID".conf; do
      log_info "$f"
      if [ -f "$f" ]; then
        log_info "VM with ID $VM_ID does exist on other node ($f)."
        VM_CONF_SRC="$f"
      else
        log_error "VM with ID $VM_ID does not exist - exiting."
        stop $EXIT_ERROR
      fi
      break
    done
  fi

  if [ -z "$DST_DATASET" ]; then
    log_error "Missing parameter -d | --dest for receiving dataset (destination)."
    exit_code=$EXIT_MISSING_PARAM
  fi

  if [ "$SRC_TYPE" = "$TYPE_SSH" ] && [ "$DST_TYPE" = "$TYPE_SSH" ]; then
    log_error "You can use type 'ssh' only for source or destination but not both."
    exit_code=$EXIT_INVALID_PARAM
  elif [ "$SRC_TYPE" = "$TYPE_SSH" ] || [ "$DST_TYPE" = "$TYPE_SSH" ]; then
    if [ -z "$SSH_HOST" ]; then
      log_error "Missing parameter --ssh_host for sending or receiving host."
      exit_code=$EXIT_MISSING_PARAM
    fi
  fi

  if [ -z "$ID" ]; then
    ID="$($MD5SUM_CMD <<<"$DST_DATASET$SSH_HOST")"
    ID="${ID:0:$ID_LENGTH}"
  fi
  if ! [[ "$ID" =~ ^[a-zA-Z0-9]*$ ]]; then
    log_error "ID -i must only contain characters and numbers. You used '$ID'."
    exit_code=$EXIT_INVALID_PARAM
  fi

  if [ -n "$DST_PROP" ]; then
    IFS=',' read -ra DST_PROP_ARRAY <<<"$DST_PROP"
    unset IFS
  fi

  if [ -n "$exit_code" ]; then
    echo
    usage
    stop $exit_code
  fi

  # load datasets from vm config and check if they exists
  log_debug "checking if source datasets for vm $VM_ID exists ..."
  load_src_datasets
  if [ ${#SRC_DATASETS[@]} -eq 0 ]; then
    log_error "Unable to extract source datasets from vm config ($VM_CONF_SRC)."
    stop $EXIT_ERROR
  fi
  for sds in "${SRC_DATASETS[@]}"; do
    if dataset_exists true $sds; then
      log_debug "... '$sds' exits and ..."
    else
      log_error "Source dataset '$sds' found in vm config does not exist."
      stop $EXIT_ERROR
    fi
  done
}

# validation of current dataset
# $1 src dataset name
function validate_dataset() {
  if dataset_encrypted true $1; then
    log_debug "... is encrypted"
    SRC_ENCRYPTED=true
  else
    log_debug "... is not encrypted"
  fi

  # bookmarks only make sense if snapshot count on source side is 1
  if [ "$SRC_COUNT" = "1" ]; then
    if [ "$BOOKMARK" = "true" ]; then
      log_debug "checking if pool of source '$1' support bookmarks ..."
      if pool_support_bookmarks true; then
        log_debug "... bookmarks supported"
        BOOKMARK=true
      else
        log_debug "... bookmarks not supported"
        BOOKMARK=false
      fi
    fi
  elif [ "$BOOKMARK" = "true" ]; then
    log_warn "Bookmark option --bookmark will be ignored since you are using a snapshot count $SRC_COUNT which is greater then 1."
    BOOKMARK=false
  fi

  DST_DATASET_CURRENT="$DST_DATASET/$(dataset_last_node $1)"
  # if we passed basic validation we load snapshots to check if this is the first sync
  load_src_snapshots $1
  # if we already have a sync done skip destination checks
  if [ -z "$SRC_SNAPSHOT_LAST" ]; then
    FIRST_RUN=true
    log_debug "checking if destination dataset '$DST_DATASET_CURRENT' exists ..."
    if dataset_exists false $DST_DATASET_CURRENT; then
      log_debug "... '$DST_DATASET_CURRENT' exists."
      if [ "$SRC_ENCRYPTED" = "true" ]; then
        log_error "You cannot initially send an encrypted dataset into an existing one."
        stop $EXIT_ERROR
      fi
    else
      log_debug "... '$DST_DATASET_CURRENT' does not exist."
      if ! dataset_exists false $DST_DATASET; then
        log_error "Parent dataset $DST_DATASET does not exist."
        stop $EXIT_ERROR
      fi
      log_debug "checking if destination pool supports encryption ..."
      if pool_support_encryption false $DST_DATASET; then
        log_debug "... encryption supported"
      else
        log_debug "... encryption not supported"
        if [ "$SRC_ENCRYPTED" = "true" ]; then
          log_error "Source dataset '$1' is encrypted but target pool does not support encryption."
          stop $EXIT_ERROR
        fi
      fi
    fi
  else
    # check if destination snapshot exists
    load_dst_snapshots $DST_DATASET_CURRENT $1
    if [ -z "$DST_SNAPSHOT_LAST" ]; then
      log_error "Destination does not have a snapshot but source does."
      if [ "$RESUME" = "true" ]; then
        log_info "Look if initial sync can be resumed ..."
        if [ "$(dataset_resume_token $DST_DATASET_CURRENT)" = "-" ]; then
          log_error "... no resume token found. Please delete all snapshots and start with full sync."
        fi
      else
        log_error "Either the initial sync did not work or we are out of sync."
        log_error "Please delete all snapshots and start with full sync."
        stop $EXIT_ERROR
      fi
    elif [ -z "$SRC_SNAPSHOT_LAST_SYNCED" ]; then
      log_error "Last destination snapshot $DST_SNAPSHOT_LAST is not present at source."
      log_error "We are out of sync."
      log_error "Please delete all snapshots on both sides and start with full sync."
      stop $EXIT_ERROR
    fi
  fi
}

# $1 src dataset name
function resume() {
  # looking for resume token and resume previous aborted sync if necessary
  if [ "$FIRST_RUN" = "false" ] && [ "$RESUME" = "true" ]; then
    log_info "Looking for resume token ..."
    local resume_token
    resume_token=$(dataset_resume_token $DST_DATASET_CURRENT)
    if [ "$resume_token" = "-" ] || [ "$resume_token" = "" ]; then
      log_info "... no sync to resume."
    else
      log_info "... resuming previous aborted sync with token '${resume_token:0:20}' ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_resume_send_cmd "$ZFS_CMD" "$resume_token")") | $(build_cmd "$DST_TYPE" "$(zfs_snapshot_receive_cmd "$ZFS_CMD_REMOTE" "$DST_DATASET_CURRENT" "true")")"
      if execute "$cmd"; then
        log_info "... finished previous sync."
        # reload destination snapshots to get last
        load_dst_snapshots $DST_DATASET_CURRENT $1
        # put hold on destination snapshot
        if [ "$NO_HOLD_DEST" != "true" ]; then
          execute_snapshot_hold false "$DST_SNAPSHOT_LAST"
        fi
        log_info "Continue with new sync ..."
      else
        log_error "Error resuming previous aborted sync."
        stop $EXIT_ERROR
      fi
    fi
  fi
}

# Backup configuration
function conf_backup() {
  if [ -n "$VM_CONF_DEST" ]; then
     local cmd
     log_info "Backup configuration ..."
     cmd="$(build_cmd "$SRC_TYPE" "cat $VM_CONF_SRC") | $(build_cmd "$DST_TYPE" "'cat > $VM_CONF_DEST/${VM_ID}.conf'")"
     if ! execute "$cmd"; then       
       log_error "Error backup configuration."
       EXECUTION_ERROR=true
     fi
  fi
}

function create_snapshot() {
  local cmd
  if [ -n "$PRE_SNAPSHOT" ]; then
    if ! execute "$PRE_SNAPSHOT"; then
      log_error "Error executing pre snapshot command/script ..."
      stop $EXIT_ERROR
    fi
  fi

  local vm_state
  log_info "Check VM state ..."
  cmd="$(build_cmd "$SRC_TYPE" "$(qm_state_cmd)")"
  vm_state="$($cmd)"
  if [[ $vm_state == *running ]]; then
    log_info "VM is running."
  elif [[ $vm_state == *stopped ]]; then
    log_info "VM is stopped."
    VM_NO_FREEZE="true"
  else
    log_error "VM has undefined state '$vm_state' - abort."
    stop $EXIT_ERROR
  fi

  if [ "$VM_NO_FREEZE" = "true" ]; then
    log_info "Freeze of VM file system is skipped"
  else
    log_info "Freeze VM file system ..."
    cmd="$(build_cmd "$SRC_TYPE" "$(qm_fs_freeze_cmd)")"
    if ! execute "$cmd"; then       
      log_error "Error freezing VM."
      stop $EXIT_ERROR
    fi
  fi

  if [ -n "$SNAPSHOT_EXTERNAL_COMMAND" ]; then
    log_info "Using external command to create snapshots ..."
    cmd="$(build_cmd "$SRC_TYPE" "$SNAPSHOT_EXTERNAL_COMMAND ${SRC_DATASETS[*]}")"
    if ! execute "$cmd"; then
      log_error "Error creating new snapshot with external command."
      thaw
      stop $EXIT_ERROR
    fi
  elif [ "$SNAPSHOT_USE_QM" = "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(qm_create_snapshot_cmd)")"
    log_info "Creating new snapshot for sync using qm ..."
    if ! execute "$cmd"; then
      log_error "Error creating new snapshot."
      thaw
      stop $EXIT_ERROR
    fi
  else
    log_info "Creating new snapshot for sync using zfs ..."
    for sds in "${SRC_DATASETS[@]}"; do
      log_info "... creating snapshot for $sds ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_create_cmd "$ZFS_CMD" "$sds")")"
      if ! execute "$cmd"; then
        log_error "Error creating new snapshot."
        thaw
        stop $EXIT_ERROR
      fi
    done
  fi

  thaw

  if [ -n "$POST_SNAPSHOT" ]; then
    if ! execute "$POST_SNAPSHOT"; then
      log_error "Error executing post snapshot command/script ..."
      EXECUTION_ERROR=true
    fi
  fi
}

function thaw() {
  if [ "$VM_NO_FREEZE" != "true" ]; then
    log_info "Thaw VM filesystem ..."
    cmd="$(build_cmd "$SRC_TYPE" "$(qm_fs_thaw_cmd)")"
    if ! execute "$cmd"; then
      log_error "Error thawing VM."
      EXECUTION_ERROR=true
    fi
  fi
}

# $1 dataset
function send_snapshot() {
  local cmd
  local limit
  log_info "sending snapshot '$SRC_SNAPSHOT_LAST' ..."
  cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_send_cmd "$ZFS_CMD" "$SRC_SNAPSHOT_LAST_SYNCED" "$SRC_SNAPSHOT_LAST")")"
  if [ -n "$LIMIT_BANDWIDTH" ]; then
    limit=$((LIMIT_BANDWIDTH*1024))
    if [ "$limit" -ge 1024 ]; then
      log_debug "limiting bandwith to $LIMIT_BANDWIDTH KB ..."
      cmd="$cmd | $CSTREAM_CMD -t $limit"
    else
      log_error "--limit value must be a number larger then 0, current value '$LIMIT_BANDWIDTH' is not valid - no limit applied."
      EXECUTION_ERROR=true
    fi
  fi
  cmd="$cmd | $(build_cmd "$DST_TYPE" "$(zfs_snapshot_receive_cmd "$ZFS_CMD_REMOTE" "$DST_DATASET_CURRENT")")"
  if execute "$cmd"; then
    if [ "$FIRST_RUN" = "true" ]; then
      [ -n "$DST_PROP" ] && log_info "setting properties at destination ... "
      for prop in "${DST_PROP_ARRAY[@]}"; do
        if [[ "$prop" =~ .*inherit$ ]]; then
          cmd="$(build_cmd "$DST_TYPE" "$(zfs_inherit_cmd "$ZFS_CMD_REMOTE" "${prop/=inherit/}" "$DST_DATASET_CURRENT")")"
          if execute "$cmd"; then
            log_debug "Property ${prop/=inherit/} inherited on destination dataset $DST_DATASET_CURRENT."
          else
            log_error "Error setting property $prop on destination dataset $DST_DATASET_CURRENT."
            EXECUTION_ERROR=true
          fi
        else
          cmd="$(build_cmd "$DST_TYPE" "$(zfs_set_cmd "$ZFS_CMD_REMOTE" "$prop" "$DST_DATASET_CURRENT")")"
          if execute "$cmd"; then
            log_debug "Property $prop set on destination dataset $DST_DATASET_CURRENT."
          else
            log_error "Error setting property $prop on destination dataset $DST_DATASET_CURRENT."
            EXECUTION_ERROR=true
          fi
        fi
      done
    fi
    # reload destination snapshots to get last
    load_dst_snapshots $DST_DATASET_CURRENT $1

    # put hold on destination snapshot
    if [ "$NO_HOLD_DEST" != "true" ]; then
      execute_snapshot_hold false "$DST_SNAPSHOT_LAST"
    fi

    # convert snapshot to bookmark
    if [ "$BOOKMARK" = "true" ]; then
      log_info "converting snapshot '$SRC_SNAPSHOT_LAST' to bookmark ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_bookmark_create_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
      if execute "$cmd"; then
        execute_snapshot_destroy true "$SRC_SNAPSHOT_LAST"
      else
        log_error "Error converting snapshot to bookmark."
        EXECUTION_ERROR=true
      fi
    fi
  else
    log_error "Error sending snapshot."
    [ "$FIRST_RUN" = "true" ] && help_permissions_receive
    if [ "$INTERMEDIATE" = "true" ] || [ "$RESUME" = "true" ]; then
      log_info "Keeping unsent snapshot $SRC_SNAPSHOT_LAST for later send."
    else
      log_info "Destroying unsent snapshot $SRC_SNAPSHOT_LAST ..."
      release_holds_and_destroy true "$SRC_SNAPSHOT_LAST"
    fi
    stop $EXIT_ERROR
  fi
}

# $1 dataset
function do_backup() {
  # reload source snapshots to get last
  load_src_snapshots $1

  if [ -z "$SRC_SNAPSHOT_LAST" ]; then
    log_error "No snapshot found."
    if [ "$DRYRUN" = "true" ]; then
      log_info "dryrun using dummy snapshot '$1@dryrun_${SNAPSHOT_PREFIX}_${ID}_$(date_text)' ..."
      SRC_SNAPSHOT_LAST="$1@dryrun_${SNAPSHOT_PREFIX}_${ID}_$(date_text)"
    else
      stop $EXIT_ERROR
    fi
  fi

  # put hold on source snapshot
  if [ "$NO_HOLD" = "false" ] && [ "$BOOKMARK" = "false" ]; then
    execute_snapshot_hold true "$SRC_SNAPSHOT_LAST"
  fi

  if [ -z "$SRC_SNAPSHOT_LAST_SYNCED" ]; then
    log_info "No synced snapshot found."
    log_info "Using newest snapshot '$SRC_SNAPSHOT_LAST' for initial sync ..."
  else
    log_info "Using last synced snapshot '$SRC_SNAPSHOT_LAST_SYNCED' for incremental sync ..."
  fi

  # sending snapshot
  send_snapshot $1

  # cleanup successfully send snapshots on both sides
  if [ ! "$SNAPSHOT_USE_QM" = "true" ]; then
    load_src_snapshots $1
    if [ ${#SRC_SNAPSHOTS[@]} -gt "$SRC_COUNT" ]; then
      log_info "Destroying old source snapshots ..."
      for snap in "${SRC_SNAPSHOTS[@]::${#SRC_SNAPSHOTS[@]}-$SRC_COUNT}"; do
        if [ "$snap" = "$SRC_SNAPSHOT_KEEP" ]; then
          log_info "... keeping snapshot $snap, because its the last one or last one before non backup snapshots."
        else
          if [[ "$snap" =~ @ ]]; then
            release_holds_and_destroy true "$snap"
          else
            execute_bookmark_destroy true "$snap"
          fi
        fi
      done
    fi
  fi

  if [ ${#DST_SNAPSHOTS[@]} -gt "$DST_COUNT" ]; then
    log_info "Destroying old destination snapshots ..."
    for snap in "${DST_SNAPSHOTS[@]::${#DST_SNAPSHOTS[@]}-$DST_COUNT}"; do
      if [ "$snap" = "$DST_SNAPSHOT_KEEP" ]; then
        log_info "... keeping snapshot $snap, because its the last one or last one before non backup snapshots."
      else
        release_holds_and_destroy false "$snap"
      fi
    done
  fi
}

# $1 dataset
function do_cleanup_old_from_other() {
  # source snapshots to get last
  load_src_snapshots $1
  if [ -z "$SRC_SNAPSHOT_LAST" ]; then
    log_info "... no snapshot exists."
  else
    load_dst_snapshots $DST_DATASET_CURRENT $1
    log_info "Destroying source snapshots which no longer exists on destination ..."
    local delete
    for src_snap in "${SRC_SNAPSHOTS[@]}"; do
      delete="true"
      for dst_snap in "${DST_SNAPSHOTS[@]}"; do
        if [ "$dst_snap" = "$src_snap" ]; then
          delete="false"
          log_info "Source snapshot $src_snap exists on destination and will retain."
        fi
      done
      if [ "$delete" = "true" ]; then
        log_info "Source snapshot $src_snap does not exits on destination and will be deleted."
        if [[ "$src_snap" =~ @ ]]; then
          release_holds_and_destroy true "$src_snap"
        else
          execute_bookmark_destroy true "$src_snap"
        fi
      fi
    done
  fi
}

function cleanup_source_using_qm() {
  local first_dataset
  if [ "$SNAPSHOT_USE_QM" = "true" ] && [ ${#SRC_DATASETS[@]} -gt 0 ]; then
    first_dataset=${SRC_DATASETS[0]}
    load_src_snapshots "$first_dataset"
    if [ ${#SRC_SNAPSHOTS[@]} -gt "$SRC_COUNT" ]; then
      log_info "Destroying old source snapshots ..."
      for snap in "${SRC_SNAPSHOTS[@]::${#SRC_SNAPSHOTS[@]}-$SRC_COUNT}"; do
        if [ "$snap" = "$SRC_SNAPSHOT_KEEP" ]; then
          log_info "... keeping snapshot $snap, because its the last one or last one before non backup snapshots."
        else
          qm_snapshot_destroy "$(snapshot_name $first_dataset $snap)"
        fi
      done
    fi
  fi
}

function create_config() {
  local config
  config="#######
## Config generated by zfs-backup-pve $VERSION at $(date +"$LOG_DATE_PATTERN")
#######

## ZFS commands
# The script is trying to find the right path
# but you can set it if it fails
#ZFS_CMD=$ZFS_CMD
#ZPOOL_CMD=$ZPOOL_CMD
#SSH_CMD=$SSH_CMD
#MD5SUM_CMD=$MD5SUM_CMD
#ZFS_CMD_REMOTE=$ZFS_CMD_REMOTE
#ZPOOL_CMD_REMOTE=$ZFS_CMD_REMOTE
#QM_CMD=$QM_CMD
#CSTREAM_CMD=$CSTREAM_CMD

## VM Settings
# $VM_ID_HELP
VM_ID=$VM_ID
# VM disk name schema, %VM_ID% is replace by VM_ID
#VM_DISK_PATTERN=\"vm-%VM_ID%-disk-\"
# $VM_STATE_HELP
#VM_STATE=false
# $VM_SNAP_DESC_HELP
#VM_SNAP_DESC=zfsbackup
# $VM_CONF_DEST_HELP
VM_CONF_DEST=
# $VM_NO_FREEZE_HELP
VM_NO_FREEZE=$VM_NO_FREEZE

## Destination ID
# Unique id of target system for example 'nas' of 'home'
# This id is used to separate backups of the same source
# to multiple targets.
# If this is not set the id is auto generated to the
# md5sum of destination dataset and ssh host (if present).
# Use only A-Za-z0-9 and maximum of $ID_LENGTH characters.
ID=\"$ID\"

## Source dataset options
# $SRC_TYPE_HELP
SRC_TYPE=$SRC_TYPE
# ${DECRYPT_HElP[0]}
# ${DECRYPT_HElP[1]}
SRC_DECRYPT=$SRC_DECRYPT
# $SRC_COUNT_HELP
SRC_COUNT=$SRC_COUNT

## Destination dataset options
# $DST_DATASET_HELP
DST_DATASET=\"$DST_DATASET\"
# $DST_TYPE_HELP
DST_TYPE=$DST_TYPE
# $DST_COUNT_HELP
DST_COUNT=$DST_COUNT
# ${DST_PROP_HELP[0]}
# ${DST_PROP_HELP[1]}
# ${DST_PROP_HELP[2]}
DST_PROP=$DST_PROP

# $LIMIT_BANDWIDTH_HELP
LIMIT_BANDWIDTH=$LIMIT_BANDWIDTH

# $ALLOW_NONE_ZFS_HELP
#ALLOW_NONE_ZFS=false

# Snapshot pre-/postfix and hold tag
#SNAPSHOT_PREFIX=\"bkp\"
#SNAPSHOT_HOLD_TAG=\"zfsbackup\"
# $SNAPSHOT_USE_QM_HELP
#SNAPSHOT_USE_QM=false
# $NO_SNAPSHOT_HELP
#SNAPSHOT_CREATE=true
# $SNAPSHOT_CMD_HELP
#SNAPSHOT_EXTERNAL_COMMAND=

## SSH parameter
# $SSH_HOST_HELP
SSH_HOST=\"$SSH_HOST\"
# $SSH_PORT_HELP
SSH_PORT=\"$SSH_PORT\"
# $SSH_USER_HELP
SSH_USER=\"$SSH_USER\"
# $SSH_KEY_HELP
SSH_KEY=\"$SSH_KEY\"
# $SSH_OPT_HELP
# SSH_OPT=\"-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new\"
SSH_OPT=\"$SSH_OPT\"

## E-Mail Notification
# To enable email notification set \$MAIL_TO parameter.
# $MAIL_TO_HELP
#MAIL_TO=\"$MAIL_TO\"
# $MAIL_FROM_HELP
#MAIL_FROM=\"$MAIL_FROM\"
# $MAIL_SUBJECT_HELP
#MAIL_SUBJECT=\"$MAIL_SUBJECT\"
# $MAIL_ON_SUCCESS_HELP
#MAIL_ON_SUCCESS=$MAIL_ON_SUCCESS

# Backup style configuration
# $BOOKMARK_HELP
BOOKMARK=$BOOKMARK
# $RESUME_HELP
RESUME=$RESUME
# ${INTERMEDIATE_HElP[0]}
# ${INTERMEDIATE_HElP[1]}
INTERMEDIATE=$INTERMEDIATE
# ${NO_OVERRIDE_HElP[0]}
# ${NO_OVERRIDE_HElP[1]}
NO_OVERRIDE=$NO_OVERRIDE
# $NO_HOLD_HELP
# $NO_HOLD_NOTE
NO_HOLD=$NO_HOLD
# $NO_HOLD_DEST_HELP
NO_HOLD_DEST=$NO_HOLD_DEST
# $DEBUG_HELP
DEBUG=$DEBUG

# $SEND_PARAMETER_HELP
SEND_PARAMETER=\"$SEND_PARAMETER\"
# $RECEIVE_PARAMETER_HELP
RECEIVE_PARAMETER=\"$RECEIVE_PARAMETER\"

## Scripts and commands
# ${ONLY_IF_HELP[0]}
# ${ONLY_IF_HELP[1]}
# ${ONLY_IF_HELP[3]}
# ${ONLY_IF_HELP[4]}
ONLY_IF=\"$ONLY_IF\"
# $PRE_RUN_HELP
PRE_RUN=\"$PRE_RUN\"
# $POST_RUN_HELP
POST_RUN=\"$POST_RUN\"
# $PRE_SNAPSHOT_HELP
PRE_SNAPSHOT=\"$PRE_SNAPSHOT\"
# $POST_SNAPSHOT_HELP
POST_SNAPSHOT=\"$POST_SNAPSHOT\"

# Logging options
# LOG_FILE_HELP
LOG_FILE=$LOG_FILE
LOG_DATE_PATTERN=\"$LOG_FILE_DATE_PATTERN\"
# $LOG_FILE_KEEP_HELP
LOG_FILE_KEEP=$LOG_FILE_KEEP
#LOG_DATE_PATTERN=\"%Y-%m-%d - %H:%M:%S\"
#LOG_DEBUG=\"[DEBUG]\"
#LOG_INFO=\"[INFO]\"
#LOG_WARN=\"[WARN]\"
#LOG_ERROR=\"[ERROR]\"
#LOG_CMD=\"[COMMAND]\"
"
  if [ -n "$CONFIG_FILE" ]; then
    echo "$config" >$CONFIG_FILE
    echo "Configuration was written to $CONFIG_FILE."
  else
    echo "$config"
  fi
}

# $1 exit code
function mail_subject() {
  local subj
  if [ $1 = $EXIT_ERROR ]; then
    subj="${MAIL_SUBJECT//%RESULT%/"ERROR"}"
  else
    subj="${MAIL_SUBJECT//%RESULT%/"SUCCESS"}"
  fi
  subj="${subj//%VMID%/$VM_ID}"
  subj="${subj//%ID%/$ID}"
  subj="${subj//%DATE%/$(date +"$LOG_DATE_PATTERN")}"
  echo $subj
}

function start() {
  log_info "Starting zfs-backup-pve ..."
  if [ -n "$ONLY_IF" ]; then
    log_debug "check if backup should be done ..."
    if execute "$ONLY_IF" "false"; then
      log_debug "... pre condition are met, continue."
    else
      log_error "... pre conditions are not met, abort backup."
      exit $EXIT_OK
    fi
  fi
  if [ -n "$PRE_RUN" ]; then
    log_debug "executing pre run script ..."
    if execute "$PRE_RUN" "false"; then
      log_debug "... done"
    else
      log_error "Error executing pre run script, abort backup."
    fi
  fi
}

# $1 exit code
function stop() {
  if [ -n "$MAIL_TO" ]; then
    if [ "$1" == "$EXIT_ERROR" ] || { [ "$1" == "$EXIT_OK" ] && [ "$MAIL_ON_SUCCESS" == "true" ]; }; then
        log_debug "sending email ..."
        local mail_subj
        mail_subj="$(mail_subject $1)"
        args=(-s "$mail_subj" -a "From: $MAIL_FROM" "$MAIL_TO")
        if [ -n "$LOG_FILE" ]; then
          mail "${args[@]}" < "$LOG_FILE"
        else
          echo "No logfile specified." | mail "${args[@]}"
        fi
    fi
  fi
  if [ -n "$POST_RUN" ]; then
    log_debug "executing post run script ..."
    if execute "$POST_RUN" "false"; then
      log_debug "... done"
    else
      log_error "Error executing post run script, abort backup."
    fi
  fi
  # log cleanup
  if [ -n "$LOG_FILE_SEARCH" ]; then
    # shellcheck disable=SC2207
    old_logs=($(find $LOG_FILE_SEARCH -type f | sort -n | head -n -"$LOG_FILE_KEEP"))
    for file in "${old_logs[@]}"; do
        log_info "deleting old logfile $file"
        rm $file
    done
  fi
  exit $1
}

# main function calls
load_config
start
distro_dependent_commands
validate
if [ "$MAKE_CONFIG" = "true" ]; then
  create_config
else
  if [ "$VM_CONF_SRC" = "$PVE_CONF_DIR/$VM_ID.conf" ]; then
    if [ "$SNAPSHOT_CREATE" = "true" ]; then
      log_info "Creating snapshot(s) ..."
      create_snapshot
    else
      log_info "Snapshot creation skipped ..."
    fi
    for sds in "${SRC_DATASETS[@]}"; do
      log_info "Backup dataset '$sds' ..."
      validate_dataset $sds
      resume $sds
      do_backup $sds
    done
    cleanup_source_using_qm
    conf_backup
  else
    for sds in "${SRC_DATASETS[@]}"; do
      log_info "Cleanup snapshot for dataset '$sds' created by other host ..."
      DST_DATASET_CURRENT="$DST_DATASET/$(dataset_last_node $sds)"
      do_cleanup_old_from_other $sds
    done
  fi
  if [ "$EXECUTION_ERROR" = "true" ]; then
    log_error "... zfs-backup-pve finished with errors."
    stop $EXIT_WARN
  else
    log_info "... zfs-backup-pve finished successful."
    stop $EXIT_OK
  fi
fi
