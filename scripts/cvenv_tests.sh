#!/usr/bin/env bash
# Tests for the cvenv Lmod module.
#
# Exercises the module the way a user would: module load, python -m venv,
# source activate, pip install, deactivate, reactivate in a "new job", etc.
#
# Usage (from a directory OUTSIDE /tmp, where `module load cvenv` works):
#   bash scripts/cvenv_tests.sh
#   VERBOSE=1 bash scripts/cvenv_tests.sh
#
# Exit code: 0 all passed (skips allowed), 1 any failure, 2 setup error.

[ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "FATAL: bash >= 4 required" >&2; exit 2; }

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }

case "$PWD" in /tmp|/tmp/*) fatal "run from a directory outside /tmp" ;; esac

if ! type module >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh "${LMOD_PKG:-/nonexistent}/init/bash"; do
        [ -f "$f" ] && . "$f" && break
    done
fi
type module >/dev/null 2>&1 || fatal "module command not available"

cvenv_module='cvenv/0.1.0'
TEST_ROOT=$(mktemp -d "$PWD/cvenv-tests.XXXXXX") || fatal "cannot create test dir"
TEST_ROOT=$(builtin cd "$TEST_ROOT" && pwd -P) || fatal "cannot resolve test dir"
BASE_SCRATCH=$(mktemp -d "/tmp/cvenv-tests-${USER:-user}-$$-XXXXXX") || fatal "cannot create scratch dir"
BASE_SCRATCH=$(builtin cd "$BASE_SCRATCH" && pwd -P) || fatal "cannot resolve scratch dir"
rmdir "$BASE_SCRATCH" || fatal "cannot prepare scratch dir"

ENV_TEST_VARS=(
    PYTHONHASHSEED PYTHONUNBUFFERED CV_USER_tests CV_USER_tests_EMPTY
    HF_TOKEN CVENV_tests_NOT_ALLOWED
)
unset "${ENV_TEST_VARS[@]}" CVENV_RO

SAVED_LD="${LD_LIBRARY_PATH-__unset__}"
SAVED_CRAY="${CRAY_LD_LIBRARY_PATH-__unset__}"
restore_var() { if [ "$2" = "__unset__" ]; then unset "$1"; else export "$1=$2"; fi; }

module -q unload cvenv >/dev/null 2>&1 || true
export CV_ARCHIVE_DIR="$TEST_ROOT"
export CV_JOB_SCRATCH="$BASE_SCRATCH"
module load "$cvenv_module" >/dev/null 2>&1 || fatal "module load $cvenv_module failed"
if [ "$CV_JOB_SCRATCH" != "$BASE_SCRATCH" ] || [ "$CV_ARCHIVE_DIR" != "$TEST_ROOT" ]; then
    fatal "loaded $cvenv_module ignored CV_JOB_SCRATCH or CV_ARCHIVE_DIR"
fi
declare -F _cv_compress_venv >/dev/null || fatal "cvenv shell functions not defined after module load"
SAVED_ARCHIVE_DIR="${CV_ARCHIVE_DIR-__unset__}"
SAVED_BACKEND_EXT="${CV_BACKEND_EXT-__unset__}"
SAVED_IS_WRITER="${CV_IS_WRITER-__unset__}"
SAVED_ARCHIVE_NAME="${CVENV_ARCHIVE_NAME-__unset__}"
SAVED_UV="${CV_UV-__unset__}"
SAVED_CONDA="${CV_CONDA-__unset__}"
SAVED_UV_CACHE_DIR="${UV_CACHE_DIR-__unset__}"
SAVED_VIRTUAL_ENV="${VIRTUAL_ENV-__unset__}"
SAVED_CONDA_PREFIX="${CONDA_PREFIX-__unset__}"
SAVED_CONDA_DEFAULT_ENV="${CONDA_DEFAULT_ENV-__unset__}"
SAVED_CONDA_SHLVL="${CONDA_SHLVL-__unset__}"
SAVED_CONDA_PROMPT_MODIFIER="${CONDA_PROMPT_MODIFIER-__unset__}"
SAVED_PATH="${PATH-__unset__}"
SAVED_PS1="${PS1-__unset__}"
SAVED_PKG_CONFIG_PATH="${PKG_CONFIG_PATH-__unset__}"

builtin cd "$TEST_ROOT" || fatal "cannot cd to $TEST_ROOT"

mkdir -p "$TEST_ROOT/.wheels"
WHEEL=$("${CV_ORIGINAL_PYTHON3:-python3}" - "$TEST_ROOT/.wheels" <<'PY'
import base64, hashlib, os, sys, zipfile
out = sys.argv[1]
name, ver = "cvenv_tests_pkg", "0.1"
di = f"{name}-{ver}.dist-info"
files = {
    f"{name}/__init__.py": "VALUE = 42\n\ndef main():\n    print('hello from cvenv_tests_pkg')\n",
    f"{di}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {ver}\n",
    f"{di}/WHEEL": "Wheel-Version: 1.0\nGenerator: cvenv-tests\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{di}/entry_points.txt": f"[console_scripts]\ncvenv-tests-hello = {name}:main\n",
}
def digest(b):
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b"=").decode()
record = [f"{p},{digest(c.encode())},{len(c.encode())}" for p, c in files.items()]
record.append(f"{di}/RECORD,,")
path = os.path.join(out, f"{name}-{ver}-py3-none-any.whl")
with zipfile.ZipFile(path, "w") as z:
    for p, c in files.items():
        z.writestr(p, c)
    z.writestr(f"{di}/RECORD", "\n".join(record) + "\n")
print(path)
PY
) || fatal "could not build test wheel"

qq() { if [ "${VERBOSE:-0}" = "1" ]; then "$@"; else "$@" >/dev/null 2>&1; fi; }

FAILS=()
DETAIL=
SKIP_REASON=
check() {
    local desc=$1; shift
    DETAIL=
    if ! "$@"; then FAILS+=("$desc${DETAIL:+ -- $DETAIL}"); fi
}
must() {
    if ! "$@"; then FAILS+=("step failed: $*"); return 1; fi
}
eq()        { [ "$1" = "$2" ] || { DETAIL="expected '$2', got '$1'"; return 1; }; }
differ()    { [ "$1" != "$2" ] || { DETAIL="both are '$1'"; return 1; }; }
not()       { ! "$@"; }
has_path()  { case ":$1:" in *":$2:"*) return 0 ;; esac; DETAIL="'$2' not in '$1'"; return 1; }
fn_defined(){ declare -F "$@" >/dev/null; }
is_stub()   { grep -q CVENV_STUB "$1/bin/activate" 2>/dev/null; }
no_text_ref() {
    local hits
    hits=$(grep -rIlF -- "$1" "$2" 2>/dev/null | head -3)
    [ -z "$hits" ] || { DETAIL="still referenced in: ${hits//$'\n'/, }"; return 1; }
}

archive_name_of() {
    local target
    if target=$(readlink -f "$1" 2>/dev/null) && [ -f "$target/.cvenv-archive-name" ]; then
        cat "$target/.cvenv-archive-name"
    elif [ -f "$1/bin/activate" ]; then
        sed -n 's/^# CVENV_ARCHIVE_NAME=//p' "$1/bin/activate" | head -1
    else
        printf '%s\n' "$1"
    fi
}
archive_of()  { _cv_find_archive "$CV_ARCHIVE_DIR" "$(archive_name_of "$1")"; }
readme_of()   { printf '%s/%s.README.md\n' "$CV_ARCHIVE_DIR" "$(archive_name_of "$1")"; }
scratch_of()  { readlink -f "$1"; }
under_scratch() { case "$1" in "$CV_JOB_SCRATCH"/*) return 0 ;; *) return 1 ;; esac; }
identity_of() {
    local target
    target=$(scratch_of "$1") || return 1
    sed -n 's/^identity=//p' "$target/.cvenv-manifest" | head -1
}
archive_has() {
    local archive member listing
    local -a list_cmd=()
    archive=$(archive_of "$1") || { DETAIL="no archive for $1"; return 1; }
    member=$2
    case "$archive" in
        *.tar.zst)
            [ -n "$CV_PZSTD" ] || { DETAIL="CV_PZSTD not set"; return 1; }
            list_cmd=("$CV_PZSTD" -dc -- "$archive")
            ;;
        *.tar.gz)
            list_cmd=(gzip -dc -- "$archive")
            ;;
        *)
            DETAIL="unsupported archive extension: $archive"
            return 1
            ;;
    esac
    if ! listing=$(set -o pipefail; "${list_cmd[@]}" | tar -tf -) 2>/dev/null; then
        DETAIL="cannot list archive: $archive"
        return 1
    fi
    printf '%s\n' "$listing" | grep -qF -- "$member" || { DETAIL="'$member' not in $archive"; return 1; }
}

repack_archive() {
    local archive="$1" payload="$2" component="$3" tmp="${1}.tmp.$$"
    case "$archive" in
        *.tar.zst)
            [ -n "$CV_PZSTD" ] || return 1
            if (set -o pipefail; tar -cf - -C "$payload" -- "$component" | \
                "$CV_PZSTD" -p "${CV_COMPRESS_CPUS:-1}" -3 -c > "$tmp") 2>/dev/null; then
                :
            else
                command rm -f -- "$tmp"
                return 1
            fi
            ;;
        *.tar.gz)
            tar -czf "$tmp" -C "$payload" -- "$component" || {
                command rm -f -- "$tmp"
                return 1
            }
            ;;
        *)
            return 2
            ;;
    esac
    command mv -f -- "$tmp" "$archive" || {
        command rm -f -- "$tmp"
        return 1
    }
}

mkenv()       { qq python -m venv "$1"; }
act()         { qq source "$1/bin/activate" && [ -n "${VIRTUAL_ENV:-}" ]; }
deact()       { qq deactivate; }
install_pkg() { qq pip install --no-index --no-deps "$WHEEL"; }
py()          { python -c "$1" 2>/dev/null; }
pkg_value()   { py 'import cvenv_tests_pkg as m; print(m.VALUE)'; }

reset_state() {
    local rc=0
    if declare -F deactivate >/dev/null && { [ -n "${_CV_ACTIVE_DIR:-}" ] || [ -n "${VIRTUAL_ENV:-}" ]; }; then
        export CVENV_RO=1
        qq deactivate || rc=1
    fi
    if [ -n "${_CV_ACTIVE_DIR:-}" ]; then
        if [ -L "${_CV_ACTIVE_LINK:-}" ]; then
            command rm -f -- "$_CV_ACTIVE_LINK" || rc=1
        fi
        command rm -rf -- "$_CV_ACTIVE_DIR" || rc=1
    fi
    if [ -n "${_CV_EXPANDED_DIR:-}" ]; then
        if [ -L "${_CV_EXPANDED_LINK:-}" ]; then
            command rm -f -- "$_CV_EXPANDED_LINK" || rc=1
        fi
        command rm -rf -- "$_CV_EXPANDED_DIR" || rc=1
    fi
    unset _CV_ACTIVE_NAME _CV_ACTIVE_ARCHIVE_NAME _CV_ACTIVE_DIR _CV_ACTIVE_ARCHIVE_DIR
    unset _CV_ACTIVE_LINK _CV_ACTIVE_VENV_SUBDIR _CV_ACTIVE_IDENTITY _CV_ACTIVE_SCRATCH_KEY
    unset _CV_ACTIVE_SOURCE_KIND _CV_ACTIVE_SOURCE_PATH _CV_EXPANDED_LINK _CV_EXPANDED_DIR
    unset _CV_EXPANDED_ARCHIVE_DIR _CV_EXPANDED_VENV_SUBDIR _CV_AUTO_ACTIVATED _CV_RO_AUTO
    unset _CV_PS1_BACKUP _CV_LD_LIBRARY_PATH_BACKUP _CV_OLD_LD_LIBRARY_PATH
    unset _CV_PKG_CONFIG_PATH_BACKUP _CV_OLD_PKG_CONFIG_PATH _CV_VENV_PKGCFG
    unset CVENV_RO "${ENV_TEST_VARS[@]}"
    chmod u+w "$TEST_ROOT" 2>/dev/null || rc=1
    restore_var CV_ARCHIVE_DIR "$SAVED_ARCHIVE_DIR" || rc=1
    restore_var CV_BACKEND_EXT "$SAVED_BACKEND_EXT" || rc=1
    restore_var CV_IS_WRITER "$SAVED_IS_WRITER" || rc=1
    restore_var CVENV_ARCHIVE_NAME "$SAVED_ARCHIVE_NAME" || rc=1
    restore_var CV_UV "$SAVED_UV" || rc=1
    restore_var CV_CONDA "$SAVED_CONDA" || rc=1
    restore_var UV_CACHE_DIR "$SAVED_UV_CACHE_DIR" || rc=1
    restore_var VIRTUAL_ENV "$SAVED_VIRTUAL_ENV" || rc=1
    restore_var CONDA_PREFIX "$SAVED_CONDA_PREFIX" || rc=1
    restore_var CONDA_DEFAULT_ENV "$SAVED_CONDA_DEFAULT_ENV" || rc=1
    restore_var CONDA_SHLVL "$SAVED_CONDA_SHLVL" || rc=1
    restore_var CONDA_PROMPT_MODIFIER "$SAVED_CONDA_PROMPT_MODIFIER" || rc=1
    export CV_JOB_SCRATCH="$BASE_SCRATCH"
    restore_var LD_LIBRARY_PATH "$SAVED_LD" || rc=1
    restore_var CRAY_LD_LIBRARY_PATH "$SAVED_CRAY" || rc=1
    restore_var PATH "$SAVED_PATH" || rc=1
    restore_var PS1 "$SAVED_PS1" || rc=1
    restore_var PKG_CONFIG_PATH "$SAVED_PKG_CONFIG_PATH" || rc=1
    builtin cd "$TEST_ROOT" || rc=1
    command rm -rf -- "$BASE_SCRATCH" "${BASE_SCRATCH}-job2" || rc=1
    return "$rc"
}

cleanup() {
    reset_state >/dev/null 2>&1
    builtin cd / || true
    command rm -rf -- "$TEST_ROOT" "$BASE_SCRATCH" "${BASE_SCRATCH}-job2"
}
trap cleanup EXIT

PASSED=0 FAILED=0 SKIPPED=0
run() {
    local fn=$1 desc=$2 rc reset_rc m
    FAILS=() SKIP_REASON=
    builtin cd "$TEST_ROOT"
    "$fn"; rc=$?
    reset_state
    reset_rc=$?
    if [ "$reset_rc" -ne 0 ]; then
        FAILS+=("test reset failed")
        rc=1
    fi
    if [ "$rc" -eq 78 ]; then
        SKIPPED=$((SKIPPED + 1)); printf '  SKIP  %s (%s)\n' "$desc" "$SKIP_REASON"
    elif [ "$rc" -ne 0 ] || [ "${#FAILS[@]}" -gt 0 ]; then
        FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$desc"
        for m in "${FAILS[@]}"; do printf '          - %s\n' "$m"; done
    else
        PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$desc"
    fi
}

t_module_load() {
    check "wrapper and helper functions defined" \
        fn_defined python python3 pip pip3 source cd rm cvenv_export \
                _cv_compress_venv _cv_decompress_venv _cv_relocate_venv
    check "CV_JOB_SCRATCH honours user setting" eq "$CV_JOB_SCRATCH" "$BASE_SCRATCH"
    check "CV_ARCHIVE_DIR honours user setting" eq "$CV_ARCHIVE_DIR" "$TEST_ROOT"
    check "backend extension is .tar.zst or .tar.gz" \
        eval '[ "$CV_BACKEND_EXT" = .tar.zst ] || [ "$CV_BACKEND_EXT" = .tar.gz ]'
}

t_default_scratch_cleanup() {
    local old_job_scratch="$CV_JOB_SCRATCH"
    local old_local_scratch="${LOCALSCRATCH-__unset__}"
    module -q unload "$cvenv_module" >/dev/null 2>&1 || return 1
    unset CV_JOB_SCRATCH LOCALSCRATCH
    module -q load "$cvenv_module" >/dev/null 2>&1 || return 1
    local scratch="$CV_JOB_SCRATCH"
    check "default scratch is under /tmp" bash -c "[[ '$scratch' == /tmp/cvenv-* ]]"
    module -q unload "$cvenv_module" >/dev/null 2>&1 || return 1
    check "default scratch removed on unload" not [ -e "$scratch" ]
    check "internal scratch marker unset" eq "${_CV_DEFAULT_SCRATCH-<unset>}" "<unset>"
    if [ "$old_local_scratch" = "__unset__" ]; then
        unset LOCALSCRATCH
    else
        export LOCALSCRATCH="$old_local_scratch"
    fi
    export CV_JOB_SCRATCH="$old_job_scratch"
    module -q load "$cvenv_module" >/dev/null 2>&1 || return 1
}

t_create() {
    must mkenv e1 || return 1
    check "e1 is a symlink"                      [ -L e1 ]
    check "e1 points into job scratch"           under_scratch "$(scratch_of e1)"
    check "archive written"                      archive_of e1
    check "README written next to archive"       [ -f "$(readme_of e1)" ]
    check "README shows activate command"        grep -q 'source .*e1/bin/activate' "$(readme_of e1)"
    check "README records cvenv module version"  grep -q -- '- cvenv module: ' "$(readme_of e1)"
    check "README requires cd"                   grep -q '^cd ' "$(readme_of e1)"
    check "README uses environment directory"    grep -q "cd .*${TEST_ROOT}$" "$(readme_of e1)"
    check "README avoids absolute activation"    not grep -q "source .*${TEST_ROOT}/e1/bin/activate" "$(readme_of e1)"
}

t_activate_deactivate() {
    must mkenv e2 || return 1
    must act e2 || return 1
    local scratch=$(scratch_of e2)
    check "VIRTUAL_ENV is the scratch copy"      eq "${VIRTUAL_ENV:-}" "$scratch"
    check "python runs from the venv"            eq "$(py 'import sys; print(sys.prefix)')" "$scratch"
    check "cvenv tracks the active env"          eq "${_CV_ACTIVE_NAME:-}" e2
    must deact || return 1
    check "VIRTUAL_ENV unset after deactivate"   eq "${VIRTUAL_ENV-<unset>}" "<unset>"
    check "scratch copy removed"                 not [ -e "$scratch" ]
    check "symlink replaced by stub"             eval '[ ! -L e2 ] && is_stub e2'
    check "archive kept"                         archive_of e2
    check "reactivation from stub works"         act e2
    check "reactivated VIRTUAL_ENV correct"      eq "${VIRTUAL_ENV:-}" "$scratch"
}

t_pip_persist() {
    must mkenv e3 || return 1
    must act e3 || return 1
    must install_pkg || return 1
    check "archive updated immediately after pip install" archive_has e3 cvenv_tests_pkg/__init__.py
    must deact || return 1
    must act e3 || return 1
    check "package importable after reactivation" eq "$(pkg_value)" 42
    check "console script works after reactivation" \
        eq "$(cvenv-tests-hello 2>/dev/null)" "hello from cvenv_tests_pkg"
}

t_pip_global_options() {
    must mkenv pipopts || return 1
    must act pipopts || return 1
    must qq pip --no-cache-dir install --no-index --no-deps "$WHEEL" || return 1
    check "archive updated after pip global option" \
        archive_has pipopts cvenv_tests_pkg/__init__.py
    must qq python -m pip --disable-pip-version-check install --no-index --no-deps "$WHEEL" || return 1
    check "archive updated after python -m pip global option" \
        archive_has pipopts cvenv_tests_pkg/__init__.py
    must deact || return 1
}

t_relocate() {
    must mkenv rel || return 1
    must act rel || return 1
    must install_pkg || return 1
    local old=$(scratch_of rel)
    must deact || return 1
    export CV_JOB_SCRATCH="${BASE_SCRATCH}-job2"
    must act rel || return 1
    local new=$(scratch_of rel)
    check "VIRTUAL_ENV points to new scratch"    eq "${VIRTUAL_ENV:-}" "$new"
    check "sys.prefix is new scratch"            eq "$(py 'import sys; print(sys.prefix)')" "$new"
    check "package importable"                   eq "$(pkg_value)" 42
    check "console script shebang relocated" \
        eq "$("$VIRTUAL_ENV/bin/cvenv-tests-hello" 2>/dev/null)" "hello from cvenv_tests_pkg"
    check "pip shebang relocated"                qq "$VIRTUAL_ENV/bin/pip" --version
    check "no text file references old prefix"  no_text_ref "$old" "$VIRTUAL_ENV"
}

t_readonly() {
    must mkenv ro || return 1
    must act ro || return 1
    touch "$VIRTUAL_ENV/marker_ro"
    export CVENV_RO=1
    must deact || return 1
    must act ro || return 1
    check "CVENV_RO=1: change not saved"         not [ -e "$VIRTUAL_ENV/marker_ro" ]
    unset CVENV_RO
    touch "$VIRTUAL_ENV/marker_rw"
    must deact || return 1
    must act ro || return 1
    check "default: change saved on deactivate"  [ -e "$VIRTUAL_ENV/marker_rw" ]
}

t_gzip_backend() {
    local old_backend="${CV_BACKEND_EXT:-.tar.gz}" archive
    export CV_BACKEND_EXT=.tar.gz
    if must mkenv gz; then
        archive=$(archive_of gz)
        check "gzip backend creates .tar.gz archive" \
            eval '[ -n "${archive:-}" ] && [[ "$archive" == *.tar.gz ]]'
        if must act gz; then
            must deact
        fi
    fi
    export CV_BACKEND_EXT="$old_backend"
}

t_archive_extension_preservation() {
    [ -n "${CV_PZSTD:-}" ] || { SKIP_REASON="pzstd not found at module load"; return 78; }
    local old_backend="${CV_BACKEND_EXT:-.tar.gz}" archive
    export CV_BACKEND_EXT=.tar.gz
    must mkenv extkeep || return 1
    archive=$(archive_of extkeep)
    check "initial archive is gzip" eval '[ -n "${archive:-}" ] && [[ "$archive" == *.tar.gz ]]'
    must act extkeep || return 1
    touch "$VIRTUAL_ENV/first-save"
    must deact || return 1

    export CV_BACKEND_EXT=.tar.zst
    must act extkeep || return 1
    touch "$VIRTUAL_ENV/second-save"
    must deact || return 1
    archive=$(archive_of extkeep)
    check "existing archive keeps its gzip extension" eval '[ -n "${archive:-}" ] && [[ "$archive" == *.tar.gz ]]'
    check "gzip archive contains latest save" archive_has extkeep second-save
    export CV_BACKEND_EXT="$old_backend"
}

t_compress_failure() {
    [ "$(id -u)" -ne 0 ] || { SKIP_REASON="cannot test write failure as root"; return 78; }
    must mkenv cf || return 1
    must act cf || return 1
    touch "$VIRTUAL_ENV/marker_cf"
    chmod a-w "$TEST_ROOT"
    qq deactivate; local rc=$?
    chmod u+w "$TEST_ROOT"
    check "deactivate reports failure"           differ "$rc" 0
    check "env still active"                     eq "${VIRTUAL_ENV:-}" "$(scratch_of cf)"
    check "scratch copy retained"                [ -e "$VIRTUAL_ENV/marker_cf" ]
    must deact || return 1
    must act cf || return 1
    check "change saved once writable again"     [ -e "$VIRTUAL_ENV/marker_cf" ]
}

t_read_only_node() {
    [ "${CV_IS_WRITER:-1}" = "1" ] || { SKIP_REASON="test requires the writer node"; return 78; }
    local old_writer="$CV_IS_WRITER"
    must mkenv roenv || return 1
    must deact || return 1
    export CV_IS_WRITER=0
    must act roenv || return 1
    local scratch=$(scratch_of roenv)
    touch "$VIRTUAL_ENV/marker_read_only"
    must deact || return 1
    check "read-only node removes scratch copy" not [ -e "$scratch" ]
    check "read-only node does not write stub" not [ -e roenv/bin/activate ]
    must act roenv || return 1
    check "read-only node changes are not persisted" not [ -e "$VIRTUAL_ENV/marker_read_only" ]
    export CV_IS_WRITER="$old_writer"
    must deact || return 1
}

t_rm_guard() {
    must mkenv rg || return 1
    must act rg || return 1
    qq rm -rf rg
    qq rm -rf "$VIRTUAL_ENV"
    check "symlink to active env not removed"    [ -L rg ]
    check "active scratch env not removed"       [ -x "$VIRTUAL_ENV/bin/python" ]
}

t_rm_created_unactivated() {
    must mkenv rm-created || return 1
    local scratch="$_CV_ACTIVE_DIR"
    qq rm -rf rm-created*
    check "unactivated env removed"              not [ -e rm-created ]
    check "unactivated env scratch removed"      not [ -d "$scratch" ]
    check "unactivated env state cleared"        not [ -n "${_CV_ACTIVE_DIR:-}" ]
}

t_rm_non_venv() {
    touch plain-file
    qq rm plain-file
    check "non-venv file removed" not [ -e plain-file ]
}

t_archive_dir_unset_fallback() {
    unset CV_ARCHIVE_DIR
    mkdir -p archive-fallback
    builtin cd archive-fallback
    must mkenv afb || return 1
    check "archive defaults to current directory" _cv_find_archive "$PWD" afb
    must act afb || return 1
    must deact || return 1
    builtin cd "$TEST_ROOT"
}

t_ld_path() {
    export LD_LIBRARY_PATH=/cvenv-tests/orig
    export CRAY_LD_LIBRARY_PATH=/cvenv-tests/cray
    must mkenv ld || return 1
    must act ld || return 1
    check "CRAY_LD_LIBRARY_PATH merged"          has_path "${LD_LIBRARY_PATH:-}" /cvenv-tests/cray
    check "original LD_LIBRARY_PATH kept"        has_path "${LD_LIBRARY_PATH:-}" /cvenv-tests/orig
    must deact || return 1
    check "LD_LIBRARY_PATH restored"             eq "${LD_LIBRARY_PATH:-}" /cvenv-tests/orig
}

t_envvars() {
    must mkenv ev || return 1
    must act ev || return 1
    export PYTHONHASHSEED=12345
    export PYTHONUNBUFFERED=1
    export CV_USER_tests='a b "q" $HOME `x` \ end'
    export CV_USER_tests_EMPTY=''
    export HF_TOKEN=secret CVENV_tests_NOT_ALLOWED=nope
    must deact || return 1
    check "env-var snapshot archived" archive_has ev .cvenv-envvars.sh
    unset "${ENV_TEST_VARS[@]}"
    must act ev || return 1
    check "allow-listed PYTHONHASHSEED restored" eq "${PYTHONHASHSEED-<unset>}" 12345
    check "allow-listed PYTHONUNBUFFERED restored" eq "${PYTHONUNBUFFERED-<unset>}" 1
    check "CV_USER_* with special chars"         eq "${CV_USER_tests-<unset>}" 'a b "q" $HOME `x` \ end'
    check "CV_USER_* empty value kept as set"    eq "${CV_USER_tests_EMPTY-<unset>}" ''
    check "HF_TOKEN not persisted"               eq "${HF_TOKEN-<unset>}" '<unset>'
    check "non-allow-listed var not persisted"   eq "${CVENV_tests_NOT_ALLOWED-<unset>}" '<unset>'
    must deact || return 1
    unset "${ENV_TEST_VARS[@]}"
    export PYTHONUNBUFFERED=0
    must act ev || return 1
    check "shell value wins over saved value"    eq "${PYTHONUNBUFFERED-<unset>}" 0
}

t_uv_venv() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv venv uvenv --python="$CV_ORIGINAL_PYTHON3" || return 1
    check "uvenv is a symlink into scratch"      under_scratch "$(scratch_of uvenv)"
    check "archive written"                      archive_of uvenv
    must act uvenv || return 1
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    check "archive updated after uv pip install" archive_has uvenv cvenv_tests_pkg/__init__.py
    must deact || return 1
    must act uvenv || return 1
    check "package importable after reactivation" eq "$(pkg_value)" 42
}

t_uv_dot_venv_auto_activate() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv venv --python="$CV_ORIGINAL_PYTHON3" || return 1
    local scratch=$(scratch_of .venv)
    must deact || return 1
    check "local .venv stub exists" is_stub .venv
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    check "uv auto-deactivated local .venv" eq "${VIRTUAL_ENV-<unset>}" "<unset>"
    check "local .venv scratch removed" not [ -e "$scratch" ]
    check "local .venv stub restored" is_stub .venv
}

t_conda() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 78; }
    must qq conda create -n cenv python || return 1
    check "cenv is a symlink into scratch"       under_scratch "$(scratch_of cenv)"
    check "conda README requires cd"             grep -q '^cd ' "$(readme_of cenv)"
    check "conda README uses relative activation" grep -q 'conda activate cenv$' "$(readme_of cenv)"
    check "conda README avoids archive export"   not grep -q '^export CV_ARCHIVE_DIR=' "$(readme_of cenv)"
    check "conda README avoids absolute activation" not grep -q "conda activate .*${TEST_ROOT}/cenv" "$(readme_of cenv)"
    local old=$(scratch_of cenv)
    must qq conda activate cenv || return 1
    check "CONDA_PREFIX is the scratch copy"     under_scratch "${CONDA_PREFIX:-}"
    must qq conda deactivate || return 1
    check "scratch copy removed"                 not [ -e "$old" ]
    export CV_JOB_SCRATCH="${BASE_SCRATCH}-job2"
    must qq conda activate cenv || return 1
    check "CONDA_PREFIX points to new scratch"   under_scratch "${CONDA_PREFIX:-}"
    check "python runs from new prefix"          under_scratch "$(py 'import sys; print(sys.prefix)')"
    check "[known issue] no text file references old prefix" no_text_ref "$old" "$CONDA_PREFIX"
}

t_conda_mutations() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 78; }
    must qq conda create -n cmut python || return 1
    must qq conda activate cmut || return 1
    touch "$CONDA_PREFIX/marker_conda_install"
    must qq conda install --yes --offline --no-deps python || return 1
    check "conda install archives changes" archive_has cmut marker_conda_install
    must qq conda deactivate || return 1
    must qq conda activate cmut || return 1
    check "conda install change persists" [ -e "$CONDA_PREFIX/marker_conda_install" ]
    must qq conda remove --yes python || return 1
    must qq conda deactivate || return 1
    must qq conda activate cmut || return 1
    check "conda remove persists" not [ -e "$CONDA_PREFIX/bin/python" ]
}

t_conda_unactivated_unload_guard() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 78; }
    must qq conda create -n cunload python || return 1
    local scratch=$(scratch_of cunload)
    check "unactivated conda env is tracked" [ -n "${_CV_ACTIVE_DIR:-}" ]
    check "unactivated conda scratch exists" [ -d "$scratch" ]
    local unload_rc=0
    ( module -q unload "$cvenv_module" >/dev/null 2>&1 ) || unload_rc=$?
    check "module unload follows Lmod policy" eq "$unload_rc" 0
    check "parent cvenv state is isolated" fn_defined _cv_compress_venv conda
    must deact || return 1
    check "unactivated conda scratch removed" not [ -e "$scratch" ]
    check "unactivated conda state cleared" not [ -n "${_CV_ACTIVE_DIR:-}" ]
    check "conda activation stub created" is_stub cunload
}

t_absolute_path() {
    mkdir -p "$TEST_ROOT/abs"
    must mkenv "$TEST_ROOT/abs/absenv" || return 1
    check "symlink created at the absolute path" [ -L "$TEST_ROOT/abs/absenv" ]
    check "no stray directories under \$PWD"     not [ -e "$TEST_ROOT/${TEST_ROOT#/}" ]
    must act "$TEST_ROOT/abs/absenv" || return 1
    check "absolute-path VIRTUAL_ENV is correct" under_scratch "${VIRTUAL_ENV:-}"
    must deact || return 1
    must act "$TEST_ROOT/abs/absenv" || return 1
    check "absolute-path reactivation works" [ -n "${VIRTUAL_ENV:-}" ]
    must deact || return 1
}

t_name_collision() {
    mkdir -p a b
    must mkenv a/.venv || return 1
    local a_scratch=$(scratch_of a/.venv)
    must deact || return 1
    must mkenv b/.venv || return 1
    local b_scratch=$(scratch_of b/.venv)
    must deact || return 1
    check "a/.venv and b/.venv are distinct environments" differ "$a_scratch" "$b_scratch"
}

t_collision_python() {
    mkdir -p collision/a collision/b
    must mkenv collision/a/same || return 1
    local a_scratch=$(scratch_of collision/a/same)
    local a_archive=$(archive_name_of collision/a/same)
    local a_identity=$(identity_of collision/a/same)
    must deact || return 1
    must mkenv collision/b/same || return 1
    local b_scratch=$(scratch_of collision/b/same)
    local b_archive=$(archive_name_of collision/b/same)
    local b_identity=$(identity_of collision/b/same)
    must deact || return 1

    check "python scratch paths are distinct"       differ "$a_scratch" "$b_scratch"
    check "python archive names are distinct"       differ "$a_archive" "$b_archive"
    check "python identities are distinct"          differ "$a_identity" "$b_identity"
    check "python refuses duplicate identity"       not mkenv collision/a/same

    must act collision/a/same || return 1
    check "python reactivates first environment"    eq "${VIRTUAL_ENV:-}" "$a_scratch"
    must deact || return 1
    must act collision/b/same || return 1
    check "python reactivates second environment"   eq "${VIRTUAL_ENV:-}" "$b_scratch"
    must deact || return 1
}

t_collision_uv() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    mkdir -p uv-collision/a uv-collision/b
    must qq uv venv "$TEST_ROOT/uv-collision/a/.venv" --python="$CV_ORIGINAL_PYTHON3" || return 1
    local a_scratch=$(scratch_of uv-collision/a/.venv)
    local a_archive=$(archive_name_of uv-collision/a/.venv)
    local a_identity=$(identity_of uv-collision/a/.venv)
    must deact || return 1
    must qq uv venv "$TEST_ROOT/uv-collision/b/.venv" --python="$CV_ORIGINAL_PYTHON3" || return 1
    local b_scratch=$(scratch_of uv-collision/b/.venv)
    local b_archive=$(archive_name_of uv-collision/b/.venv)
    local b_identity=$(identity_of uv-collision/b/.venv)
    must deact || return 1

    check "uv scratch paths are distinct"           differ "$a_scratch" "$b_scratch"
    check "uv archive names are distinct"           differ "$a_archive" "$b_archive"
    check "uv identities are distinct"              differ "$a_identity" "$b_identity"
    check "uv refuses duplicate identity"           not qq uv venv "$TEST_ROOT/uv-collision/a/.venv"

    must act uv-collision/a/.venv || return 1
    check "uv reactivates first environment"        eq "${VIRTUAL_ENV:-}" "$a_scratch"
    must deact || return 1
    must act uv-collision/b/.venv || return 1
    check "uv reactivates second environment"       eq "${VIRTUAL_ENV:-}" "$b_scratch"
    must deact || return 1
}

t_collision_conda() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 78; }
    mkdir -p conda-collision/a conda-collision/b
    must qq conda create -p "$TEST_ROOT/conda-collision/a/env" python || return 1
    must qq conda activate "$TEST_ROOT/conda-collision/a/env" || return 1
    local a_scratch=$(scratch_of conda-collision/a/env)
    local a_archive=$(archive_name_of conda-collision/a/env)
    local a_identity=$(identity_of conda-collision/a/env)
    must qq conda deactivate || return 1
    must qq conda create -p "$TEST_ROOT/conda-collision/b/env" python || return 1
    must qq conda activate "$TEST_ROOT/conda-collision/b/env" || return 1
    local b_scratch=$(scratch_of conda-collision/b/env)
    local b_archive=$(archive_name_of conda-collision/b/env)
    local b_identity=$(identity_of conda-collision/b/env)
    must qq conda deactivate || return 1

    check "conda scratch paths are distinct"        differ "$a_scratch" "$b_scratch"
    check "conda archive names are distinct"        differ "$a_archive" "$b_archive"
    check "conda identities are distinct"           differ "$a_identity" "$b_identity"
    check "conda refuses duplicate prefix"          not qq conda create -p "$TEST_ROOT/conda-collision/a/env" python

    printf 'dependencies: []\n' > conda-collision/a/environment.yml
    printf 'dependencies: []\n' > conda-collision/b/environment.yml
    must qq conda env create -f conda-collision/a/environment.yml || return 1
    builtin cd conda-collision/a
    must qq conda activate environment || return 1
    local file_a_scratch=$(scratch_of environment)
    must qq conda deactivate || return 1
    builtin cd "$TEST_ROOT"
    must qq conda env create -f conda-collision/b/environment.yml || return 1
    builtin cd conda-collision/b
    must qq conda activate environment || return 1
    local file_b_scratch=$(scratch_of environment)
    must qq conda deactivate || return 1
    builtin cd "$TEST_ROOT"
    check "conda env-file scratch paths are distinct" differ "$file_a_scratch" "$file_b_scratch"

    must qq conda create -n conda-duplicate python || return 1
    must qq conda activate conda-duplicate || return 1
    must qq conda deactivate || return 1
    check "conda refuses duplicate name"            not qq conda create -n conda-duplicate python
}

t_collision_concurrent() {
    mkdir -p concurrent
    qq python -m venv concurrent/env &
    local pid1=$!
    qq python -m venv concurrent/env &
    local pid2=$!
    local rc1 rc2
    wait "$pid1"; rc1=$?
    wait "$pid2"; rc2=$?
    check "exactly one concurrent creator succeeds"  eq "$(( (rc1 == 0) + (rc2 == 0) ))" 1
    must archive_of concurrent/env || return 1
    [ -L concurrent/env ] || { FAILS+=("concurrent winner scratch missing"); return 1; }
    local winner_scratch=$(scratch_of concurrent/env)
    must act concurrent/env || return 1
    must deact || return 1
    check "concurrent winner scratch removed"       not [ -e "$winner_scratch" ]
}

t_legacy_archive() {
    must mkenv legacy || return 1
    must deact || return 1
    local archive=$(archive_of legacy)
    local payload="$TEST_ROOT/.legacy-payload"
    mkdir -p "$payload/legacy"
    _cv_extract_archive_strip "$archive" "$payload/legacy" || return 1
    command rm -f "$payload/legacy/.cvenv-manifest"
    printf '%s\n' legacy > "$payload/legacy/.cvenv-archive-name"
    tar -czf "$CV_ARCHIVE_DIR/legacy.tar.gz" -C "$payload" legacy
    command rm -f "$archive" "$(readme_of legacy)"
    mkdir -p legacy/bin
    printf '# CVENV_STUB\n# CVENV_ARCHIVE_NAME=legacy\n' > legacy/bin/activate

    must act legacy || return 1
    check "legacy archive gains a manifest"          [ -f "$VIRTUAL_ENV/.cvenv-manifest" ]
    must deact || return 1
    check "legacy archive remains readable"          archive_has legacy .cvenv-manifest
    check "legacy creation is refused after migration" not mkenv legacy
}

t_invalid_manifest() {
    must mkenv invalid-manifest || return 1
    must deact || return 1
    local archive=$(archive_of invalid-manifest)
    local payload="$TEST_ROOT/.invalid-manifest-payload"
    mkdir -p "$payload/invalid-manifest"
    _cv_extract_archive_strip "$archive" "$payload/invalid-manifest" || return 1
    printf 'format=2\nsource_kind=path\n' > "$payload/invalid-manifest/.cvenv-manifest"
    repack_archive "$archive" "$payload" invalid-manifest || return 1

    check "invalid manifest activation is refused" not act invalid-manifest
    check "invalid manifest creation is refused" not mkenv invalid-manifest
}

t_manual_modification_without_activation() {
    must mkenv badenv || return 1
    must deact || return 1
    local archive payload
    archive=$(archive_of badenv)
    payload="$TEST_ROOT/.badenv-payload"
    mkdir -p "$payload/badenv"
    _cv_extract_archive_strip "$archive" "$payload/badenv" || return 1
    printf 'export FOO=x; touch pwned\n' > "$payload/badenv/.cvenv-envvars.sh"
    repack_archive "$archive" "$payload" badenv || return 1

    check "manual snapshot modification is refused" not act badenv
    check "manual snapshot modification does not execute" not [ -e "$TEST_ROOT/pwned" ]
}

t_export_read_only() {
    must mkenv export-ro || return 1
    must deact || return 1
    export CV_IS_WRITER=0
    check "read-only node cannot export" not qq cvenv_export export-ro export-ro-out
    export CV_IS_WRITER=1
    check "read-only export creates no archive" not [ -e "$TEST_ROOT/export-ro-out" ]
}

t_portable_export() {
    must mkenv portable-source || return 1
    must deact || return 1
    must qq cvenv_export portable-source portable-export || return 1

    local archive archive_base recipient="$TEST_ROOT/portable-recipient"
    local exported_manifest
    archive=$(find "$TEST_ROOT/portable-export" -maxdepth 1 -name 'portable-source-*.tar.*' -print -quit)
    [ -n "$archive" ] || { FAILS+=("portable export archive missing"); return 1; }
    exported_manifest=$(_cv_read_archive_manifest "$archive") || {
        FAILS+=("portable export manifest is invalid")
        return 1
    }
    archive_base=$(basename "$archive")
    archive_base="${archive_base%.tar.zst}"
    archive_base="${archive_base%.tar.gz}"
    mkdir -p "$recipient"
    cp "$archive" "$recipient/"

    export CV_ARCHIVE_DIR="$recipient"
    must builtin cd "$recipient" || return 1
    must act portable-source || return 1
    check "portable manifest format is 3"       eq "$(sed -n 's/^format=//p' "$VIRTUAL_ENV/.cvenv-manifest")" 3
    check "portable manifest kind is portable"  eq "$(sed -n 's/^source_kind=//p' "$VIRTUAL_ENV/.cvenv-manifest")" portable
    check "portable source path is omitted"    not _cv_manifest_field "$exported_manifest" source_path
    must deact || return 1
    must builtin cd "$TEST_ROOT" || return 1
    export CV_ARCHIVE_DIR="$TEST_ROOT"

    must qq cvenv_export "$TEST_ROOT/portable-source" "$TEST_ROOT/portable-export" || return 1
    local second_archive
    second_archive=$(find "$TEST_ROOT/portable-export" -maxdepth 1 -name 'portable-source-*.tar.*' ! -name "$(basename "$archive")" -print -quit)
    [ -n "$second_archive" ] || { FAILS+=("second portable export archive missing"); return 1; }
    cp "$second_archive" "$recipient/"
    command rm -rf "$recipient/portable-source"

    export CV_ARCHIVE_DIR="$recipient"
    must builtin cd "$recipient" || return 1
    check "ambiguous portable activation is refused" not act portable-source
    export CVENV_ARCHIVE_NAME="$archive_base"
    must act portable-source || return 1
    check "exact portable selector activates"    under_scratch "$(readlink -f "$VIRTUAL_ENV")"
    must deact || return 1
    unset CVENV_ARCHIVE_NAME
    must builtin cd "$TEST_ROOT" || return 1
}

t_portable_export_uv() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    mkdir -p portable-uv-source
    must qq uv venv "$TEST_ROOT/portable-uv-source/.venv" --python="$CV_ORIGINAL_PYTHON3" || return 1
    must deact || return 1
    must qq cvenv_export "$TEST_ROOT/portable-uv-source/.venv" "$TEST_ROOT/portable-uv-export" || return 1

    local archive recipient="$TEST_ROOT/portable-uv-recipient"
    archive=$(find "$TEST_ROOT/portable-uv-export" -maxdepth 1 -name '.venv-*.tar.*' -print -quit)
    [ -n "$archive" ] || { FAILS+=("portable uv export archive missing"); return 1; }
    mkdir -p "$recipient"
    cp "$archive" "$recipient/"
    export CV_ARCHIVE_DIR="$recipient"
    must builtin cd "$recipient" || return 1
    must act .venv || return 1
    check "portable uv manifest is portable" eq "$(sed -n 's/^source_kind=//p' "$VIRTUAL_ENV/.cvenv-manifest")" portable
    must deact || return 1
    must builtin cd "$TEST_ROOT" || return 1
}

t_portable_export_conda() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 78; }
    must qq conda create -n portable-conda python || return 1
    must qq conda activate portable-conda || return 1
    must qq conda deactivate || return 1
    must qq cvenv_export portable-conda "$TEST_ROOT/portable-conda-export" || return 1

    local archive recipient="$TEST_ROOT/portable-conda-recipient"
    archive=$(find "$TEST_ROOT/portable-conda-export" -maxdepth 1 -name 'portable-conda-*.tar.*' -print -quit)
    [ -n "$archive" ] || { FAILS+=("portable conda export archive missing"); return 1; }
    mkdir -p "$recipient"
    cp "$archive" "$recipient/"
    export CV_ARCHIVE_DIR="$recipient"
    must builtin cd "$recipient" || return 1
    must qq conda activate portable-conda || return 1
    check "portable conda manifest is portable" eq "$(sed -n 's/^source_kind=//p' "$CONDA_PREFIX/.cvenv-manifest")" portable
    must qq conda deactivate || return 1
    must builtin cd "$TEST_ROOT" || return 1
}

t_backend_fallback() {
    [ "$CV_BACKEND_EXT" = ".tar.zst" ] || { SKIP_REASON="backend is not zstd"; return 78; }
    must mkenv bf || return 1
    must act bf || return 1
    must deact || return 1
    CV_BACKEND_EXT=.tar.gz qq source bf/bin/activate
    check "activation finds existing .tar.zst when backend is gzip" [ -n "${VIRTUAL_ENV:-}" ]
}

t_uv_init_relocate() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv init uvproj --python="$CV_ORIGINAL_PYTHON3" || return 1
    must act uvproj/.venv || return 1
    check "VIRTUAL_ENV is project .venv in scratch" under_scratch "${VIRTUAL_ENV:-}"
    must deact || return 1
    export CV_JOB_SCRATCH="${BASE_SCRATCH}-job2"
    must act uvproj/.venv || return 1
    check "VIRTUAL_ENV points to new scratch"    under_scratch "${VIRTUAL_ENV:-}"
    check "sys.prefix is new scratch"            under_scratch "$(py 'import sys; print(sys.prefix)')"
}

t_uv_project_run() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv init uvrunproj --python="$CV_ORIGINAL_PYTHON3" || return 1
    must act uvrunproj/.venv || return 1
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    local scratch=$(scratch_of uvrunproj/.venv)
    must deact || return 1
    must qq uv run --no-sync --directory uvrunproj python -c 'import cvenv_tests_pkg; print(cvenv_tests_pkg.VALUE)' || return 1
    check "uv project run auto-deactivates" eq "${VIRTUAL_ENV-<unset>}" "<unset>"
    check "uv project scratch removed" not [ -e "$scratch" ]
    check "uv project stub restored" is_stub uvrunproj/.venv
}

t_uv_option_parsing() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv venv --python "$CV_ORIGINAL_PYTHON3" uvparse || return 1
    check "separate --python value is not the venv path" [ -L uvparse ]
    must deact || return 1
}

t_trailing_slash() {
    must mkenv trail/ || return 1
    check "trailing slash creates the requested name" [ -L trail ]
    must act trail || return 1
    must deact || return 1
}

t_python_dash_m_pip() {
    must mkenv pmp || return 1
    must act pmp || return 1
    must qq python -m pip install --no-index --no-deps "$WHEEL" || return 1
    check "python -m pip install saves to archive" archive_has pmp cvenv_tests_pkg/__init__.py
    must deact || return 1
    must act pmp || return 1
    check "package importable after python -m pip" eq "$(pkg_value)" 42
}

t_ordinary_python_venv_passthrough() {
    mkdir -p "$CV_JOB_SCRATCH"
    must "${CV_ORIGINAL_PYTHON3:-python3}" -m venv "$CV_JOB_SCRATCH/ordinary" || return 1
    ln -sfn "$CV_JOB_SCRATCH/ordinary" ordinary
    export LD_LIBRARY_PATH=ordinary-ld
    export PKG_CONFIG_PATH=ordinary-pc
    must qq source ordinary/bin/activate || return 1
    check "ordinary scratch venv activates directly" eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/ordinary"
    check "ordinary venv keeps LD_LIBRARY_PATH" eq "${LD_LIBRARY_PATH:-}" ordinary-ld
    check "ordinary venv keeps PKG_CONFIG_PATH" eq "${PKG_CONFIG_PATH:-}" ordinary-pc
    must deact || return 1
}

t_conda_failed_activation() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 78; }
    must qq conda create -n conda-fail python || return 1
    must qq conda activate conda-fail || return 1
    local scratch fake_conda old_conda rc
    scratch=$(scratch_of conda-fail)
    must qq conda deactivate || return 1
    check "conda activation archives cleanly" not [ -e "$scratch" ]
    fake_conda=$(mktemp "$TEST_ROOT/conda-fail.XXXXXX")
    printf '#!/bin/sh\nexit 42\n' > "$fake_conda"
    chmod +x "$fake_conda"
    old_conda="$CV_CONDA"
    export CV_CONDA="$fake_conda"
    qq conda activate conda-fail
    rc=$?
    export CV_CONDA="$old_conda"
    command rm -f "$fake_conda"
    check "failed conda activation returns nonzero" [ "$rc" -ne 0 ]
    check "failed conda activation retains scratch" [ -d "$scratch" ]
    must qq conda activate conda-fail || return 1
    must qq conda deactivate || return 1
    check "recovered conda activation removes scratch" not [ -e "$scratch" ]
}

# --- Additional functionality tests -------------------------------------------
t_cd_subdirectory() {
    must mkenv cdsub || return 1
    must act cdsub || return 1
    local scratch=$(scratch_of cdsub)
    mkdir -p src
    cd src
    check "cd into subdirectory keeps env active" [ -n "${VIRTUAL_ENV:-}" ]
    check "scratch copy still present"            [ -x "$VIRTUAL_ENV/bin/python" ]
    cd ..
    check "still active at project root"          [ -n "${VIRTUAL_ENV:-}" ]
    cd /tmp
    check "scratch copy removed after leaving project" not [ -e "$scratch" ]
    unset VIRTUAL_ENV CONDA_PREFIX
    builtin cd "$TEST_ROOT"
}

t_pushd_popd() {
    must mkenv pd || return 1
    must act pd || return 1
    local scratch=$(scratch_of pd)
    mkdir -p sub
    qq pushd sub
    check "pushd into subdirectory keeps env active" [ -n "${VIRTUAL_ENV:-}" ]
    qq popd
    check "popd back to project root keeps env active" [ -n "${VIRTUAL_ENV:-}" ]
    cd /tmp
    check "leaving project root archives"         not [ -e "$scratch" ]
    unset VIRTUAL_ENV CONDA_PREFIX
    builtin cd "$TEST_ROOT"
}

t_uv_auto_activate() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv venv uvauto --python="$CV_ORIGINAL_PYTHON3" || return 1
    local scratch=$(scratch_of uvauto)
    must deact || return 1
    must qq uv pip install --offline --no-deps --directory uvauto "$WHEEL" || return 1
    check "uv auto-deactivated named venv" eq "${VIRTUAL_ENV-<unset>}" "<unset>"
    check "named venv scratch removed" not [ -e "$scratch" ]
    check "named venv stub restored" is_stub uvauto
}

t_uv_run() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 78; }
    must qq uv venv uvrun --python="$CV_ORIGINAL_PYTHON3" || return 1
    must act uvrun || return 1
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    local scratch=$(scratch_of uvrun)
    must qq uv run --no-sync python -c 'import cvenv_tests_pkg; print(cvenv_tests_pkg.VALUE)' || return 1
    check "uv run keeps the active venv" eq "${VIRTUAL_ENV:-}" "$scratch"
    must deact || return 1
    check "uv run scratch removed after deactivate" not [ -e "$scratch" ]
    check "uv run stub restored" is_stub uvrun
}

t_pip3() {
    must mkenv p3 || return 1
    must act p3 || return 1
    must qq pip3 install --no-index --no-deps "$WHEEL" || return 1
    check "pip3 install saved to archive"         archive_has p3 cvenv_tests_pkg/__init__.py
    must deact || return 1
    must act p3 || return 1
    check "package importable after pip3"         eq "$(pkg_value)" 42
}

t_unique_name() {
    must mkenv un || return 1
    check "archive name includes hash suffix"     bash -c "[[ '$(archive_name_of un)' == un-* ]]"
    check "symlink points to scratch"             under_scratch "$(scratch_of un)"
}

t_source_wrapper() {
    must mkenv sw || return 1
    must deact || return 1
    check "stub activate exists"                  is_stub sw
    qq source sw/bin/activate
    check "source wrapper decompresses and activates" [ -n "${VIRTUAL_ENV:-}" ]
    check "VIRTUAL_ENV is the scratch copy"       under_scratch "${VIRTUAL_ENV:-}"
    must deact || return 1
}

t_scratch_cleanup() {
    must mkenv sc || return 1
    must act sc || return 1
    must deact || return 1
    check "scratch dir removed after last deactivate" not [ -d "$CV_JOB_SCRATCH" ]
}

t_archive_dir_explicit() {
    must mkenv af || return 1
    check "archive found in CV_ARCHIVE_DIR"       archive_of af
    must act af || return 1
    must deact || return 1
}

t_static_hardening() {
    local case_dir python action arg f_count
    local -a args expected_prefix

    case_dir=$(mktemp -d "$TEST_ROOT/static-hardening.XXXXXX") || return 1
    python="${CV_ORIGINAL_PYTHON3:-python3}"
    check "dashed basename is preserved"           eq "$(_cv_base_name --odd-name)" --odd-name

    action=$(_cv_uv_pip_action pip --python 3.11 install) || action=""
    check "uv parser recognises value before install" eq "$action" install
    mkdir -p "$case_dir/uv-cache"
    cat > "$case_dir/mock-uv" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" > "$(dirname "$0")/uv.args"
exit 0
MOCK
    chmod +x "$case_dir/mock-uv"
    CV_UV="$case_dir/mock-uv" UV_CACHE_DIR="$case_dir/uv-cache" \
        check "option-first uv mutation is rejected" not uv pip --python 3.11 install package
    CV_UV="$case_dir/mock-uv" UV_CACHE_DIR="$case_dir/uv-cache" \
        qq uv pip --python 3.11 list
    check "option-first uv read-only action runs" grep -qx -- list "$case_dir/uv.args"

    mkdir -p "$case_dir/conda-scratch" "$case_dir/conda-archive"
    printf 'name: explicit-file\n' > "$case_dir/other.yml"
    cat > "$case_dir/mock-conda" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" > "$(dirname "$0")/conda.args"
exit 1
MOCK
    chmod +x "$case_dir/mock-conda"
    (
        builtin cd "$case_dir"
        export CV_CONDA="$case_dir/mock-conda"
        export CV_JOB_SCRATCH="$case_dir/conda-scratch"
        export CV_ARCHIVE_DIR="$case_dir/conda-archive"
        _cv_conda_env_create --yes -f other.yml >/dev/null 2>&1 || true
    )
    mapfile -t args < "$case_dir/conda.args"
    expected_prefix=(env create -f other.yml --prefix)
    for arg in "${!expected_prefix[@]}"; do
        check "conda argument $arg is preserved" eq "${args[arg]}" "${expected_prefix[arg]}"
    done
    f_count=0
    for arg in "${args[@]}"; do
        [ "$arg" = "-f" ] && f_count=$((f_count + 1))
    done
    check "conda has one complete --file option" eq "$f_count" 1
    check "conda --yes is preserved" grep -qx -- --yes "$case_dir/conda.args"

    "$python" - "$case_dir" <<'PY'
import io
import pathlib
import sys
import tarfile

base = pathlib.Path(sys.argv[1])

def add_dir(archive, name):
    item = tarfile.TarInfo(name)
    item.type = tarfile.DIRTYPE
    item.mode = 0o755
    archive.addfile(item)

def add_file(archive, name, data=b"content\n"):
    archive.addfile(tarfile.TarInfo(name), io.BytesIO(data))

def add_symlink(archive, name, target):
    item = tarfile.TarInfo(name)
    item.type = tarfile.SYMTYPE
    item.linkname = target
    archive.addfile(item)

def add_hardlink(archive, name, target):
    item = tarfile.TarInfo(name)
    item.type = tarfile.LNKTYPE
    item.linkname = target
    archive.addfile(item)

with tarfile.open(base / "safe.tar.gz", "w:gz") as archive:
    add_dir(archive, "root/")
    add_file(archive, "root/file")
    add_file(archive, "root/.cvenv-manifest", b"format=x\n")
    add_dir(archive, "root/nested/")
    add_file(archive, "root/nested/.cvenv-manifest", b"format=wrong\n")
    add_symlink(archive, "root/absolute-python", "/usr/bin/python")
    add_symlink(archive, "root/inside", "file")
    add_hardlink(archive, "root/hard", "root/file")

with tarfile.open(base / "traversal.tar.gz", "w:gz") as archive:
    add_dir(archive, "root/")
    add_file(archive, "root/../bad")

with tarfile.open(base / "write-through.tar.gz", "w:gz") as archive:
    add_dir(archive, "root/")
    add_symlink(archive, "root/dir", "/tmp")
    add_file(archive, "root/dir/payload")

with tarfile.open(base / "multiple-roots.tar.gz", "w:gz") as archive:
    add_dir(archive, "root-one/")
    add_file(archive, "root-one/file")
    add_dir(archive, "root-two/")
    add_file(archive, "root-two/file")

with tarfile.open(base / "duplicate.tar.gz", "w:gz") as archive:
    add_dir(archive, "root/")
    add_file(archive, "root/file", b"one")
    add_file(archive, "root/file", b"two")
PY

    CV_JOB_SCRATCH="$case_dir/missing-scratch"
    check "top-level archive manifest is selected" \
        eq "$(_cv_archive_member "$case_dir/safe.tar.gz")" root/.cvenv-manifest
    check "safe archive validates without scratch parent" \
        _cv_validate_archive_members "$case_dir/safe.tar.gz"
    mkdir -p "$case_dir/destination"
    check "safe archive extracts" \
        _cv_extract_archive_strip "$case_dir/safe.tar.gz" "$case_dir/destination"
    check "normal absolute venv symlink is preserved" \
        eq "$(readlink "$case_dir/destination/absolute-python")" /usr/bin/python
    check "tar traversal is rejected" \
        not _cv_validate_archive_members "$case_dir/traversal.tar.gz"
    check "tar symlink write-through is rejected" \
        not _cv_validate_archive_members "$case_dir/write-through.tar.gz"
    check "tar multiple roots are rejected" \
        not _cv_validate_archive_members "$case_dir/multiple-roots.tar.gz"
    check "tar duplicate paths are rejected" \
        not _cv_validate_archive_members "$case_dir/duplicate.tar.gz"
}

echo "cvenv tests: archive dir $TEST_ROOT, scratch $BASE_SCRATCH, backend $CV_BACKEND_EXT"
echo "=== Starting tests ==="
run t_module_load          "module load sets up functions and variables"
run t_default_scratch_cleanup "default scratch is cleaned on module unload"
run t_create               "python -m venv creates symlink, archive and README"
run t_activate_deactivate  "activate/deactivate cycle and stub"
run t_pip_persist          "pip install is saved and survives reactivation"
run t_pip_global_options   "option-prefixed pip mutations are saved"
run t_relocate             "env relocates to a new job scratch path"
run t_readonly             "CVENV_RO skips saving; default saves"
run t_gzip_backend         "gzip backend creates and reactivates .tar.gz archives"
run t_archive_extension_preservation "existing archive extension is preserved"
run t_compress_failure     "compression failure retains active environment"
run t_read_only_node       "read-only node skips persistence"
run t_rm_guard             "rm refuses to delete the active env"
run t_rm_created_unactivated "rm deletes a created but unactivated env"
run t_ld_path              "LD_LIBRARY_PATH merged and restored"
run t_envvars              "env-var snapshot saved and restored"
run t_cd_subdirectory      "cd into subdirectory keeps env active"
run t_pushd_popd           "pushd/popd keep env active within project"
run t_rm_non_venv          "rm works on non-venv files"
run t_pip3                 "pip3 install persists like pip"
run t_unique_name          "archive name includes hash suffix"
run t_source_wrapper       "source wrapper decompresses stub and activates"
run t_scratch_cleanup      "scratch dir removed after last deactivate"
run t_archive_dir_explicit "archive found in CV_ARCHIVE_DIR"
run t_archive_dir_unset_fallback "archive defaults to current directory"
run t_uv_venv              "uv venv + uv pip install"
run t_uv_auto_activate     "uv auto-activates named venv by --directory"
run t_uv_dot_venv_auto_activate "uv auto-activates local .venv"
run t_uv_run               "uv run uses active venv"
run t_conda                "conda create/activate/relocate"
run t_conda_mutations      "conda install/remove persistence"
run t_conda_unactivated_unload_guard "conda unactivated unload warning"
run t_absolute_path        "absolute venv path"
run t_name_collision       "same basename in different dirs"
run t_collision_python     "python same-basename collision safety"
run t_collision_uv         "uv same-basename collision safety"
run t_collision_conda      "conda prefix, env-file, and name collision safety"
run t_collision_concurrent "concurrent creation has one winner"
run t_legacy_archive       "legacy no-checksum archive migration"
run t_invalid_manifest     "invalid manifest is refused"
run t_manual_modification_without_activation "manual snapshot modification is refused"
run t_export_read_only     "read-only node cannot export"
run t_portable_export      "portable export and archive-only activation"
run t_portable_export_uv   "portable uv export and activation"
run t_portable_export_conda "portable conda export and activation"
run t_backend_fallback     ".tar.zst archive found with gzip backend"
run t_uv_init_relocate     "uv init project relocates to new scratch"
run t_uv_project_run       "uv run in uv project"
run t_uv_option_parsing    "uv separate option values parse correctly"
run t_trailing_slash       "trailing slash uses requested venv name"
run t_python_dash_m_pip    "python -m pip install persists"
run t_ordinary_python_venv_passthrough "ordinary scratch python venv sources directly"
run t_conda_failed_activation "failed conda activation retains scratch"

echo
printf 'Single node tests: Passed: %d  Failed: %d  Skipped: %d\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
