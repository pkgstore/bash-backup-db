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
DB_DST="${DB_DST:?}"; readonly DB_DST
DB_USER="${DB_USER:?}"; readonly DB_USER
DB_PASS="${DB_PASS:?}"; readonly DB_PASS
ENC_ON="${ENC_ON:?}"; readonly ENC_ON
ENC_APP="${ENC_APP:?}"; readonly ENC_APP
ENC_PASS="${ENC_PASS:?}"; readonly ENC_PASS
SYNC_ON="${SYNC_ON:?}"; readonly SYNC_ON
SYNC_HOST="${SYNC_HOST:?}"; readonly SYNC_HOST
SYNC_USER="${SYNC_USER:?}"; readonly SYNC_USER
SYNC_PASS="${SYNC_PASS:?}"; readonly SYNC_PASS
SYNC_DST="${SYNC_DST:?}"; readonly SYNC_DST
MAIL_ON="${MAIL_ON:?}"; readonly MAIL_ON
MAIL_FROM="${MAIL_FROM:?}"; readonly MAIL_FROM
MAIL_TO=("${MAIL_TO[@]:?}"); readonly MAIL_TO
GITLAB_ON="${GITLAB_ON:?}"; readonly GITLAB_ON
GITLAB_API="${GITLAB_API:?}"; readonly GITLAB_API
GITLAB_PROJECT="${GITLAB_PROJECT:?}"; readonly GITLAB_PROJECT
GITLAB_TOKEN="${GITLAB_TOKEN:?}"; readonly GITLAB_TOKEN

# -------------------------------------------------------------------------------------------------------------------- #
# -----------------------------------------------------< SCRIPT >----------------------------------------------------- #
# -------------------------------------------------------------------------------------------------------------------- #

function _uuid() {
  dmidecode -s 'system-uuid'
}

function _host() {
  local type; type="${1}"

  case "${type}" in
    'f') hostname -f ;;
    'i') hostname -I ;;
    *) return 1 ;;
  esac
}

function _date() {
  local type; type="${1}"

  case "${type}" in
    'd') date -u '+%d' ;;
    'm') date -u '+%m' ;;
    's') date -u '+%s' ;;
    't') date -u '+%F.%H-%M-%S' ;;
    'Y') date -u '+%Y' ;;
    'z') date '+%FT%T%:z' ;;
    *) return 1 ;;
  esac
}

function _msg() {
  local type; type="${1}"
  local msg; msg="$( _date 'z' ) $( _host 'f' ) ${SRC_NAME}: ${2}"

  case "${type}" in
    'error') echo "${msg}" >&2; exit 1 ;;
    'success') echo "${msg}" ;;
    *) return 1 ;;
  esac
}

function _tree() {
  echo "$( _date 'Y' )/$( _date 'm' )/$( _date 'd' )"
}

function _mail() {
  (( ! "${MAIL_ON}" )) && return 0

  local id; id="#id:$( _host 'f' ):$( _uuid )"
  local type; type="#type:backup:${1}"
  local date; date="#date:$( _date 'z' )"
  local ip; ip="#ip:$( _host 'i' )"
  local subj; subj="[$( _host 'f' )] ${SRC_NAME}: ${2}"
  local body; body="${3}"
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
  local title; title="[$( _host 'f' )] ${SRC_NAME}: ${2}"
  local description; description="${3}"
  local id; id="#id:$( _host 'f' ):$( _uuid )"
  local ip; ip="#ip:$( _host 'i' )"
  local date; date="#date:$( _date 'z' )"
  local type; type="#type:backup:${1}"

  curl "${GITLAB_API}/projects/${GITLAB_PROJECT}/issues" -X 'POST' -kfsLo '/dev/null' \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H 'Content-Type: application/json' \
    -d @- <<EOF
{
  "title": "${title}",
  "description": "${description//\'/\`}\n\n---\n\n- \`${id^^}\`\n- \`${ip^^}\`\n- \`${date^^}\`\n- \`${type^^}\`",
  "labels": "backup,database,${label}"
}
EOF
}

function _mongo() {
  local db; db="${1}"
  local opts; opts=(
    "--host=${DB_HOST:-127.0.0.1}"
    "--port=${DB_PORT:-27017}"
    "--username=${DB_USER:-root}"
    "--password=${DB_PASS}"
    "--authenticationDatabase=${DB_AUTH:-admin}"
    "--oplog"
    "--archive"
    "--db=${db}"
  )

  mongodump "${opts[@]}"
}

function _mysql() {
  local db; db="${1}"
  local cmd; cmd='mariadb-dump'; [[ -x "$( command -v 'mysqldump' )" ]] && cmd='mysqldump'
  local opts; opts=(
    "--host=${DB_HOST:-127.0.0.1}"
    "--port=${DB_PORT:-3306}"
    "--user=${DB_USER:-root}"
    "--password=${DB_PASS}"
    "--databases=${db}"
  )
  (( "${MYSQL_ST:-1}" )) && opts+=('--single-transaction')
  (( "${MYSQL_SLT:-1}" )) && opts+=('--skip-lock-tables')

  "${cmd}" "${opts[@]}"
}

function _pgsql() {
  local db; db="${1}"
  local opts; opts=(
    "--host=${DB_HOST:-127.0.0.1}"
    "--port=${DB_PORT:-5432}"
    "--username=${DB_USER:-postgres}"
    '--no-password'
    "--dbname=${db}"
  )
  (( "${PGSQL_CLN:-1}" )) && opts+=('--clean')
  (( "${PGSQL_IE:-1}" )) && opts+=('--if-exists')
  (( "${PGSQL_NO:-1}" )) && opts+=('--no-owner')
  (( "${PGSQL_NP:-1}" )) && opts+=('--no-privileges')
  (( "${PGSQL_QAI:-1}" )) && opts+=('--quote-all-identifiers')

  case "${PGSQL_FMT:-plain}" in
    'plain') opts+=('--format=plain') ;;
    'custom') opts+=('--format=custom') ;;
    *) _msg 'error' "'PGSQL_FMT' does not exist!" ;;
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
    *) _msg 'error' "'DBMS' does not exist!" ;;
  esac
}

function _gpg() {
  local out; out="${1}.gpg"
  local pass; pass="${2}"

  gpg --batch --passphrase "${pass}" --symmetric --output "${out}" \
    --s2k-cipher-algo "${ENC_GPG_CIPHER:-AES256}" \
    --s2k-digest-algo "${ENC_GPG_DIGEST:-SHA512}" \
    --s2k-count "${ENC_GPG_COUNT:-65536}"
}

function _ssl() {
  local out; out="${1}.ssl"
  local pass; pass="${2}"

  openssl enc "-${ENC_SSL_CIPHER:-aes-256-cfb}" -out "${out}" -pass "pass:${pass}" \
    -salt -md "${ENC_SSL_DIGEST:-sha512}" -iter "${ENC_SSL_COUNT:-65536}" -pbkdf2
}

function _enc() {
  local out; out="${1}"
  local pass; pass="${ENC_PASS}"

  if (( "${ENC_ON}" )); then
    case "${ENC_APP}" in
      'gpg') _gpg "${out}" "${pass}" ;;
      'ssl') _ssl "${out}" "${pass}" ;;
      *) _msg 'error' "'ENC_APP' does not exist!" ;;
    esac
  else
    cat < '/dev/stdin' > "${out}"
  fi
}

function _sum() {
  local in; in="${1}"; (( "${ENC_ON}" )) && in="${1}.${ENC_APP}"
  local out; out="${in}.txt"

  sha256sum "${in}" | sed 's| .*/|  |g' | tee "${out}" > '/dev/null'
}

function fs_check() {
  local file; file='.backup_db'
  local msg; msg=()

  if [[ ! -f "${DB_DST}/${file}" ]]; then
    msg=(
      'error'
      "File '${file}' not found!"
      "File '${file}' not found! Please check the remote storage status!"
    ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg 'error' "${msg[2]}"
  fi; return 0
}

function db_backup() {
  local id; id="$( _date 's' )"

  for i in "${DB_SRC[@]}"; do
    local ts; ts="$( _date 't' )"
    local tree; tree="${DB_DST}/$( _tree )"
    local file; file="${i}.${id}.${ts}.xz"
    local msg; msg=()
    [[ ! -d "${tree}" ]] && mkdir -p "${tree}"; cd "${tree}" || _msg 'error' "Directory '${tree}' not found!"
    if _dump "${i}" | xz | _enc "${file}" && _sum "${file}"; then
      msg=(
        'success'
        "Backup of database '${i}' completed successfully"
        "Backup of database '${i}' completed successfully. File '${tree}/${file}' received."
      ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg 'success' "${msg[2]}"
    else
      msg=(
        'error'
        "Error backing up database '${i}'"
        "Error backing up database '${i}'! File '${tree}/${file}' not received or corrupted!"
      ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg 'error' "${msg[2]}"
    fi
  done
}

function fs_sync() {
  (( ! "${SYNC_ON}" )) && return 0

  local msg; msg=()
  local opts; opts=('--archive' '--quiet')
  (( "${SYNC_DEL:-0}" )) && opts+=('--delete')
  (( "${SYNC_RSF:-0}" )) && opts+=('--remove-source-files')
  (( "${SYNC_PED:-0}" )) && opts+=('--prune-empty-dirs')
  (( "${SYNC_CVS:-0}" )) && opts+=('--cvs-exclude')

  if rsync "${opts[@]}" -e "sshpass -p '${SYNC_PASS}' ssh -p ${SYNC_PORT:-22}" \
    "${DB_DST}/" "${SYNC_USER:-root}@${SYNC_HOST}:${SYNC_DST}/"; then
    msg=(
      'success'
      'Synchronization with remote storage completed successfully'
      'Synchronization with remote storage completed successfully.'
    ); _mail "${msg[@]}"; _msg 'success' "${msg[2]}"
  else
    msg=(
      'error'
      'Error synchronizing with remote storage'
      'Error synchronizing with remote storage!'
    ); _mail "${msg[@]}"; _msg 'error' "${msg[2]}"
  fi
}

function fs_clean() {
  find "${DB_DST}" -type 'f' -mtime "+${FS_DAYS:-30}" -print0 | xargs -0 rm -f --
  find "${DB_DST}" -mindepth 1 -type 'd' -not -name 'lost+found' -empty -delete
}

function main() {
  fs_check && db_backup && fs_sync && fs_clean
}; main "$@"
