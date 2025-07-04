#!/usr/bin/env -S bash -euo pipefail
# -------------------------------------------------------------------------------------------------------------------- #
# DATABASE BACKUP
# Backup of PostgreSQL and MariaDB databases.
# -------------------------------------------------------------------------------------------------------------------- #
# @package    Bash
# @author     Kai Kimera <mail@kai.kim>
# @license    MIT
# @version    0.1.0
# @link       https://lib.onl/ru/2025/05/57f8f8c0-b963-5708-b310-129ea98a2423/
# -------------------------------------------------------------------------------------------------------------------- #

(( EUID != 0 )) && { echo >&2 'This script should be run as root!'; exit 1; }

# -------------------------------------------------------------------------------------------------------------------- #
# CONFIGURATION
# -------------------------------------------------------------------------------------------------------------------- #

# Sources.
SRC_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd -P )"
SRC_NAME="$( basename "$( readlink -f "${BASH_SOURCE[0]}" )" )"
# shellcheck source=/dev/null
. "${SRC_DIR}/${SRC_NAME%.*}.conf"

# Parameters.
DB_SRC=("${DB_SRC[@]:?}"); readonly DB_SRC
DB_USER="${DB_USER:?}"; readonly DB_USER
DB_PASS="${DB_PASS:?}"; readonly DB_PASS
FS_DST="${FS_DST:?}"; readonly FS_DST
FS_TPL="${FS_TPL:?}"; readonly FS_TPL
ENC_ON="${ENC_ON:?}"; readonly ENC_ON
ENC_APP="${ENC_APP:?}"; readonly ENC_APP
ENC_PASS="${ENC_PASS:?}"; readonly ENC_PASS
SSH_ON="${SSH_ON:?}"; readonly SSH_ON
SSH_HOST="${SSH_HOST:?}"; readonly SSH_HOST
SSH_USER="${SSH_USER:?}"; readonly SSH_USER
SSH_PASS="${SSH_PASS:?}"; readonly SSH_PASS
SSH_DST="${SSH_DST:?}"; readonly SSH_DST
SSH_MNT="${SSH_MNT:?}"; readonly SSH_MNT
RSYNC_ON="${RSYNC_ON:?}"; readonly RSYNC_ON
RSYNC_HOST="${RSYNC_HOST:?}"; readonly RSYNC_HOST
RSYNC_USER="${RSYNC_USER:?}"; readonly RSYNC_USER
RSYNC_PASS="${RSYNC_PASS:?}"; readonly RSYNC_PASS
RSYNC_DST="${RSYNC_DST:?}"; readonly RSYNC_DST
MAIL_ON="${MAIL_ON:?}"; readonly MAIL_ON
MAIL_FROM="${MAIL_FROM:?}"; readonly MAIL_FROM
MAIL_TO=("${MAIL_TO[@]:?}"); readonly MAIL_TO
GITLAB_ON="${GITLAB_ON:?}"; readonly GITLAB_ON
GITLAB_API="${GITLAB_API:?}"; readonly GITLAB_API
GITLAB_PROJECT="${GITLAB_PROJECT:?}"; readonly GITLAB_PROJECT
GITLAB_TOKEN="${GITLAB_TOKEN:?}"; readonly GITLAB_TOKEN

# Variables.
LOG_TS="$( date '+%FT%T%:z' ) $( hostname -f ) ${SRC_NAME}"
LOG_MOUNT="${SRC_DIR}/log.mount"
LOG_CHECK="${SRC_DIR}/log.check"
LOG_BACKUP="${SRC_DIR}/log.backup"
LOG_SYNC="${SRC_DIR}/log.sync"
LOG_CLEAN="${SRC_DIR}/log.clean"

# -------------------------------------------------------------------------------------------------------------------- #
# -----------------------------------------------------< SCRIPT >----------------------------------------------------- #
# -------------------------------------------------------------------------------------------------------------------- #

function _error() {
  echo "${LOG_TS}: $*" >&2; exit 1
}

function _success() {
  echo "${LOG_TS}: $*" >&2
}

function _mail() {
  (( ! "${MAIL_ON}" )) && return 0

  local type; type="#type:backup:${1}"
  local subj; subj="[$( hostname -f )] ${SRC_NAME}: ${2}"
  local body; body="${3}"
  local id; id="#id:$( hostname -f ):$( dmidecode -s 'system-uuid' )"
  local ip; ip="#ip:$( hostname -I )"
  local date; date="#date:$( date '+%FT%T%:z' )"
  local opts; opts=('-S' 'v15-compat' '-s' "${subj}" '-r' "${MAIL_FROM}")
  [[ "${MAIL_SMTP_SERVER:-}" ]] && opts+=(
    '-S' "mta=${MAIL_SMTP_SERVER} smtp-use-starttls"
    '-S' "smtp-auth=${MAIL_SMTP_AUTH:-none}"
  )
  opts+=('-.')

  printf "%s\n\n-- \n%s\n%s\n%s\n%s" "${body}" "${id^^}" "${ip^^}" "${date^^}" "${type^^}" \
    | s-nail "${opts[@]}" "${MAIL_TO[@]}"
}

function _gitlab() {
  (( ! "${GITLAB_ON}" )) && return 0

  local label; label="${1}"
  local title; title="[$( hostname -f )] ${SRC_NAME}: ${2}"
  local desc; desc="${3}"
  local id; id="#id:$( hostname -f ):$( dmidecode -s 'system-uuid' )"
  local ip; ip="#ip:$( hostname -I )"
  local date; date="#date:$( date '+%FT%T%:z' )"
  local type; type="#type:backup:${label}"

  curl "${GITLAB_API}/projects/${GITLAB_PROJECT}/issues" -X 'POST' -kfsLo '/dev/null' \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H 'Content-Type: application/json' \
    -d @- <<EOF
{
  "title": "${title}",
  "description": "${desc//\'/\`}\n\n---\n\n- \`${id^^}\`\n- \`${ip^^}\`\n- \`${date^^}\`\n- \`${type^^}\`",
  "labels": "backup,database,${label}"
}
EOF
}

function _msg() {
  _mail "${1}" "${2}" "${3}"
  _gitlab "${1}" "${2}" "${3}"

  case "${1}" in
    'error') _error "${3}" ;;
    'success') _success "${3}" ;;
    *) _error "'MSG_TYPE' does not exist!" ;;
  esac
}

function _mongo() {
  local opts; opts=(
    "--host=${DB_HOST:-127.0.0.1}"
    "--port=${DB_PORT:-27017}"
    "--username=${DB_USER:-root}"
    "--password=${DB_PASS}"
    "--authenticationDatabase=${DB_AUTH:-admin}"
    "--oplog"
    "--archive"
    "--db=${1}"
  )

  mongodump "${opts[@]}"
}

function _mysql() {
  local cmd; cmd='mariadb-dump'; [[ -x "$( command -v 'mysqldump' )" ]] && cmd='mysqldump'
  local opts; opts=(
    "--host=${DB_HOST:-127.0.0.1}"
    "--port=${DB_PORT:-3306}"
    "--user=${DB_USER:-root}"
    "--password=${DB_PASS}"
    "--databases=${1}"
  )
  (( "${MYSQL_ST:-1}" )) && opts+=('--single-transaction')
  (( "${MYSQL_SLT:-1}" )) && opts+=('--skip-lock-tables')

  "${cmd}" "${opts[@]}"
}

function _pgsql() {
  local opts; opts=(
    "--host=${DB_HOST:-127.0.0.1}"
    "--port=${DB_PORT:-5432}"
    "--username=${DB_USER:-postgres}"
    '--no-password'
    "--dbname=${1}"
  )
  (( "${PGSQL_CLN:-1}" )) && opts+=('--clean')
  (( "${PGSQL_IE:-1}" )) && opts+=('--if-exists')
  (( "${PGSQL_NO:-1}" )) && opts+=('--no-owner')
  (( "${PGSQL_NP:-1}" )) && opts+=('--no-privileges')
  (( "${PGSQL_QAI:-1}" )) && opts+=('--quote-all-identifiers')

  case "${PGSQL_FMT:-plain}" in
    'plain') opts+=('--format=plain') ;;
    'custom') opts+=('--format=custom') ;;
    *) _error "'PGSQL_FMT' does not exist!" ;;
  esac

  PGPASSWORD="${DB_PASS}" pg_dump "${opts[@]}"
}

function _dump() {
  local dbms; dbms="${1%%.*}"
  local db; db="${1##*.}"

  case "${dbms}" in
    'mongo') _mongo "${db}" ;;
    'mysql') _mysql "${db}" ;;
    'pgsql') _pgsql "${db}" ;;
    *) _error "'DBMS' does not exist!" ;;
  esac
}

function _gpg() {
  gpg --batch --passphrase "${1}" --symmetric --output "${1}.gpg" \
    --s2k-cipher-algo "${ENC_GPG_CIPHER:-AES256}" \
    --s2k-digest-algo "${ENC_GPG_DIGEST:-SHA512}" \
    --s2k-count "${ENC_GPG_COUNT:-65536}"
}

function _ssl() {
  openssl enc "-${ENC_SSL_CIPHER:-aes-256-cfb}" -out "${1}.ssl" -pass "pass:${2}" \
    -salt -md "${ENC_SSL_DIGEST:-sha512}" -iter "${ENC_SSL_COUNT:-65536}" -pbkdf2
}

function _enc() {
  if (( "${ENC_ON}" )); then
    case "${ENC_APP}" in
      'gpg') _gpg "${1}" "${ENC_PASS}" ;;
      'ssl') _ssl "${1}" "${ENC_PASS}" ;;
      *) _error "'ENC_APP' does not exist!" ;;
    esac
  else
    cat < '/dev/stdin' > "${1}"
  fi
}

function _sum() {
  local f; f="${1}"; (( "${ENC_ON}" )) && f="${1}.${ENC_APP}"

  sha256sum "${f}" | sed 's| .*/|  |g' | tee "${f}.txt" > '/dev/null'
}

function _ssh() {
  echo "${SSH_PASS}" | sshfs "${SSH_USER:-root}@${SSH_HOST}:/${1}" "${2}" -o 'password_stdin'
}

function _rsync() {
  local opts; opts=('--archive' '--quiet')
  (( "${RSYNC_DEL:-0}" )) && opts+=('--delete')
  (( "${RSYNC_RSF:-0}" )) && opts+=('--remove-source-files')
  (( "${RSYNC_PED:-0}" )) && opts+=('--prune-empty-dirs')
  (( "${RSYNC_CVS:-0}" )) && opts+=('--cvs-exclude')

  rsync "${opts[@]}" -e "sshpass -p '${RSYNC_PASS}' ssh -p ${RSYNC_PORT:-22}" \
    "${1}/" "${RSYNC_USER:-root}@${RSYNC_HOST}:${2}/"
}

function fs_mount() {
  (( ! "${SSH_ON}" )) && return 0

  local msg_e; msg_e=(
    'error'
    'Error mounting SSH FS!'
    "Error mounting SSH FS to '${SSH_MNT}'!"
  )

  _ssh "${SSH_DST}" "${SSH_MNT}" || _msg "${msg_e[@]}"
}

function fs_check() {
  local file; file="${FS_DST}/.backup_db"; [[ -f "${file}" ]] && return 0
  local msg_e; msg_e=(
    'error'
    "File '${file}' not found!"
    "File '${file}' not found! Please check the remote storage status!"
  ); _msg "${msg_e[@]}"
}

function db_backup() {
  local ts; ts="$( date -u '+%m.%d-%H' )"

  for i in "${DB_SRC[@]}"; do
    local dst; dst="${FS_DST}/${FS_TPL}"
    local file; file="${i}.${ts}.xz"
    local msg_e; msg_e=(
      'error'
      "Error backing up database '${i}'"
      "Error backing up database '${i}'! File '${dst}/${file}' not received or corrupted!"
    )
    local msg_s; msg_s=(
      'success'
      "Backup of database '${i}' completed successfully"
      "Backup of database '${i}' completed successfully. File '${dst}/${file}' received."
    )

    [[ ! -d "${dst}" ]] && mkdir -p "${dst}"; cd "${dst}" || _error "Directory '${dst}' not found!"
    { { { _dump "${i}" | xz | _enc "${file}"; } && _sum "${file}"; } && _msg "${msg_s[@]}"; } \
      || _msg "${msg_e[@]}"
  done
}

function fs_sync() {
  (( ! "${RSYNC_ON}" )) && return 0

  local msg_e; msg_e=(
    'error'
    'Error synchronizing with remote storage'
    'Error synchronizing with remote storage!'
  )
  local msg_s; msg_s=(
    'success'
    'Synchronization with remote storage completed successfully'
    'Synchronization with remote storage completed successfully.'
  )

  { _rsync "${FS_DST}" "${RSYNC_DST}" && _msg "${msg_s[@]}"; } || _msg "${msg_e[@]}"
}

function fs_clean() {
  [[ "${FS_DAYS:-}" ]] || find "${FS_DST}" -type 'f' -mtime "+${FS_DAYS:-30}" -print0 | xargs -0 rm -f --
  find "${FS_DST}" -mindepth 1 -type 'd' -not -name 'lost+found' -empty -delete
}

function main() {
  { fs_mount 2>&1 | tee "${LOG_MOUNT}"; } \
    && { fs_check 2>&1 | tee "${LOG_CHECK}"; } \
    && { db_backup 2>&1 | tee "${LOG_BACKUP}"; } \
    && { fs_sync 2>&1 | tee "${LOG_SYNC}"; } \
    && { fs_clean 2>&1 | tee "${LOG_CLEAN}"; }
}; main "$@"
