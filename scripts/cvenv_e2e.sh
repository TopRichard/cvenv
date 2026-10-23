#!/usr/bin/env bash
# End-to-end tests for the cvenv Lmod module.
#
# Exercises the module the way a user would: module load, python -m venv,
# source activate, pip install, deactivate, reactivate in a "new job", etc.
#
# Usage (from a directory OUTSIDE /tmp, where `module load cvenv` works):
#   bash scripts/cvenv_e2e.sh
#   VERBOSE=1 bash scripts/cvenv_e2e.sh
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

TEST_ROOT=$(mktemp -d "$PWD/cvenv-e2e.XXXXXX") || fatal "cannot create test dir"
TEST_ROOT=$(builtin cd "$TEST_ROOT" && pwd -P) || fatal "cannot resolve test dir"
BASE_SCRATCH="/tmp/cvenv-e2e-${USER:-user}-$$"

ENV_TEST_VARS=(
    PYTHONHASHSEED PYTHONUNBUFFERED CV_USER_E2E CV_USER_E2E_EMPTY
    HF_TOKEN CVENV_E2E_NOT_ALLOWED
)
unset "${ENV_TEST_VARS[@]}" CVENV_RO

SAVED_LD="${LD_LIBRARY_PATH-__unset__}"
SAVED_CRAY="${CRAY_LD_LIBRARY_PATH-__unset__}"
restore_var() { if [ "$2" = "__unset__" ]; then unset "$1"; else export "$1=$2"; fi; }

module -q unload cvenv >/dev/null 2>&1 || true
export CV_ARCHIVE_DIR="$TEST_ROOT"
export CV_JOB_SCRATCH="$BASE_SCRATCH"
module load cvenv >/dev/null 2>&1 || fatal "module load cvenv failed"
declare -F _cv_compress_venv >/dev/null || fatal "cvenv shell functions not defined after module load"
SAVED_ARCHIVE_DIR="${CV_ARCHIVE_DIR-__unset__}"
SAVED_BACKEND_EXT="${CV_BACKEND_EXT-__unset__}"
SAVED_IS_WRITER="${CV_IS_WRITER-__unset__}"

builtin cd "$TEST_ROOT" || fatal "cannot cd to $TEST_ROOT"

mkdir -p "$TEST_ROOT/.wheels"
WHEEL=$("${CV_ORIGINAL_PYTHON3:-python3}" - "$TEST_ROOT/.wheels" <<'PY'
import base64, hashlib, os, sys, zipfile
out = sys.argv[1]
name, ver = "cvenv_e2e_pkg", "0.1"
di = f"{name}-{ver}.dist-info"
files = {
    f"{name}/__init__.py": "VALUE = 42\n\ndef main():\n    print('hello from cvenv_e2e_pkg')\n",
    f"{di}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {ver}\n",
    f"{di}/WHEEL": "Wheel-Version: 1.0\nGenerator: cvenv-e2e\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{di}/entry_points.txt": f"[console_scripts]\ncvenv-e2e-hello = {name}:main\n",
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

archive_of()  { _cv_find_archive "$CV_ARCHIVE_DIR" "$1"; }
archive_has() {
    local a
    a=$(archive_of "$1") || { DETAIL="no archive for $1"; return 1; }
    case "$a" in
        *.tar.zst)
            [ -n "$CV_PZSTD" ] || { DETAIL="CV_PZSTD not set"; return 1; }
            "$CV_PZSTD" -dc -- "$a" ;;
        *.tar.gz)  gzip -dc -- "$a" ;;
    esac 2>/dev/null | tar -tf - 2>/dev/null | grep -qF -- "$2" || { DETAIL="'$2' not in $a"; return 1; }
}

mkenv()       { qq python -m venv "$1"; }
act()         { qq source "$1/bin/activate" && [ -n "${VIRTUAL_ENV:-}" ]; }
deact()       { qq deactivate; }
install_pkg() { qq pip install --no-index --no-deps "$WHEEL"; }
py()          { python -c "$1" 2>/dev/null; }
pkg_value()   { py 'import cvenv_e2e_pkg as m; print(m.VALUE)'; }

reset_state() {
    if declare -F deactivate >/dev/null && { [ -n "${_CV_ACTIVE_DIR:-}" ] || [ -n "${VIRTUAL_ENV:-}" ]; }; then
        export CVENV_RO=1
        qq deactivate
    fi
    unset CVENV_RO "${ENV_TEST_VARS[@]}"
    chmod u+w "$TEST_ROOT" 2>/dev/null
    restore_var CV_ARCHIVE_DIR "$SAVED_ARCHIVE_DIR"
    restore_var CV_BACKEND_EXT "$SAVED_BACKEND_EXT"
    restore_var CV_IS_WRITER "$SAVED_IS_WRITER"
    export CV_JOB_SCRATCH="$BASE_SCRATCH"
    restore_var LD_LIBRARY_PATH "$SAVED_LD"
    restore_var CRAY_LD_LIBRARY_PATH "$SAVED_CRAY"
    builtin cd "$TEST_ROOT"
}

cleanup() {
    reset_state >/dev/null 2>&1
    builtin cd / || true
    command rm -rf -- "$TEST_ROOT" "$BASE_SCRATCH" "${BASE_SCRATCH}-job2"
}
trap cleanup EXIT

PASSED=0 FAILED=0 SKIPPED=0
run() {
    local fn=$1 desc=$2 rc m
    FAILS=() SKIP_REASON=
    builtin cd "$TEST_ROOT"
    "$fn"; rc=$?
    reset_state
    if [ "$rc" -eq 77 ]; then
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
        fn_defined python python3 pip pip3 source cd rm _cv_compress_venv _cv_decompress_venv _cv_relocate_venv
    check "CV_JOB_SCRATCH honours user setting" eq "$CV_JOB_SCRATCH" "$BASE_SCRATCH"
    check "CV_ARCHIVE_DIR honours user setting" eq "$CV_ARCHIVE_DIR" "$TEST_ROOT"
    check "backend extension is .tar.zst or .tar.gz" \
        eval '[ "$CV_BACKEND_EXT" = .tar.zst ] || [ "$CV_BACKEND_EXT" = .tar.gz ]'
}

t_create() {
    must mkenv e1 || return 1
    check "e1 is a symlink"                      [ -L e1 ]
    check "e1 points into job scratch"           eq "$(readlink -f e1)" "$CV_JOB_SCRATCH/e1"
    check "archive written"                      archive_of e1
    check "README written next to archive"       [ -f "$TEST_ROOT/e1.README.md" ]
    check "README shows activate command"        grep -q 'source e1/bin/activate' "$TEST_ROOT/e1.README.md"
}

t_activate_deactivate() {
    must mkenv e2 || return 1
    must act e2 || return 1
    check "VIRTUAL_ENV is the scratch copy"      eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/e2"
    check "python runs from the venv"            eq "$(py 'import sys; print(sys.prefix)')" "$CV_JOB_SCRATCH/e2"
    check "cvenv tracks the active env"          eq "${_CV_ACTIVE_NAME:-}" e2
    must deact || return 1
    check "VIRTUAL_ENV unset after deactivate"   eq "${VIRTUAL_ENV-<unset>}" "<unset>"
    check "scratch copy removed"                 not [ -e "$CV_JOB_SCRATCH/e2" ]
    check "symlink replaced by stub"             eval '[ ! -L e2 ] && is_stub e2'
    check "archive kept"                         archive_of e2
    check "reactivation from stub works"         act e2
    check "reactivated VIRTUAL_ENV correct"      eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/e2"
}

t_pip_persist() {
    must mkenv e3 || return 1
    must act e3 || return 1
    must install_pkg || return 1
    check "archive updated immediately after pip install" archive_has e3 cvenv_e2e_pkg/__init__.py
    must deact || return 1
    must act e3 || return 1
    check "package importable after reactivation" eq "$(pkg_value)" 42
    check "console script works after reactivation" \
        eq "$(cvenv-e2e-hello 2>/dev/null)" "hello from cvenv_e2e_pkg"
}

t_relocate() {
    must mkenv rel || return 1
    must act rel || return 1
    must install_pkg || return 1
    must deact || return 1
    local old="$CV_JOB_SCRATCH/rel"
    export CV_JOB_SCRATCH="${BASE_SCRATCH}-job2"
    local new="$CV_JOB_SCRATCH/rel"
    must act rel || return 1
    check "VIRTUAL_ENV points to new scratch"    eq "${VIRTUAL_ENV:-}" "$new"
    check "sys.prefix is new scratch"            eq "$(py 'import sys; print(sys.prefix)')" "$new"
    check "package importable"                   eq "$(pkg_value)" 42
    check "console script shebang relocated" \
        eq "$("$VIRTUAL_ENV/bin/cvenv-e2e-hello" 2>/dev/null)" "hello from cvenv_e2e_pkg"
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

t_compress_failure() {
    [ "$(id -u)" -ne 0 ] || { SKIP_REASON="cannot test write failure as root"; return 77; }
    must mkenv cf || return 1
    must act cf || return 1
    touch "$VIRTUAL_ENV/marker_cf"
    chmod a-w "$TEST_ROOT"
    qq deactivate; local rc=$?
    chmod u+w "$TEST_ROOT"
    check "deactivate reports failure"           differ "$rc" 0
    check "env still active"                     eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/cf"
    check "scratch copy retained"                [ -e "$CV_JOB_SCRATCH/cf/marker_cf" ]
    must deact || return 1
    must act cf || return 1
    check "change saved once writable again"     [ -e "$VIRTUAL_ENV/marker_cf" ]
}

t_read_only_node() {
    [ "${CV_IS_WRITER:-1}" = "1" ] || { SKIP_REASON="test requires the writer node"; return 77; }
    local old_writer="$CV_IS_WRITER"
    must mkenv roenv || return 1
    must deact || return 1
    export CV_IS_WRITER=0
    must act roenv || return 1
    touch "$VIRTUAL_ENV/marker_read_only"
    must deact || return 1
    check "read-only node removes scratch copy" not [ -e "$CV_JOB_SCRATCH/roenv" ]
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
    check "active scratch env not removed"       [ -x "$CV_JOB_SCRATCH/rg/bin/python" ]
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
    export LD_LIBRARY_PATH=/cvenv-e2e/orig
    export CRAY_LD_LIBRARY_PATH=/cvenv-e2e/cray
    must mkenv ld || return 1
    must act ld || return 1
    check "CRAY_LD_LIBRARY_PATH merged"          has_path "${LD_LIBRARY_PATH:-}" /cvenv-e2e/cray
    check "original LD_LIBRARY_PATH kept"        has_path "${LD_LIBRARY_PATH:-}" /cvenv-e2e/orig
    must deact || return 1
    check "LD_LIBRARY_PATH restored"             eq "${LD_LIBRARY_PATH:-}" /cvenv-e2e/orig
}

t_envvars() {
    must mkenv ev || return 1
    must act ev || return 1
    export PYTHONHASHSEED=12345
    export PYTHONUNBUFFERED=1
    export CV_USER_E2E='a b "q" $HOME `x` \ end'
    export CV_USER_E2E_EMPTY=''
    export HF_TOKEN=secret CVENV_E2E_NOT_ALLOWED=nope
    must deact || return 1
    check "env-var snapshot archived" archive_has ev .cvenv-envvars.sh
    unset "${ENV_TEST_VARS[@]}"
    must act ev || return 1
    check "allow-listed PYTHONHASHSEED restored" eq "${PYTHONHASHSEED-<unset>}" 12345
    check "allow-listed PYTHONUNBUFFERED restored" eq "${PYTHONUNBUFFERED-<unset>}" 1
    check "CV_USER_* with special chars"         eq "${CV_USER_E2E-<unset>}" 'a b "q" $HOME `x` \ end'
    check "CV_USER_* empty value kept as set"    eq "${CV_USER_E2E_EMPTY-<unset>}" ''
    check "HF_TOKEN not persisted"               eq "${HF_TOKEN-<unset>}" '<unset>'
    check "non-allow-listed var not persisted"   eq "${CVENV_E2E_NOT_ALLOWED-<unset>}" '<unset>'
    must deact || return 1
    unset "${ENV_TEST_VARS[@]}"
    export PYTHONUNBUFFERED=0
    must act ev || return 1
    check "shell value wins over saved value"    eq "${PYTHONUNBUFFERED-<unset>}" 0
}

t_uv_venv() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 77; }
    must qq uv venv uvenv --python="$CV_ORIGINAL_PYTHON3" || return 1
    check "uvenv is a symlink into scratch"      eq "$(readlink -f uvenv)" "$CV_JOB_SCRATCH/uvenv"
    check "archive written"                      archive_of uvenv
    must act uvenv || return 1
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    check "archive updated after uv pip install" archive_has uvenv cvenv_e2e_pkg/__init__.py
    must deact || return 1
    must act uvenv || return 1
    check "package importable after reactivation" eq "$(pkg_value)" 42
}

t_uv_dot_venv_auto_activate() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 77; }
    must qq uv venv --python="$CV_ORIGINAL_PYTHON3" || return 1
    must deact || return 1
    check "local .venv stub exists" is_stub .venv
    qq uv pip install --offline --no-deps "$WHEEL"
    check "uv auto-activated local .venv" [ -n "${VIRTUAL_ENV:-}" ]
    check "VIRTUAL_ENV is the local scratch copy" eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/.venv"
    must deact || return 1
}

t_conda() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 77; }
    must qq conda create -n cenv python || return 1
    check "cenv is a symlink into scratch"       eq "$(readlink -f cenv)" "$CV_JOB_SCRATCH/cenv"
    must qq conda activate cenv || return 1
    check "CONDA_PREFIX is the scratch copy"     eq "${CONDA_PREFIX:-}" "$CV_JOB_SCRATCH/cenv"
    must qq conda deactivate || return 1
    check "scratch copy removed"                 not [ -e "$CV_JOB_SCRATCH/cenv" ]
    local old="$CV_JOB_SCRATCH/cenv"
    export CV_JOB_SCRATCH="${BASE_SCRATCH}-job2"
    must qq conda activate cenv || return 1
    check "CONDA_PREFIX points to new scratch"   eq "${CONDA_PREFIX:-}" "$CV_JOB_SCRATCH/cenv"
    check "python runs from new prefix"          eq "$(py 'import sys; print(sys.prefix)')" "$CV_JOB_SCRATCH/cenv"
    check "[known issue] no text file references old prefix" no_text_ref "$old" "$CONDA_PREFIX"
}

t_conda_mutations() {
    [ -n "${CV_CONDA:-}" ] || { SKIP_REASON="conda not found at module load"; return 77; }
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

t_absolute_path() {
    mkdir -p "$TEST_ROOT/abs"
    must mkenv "$TEST_ROOT/abs/absenv" || return 1
    check "symlink created at the absolute path" [ -L "$TEST_ROOT/abs/absenv" ]
    check "no stray directories under \$PWD"     not [ -e "$TEST_ROOT/${TEST_ROOT#/}" ]
    must act "$TEST_ROOT/abs/absenv" || return 1
    check "absolute-path VIRTUAL_ENV is correct" eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/absenv"
    must deact || return 1
    must act "$TEST_ROOT/abs/absenv" || return 1
    check "absolute-path reactivation works" [ -n "${VIRTUAL_ENV:-}" ]
    must deact || return 1
}

t_name_collision() {
    mkdir -p a b
    must mkenv a/.venv || return 1
    qq python -m venv b/.venv
    check "a/.venv and b/.venv are distinct environments" \
        differ "$(readlink -f a/.venv)" "$(readlink -f b/.venv)"
}

t_backend_fallback() {
    [ "$CV_BACKEND_EXT" = ".tar.zst" ] || { SKIP_REASON="backend is not zstd"; return 77; }
    must mkenv bf || return 1
    must act bf || return 1
    must deact || return 1
    CV_BACKEND_EXT=.tar.gz qq source bf/bin/activate
    check "activation finds existing .tar.zst when backend is gzip" [ -n "${VIRTUAL_ENV:-}" ]
}

t_uv_init_relocate() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 77; }
    must qq uv init uvproj --python="$CV_ORIGINAL_PYTHON3" || return 1
    must act uvproj/.venv || return 1
    check "VIRTUAL_ENV is project .venv in scratch" eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/uvproj/.venv"
    must deact || return 1
    export CV_JOB_SCRATCH="${BASE_SCRATCH}-job2"
    must act uvproj/.venv || return 1
    check "VIRTUAL_ENV points to new scratch"    eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/uvproj/.venv"
    check "sys.prefix is new scratch"            eq "$(py 'import sys; print(sys.prefix)')" "$CV_JOB_SCRATCH/uvproj/.venv"
}

t_uv_project_run() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 77; }
    must qq uv init uvrunproj --python="$CV_ORIGINAL_PYTHON3" || return 1
    must act uvrunproj/.venv || return 1
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    must deact || return 1
    check "uv run auto-activates project .venv" \
        qq uv run --no-sync --directory uvrunproj python -c 'import cvenv_e2e_pkg; print(cvenv_e2e_pkg.VALUE)'
}

# --- Additional functionality tests -------------------------------------------
t_cd_subdirectory() {
    must mkenv cdsub || return 1
    must act cdsub || return 1
    mkdir -p src
    cd src
    check "cd into subdirectory keeps env active" [ -n "${VIRTUAL_ENV:-}" ]
    check "scratch copy still present"            [ -x "$CV_JOB_SCRATCH/cdsub/bin/python" ]
    cd ..
    check "still active at project root"          [ -n "${VIRTUAL_ENV:-}" ]
    cd /tmp
    check "scratch copy removed after leaving project" not [ -e "$CV_JOB_SCRATCH/cdsub" ]
    unset VIRTUAL_ENV CONDA_PREFIX
    builtin cd "$TEST_ROOT"
}

t_pushd_popd() {
    must mkenv pd || return 1
    must act pd || return 1
    mkdir -p sub
    qq pushd sub
    check "pushd into subdirectory keeps env active" [ -n "${VIRTUAL_ENV:-}" ]
    qq popd
    check "popd back to project root keeps env active" [ -n "${VIRTUAL_ENV:-}" ]
    cd /tmp
    check "leaving project root archives"         not [ -e "$CV_JOB_SCRATCH/pd" ]
    unset VIRTUAL_ENV CONDA_PREFIX
    builtin cd "$TEST_ROOT"
}

t_uv_auto_activate() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 77; }
    must qq uv venv uvauto --python="$CV_ORIGINAL_PYTHON3" || return 1
    must deact || return 1
    qq uv pip install --offline --no-deps --directory uvauto "$WHEEL"
    check "uv auto-activated the local .venv"     [ -n "${VIRTUAL_ENV:-}" ]
    check "VIRTUAL_ENV is the scratch copy"       eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/uvauto"
    must deact || return 1
}

t_uv_run() {
    [ -n "${CV_UV:-}" ] || { SKIP_REASON="uv not found at module load"; return 77; }
    must qq uv venv uvrun --python="$CV_ORIGINAL_PYTHON3" || return 1
    must act uvrun || return 1
    must qq uv pip install --offline --no-deps "$WHEEL" || return 1
    must deact || return 1
    check "uv run works with auto-activated venv" \
        qq uv run --directory uvrun python -c 'import cvenv_e2e_pkg; print(cvenv_e2e_pkg.VALUE)'
}

t_pip3() {
    must mkenv p3 || return 1
    must act p3 || return 1
    must qq pip3 install --no-index --no-deps "$WHEEL" || return 1
    check "pip3 install saved to archive"         archive_has p3 cvenv_e2e_pkg/__init__.py
    must deact || return 1
    must act p3 || return 1
    check "package importable after pip3"         eq "$(pkg_value)" 42
}

t_unique_name() {
    must mkenv un || return 1
    check "archive name includes hash suffix"     bash -c "ls '$CV_ARCHIVE_DIR'/un-*.tar.* >/dev/null 2>&1"
    check "symlink points to scratch"             eq "$(readlink -f un)" "$CV_JOB_SCRATCH/un"
}

t_source_wrapper() {
    must mkenv sw || return 1
    must deact || return 1
    check "stub activate exists"                  is_stub sw
    qq source sw/bin/activate
    check "source wrapper decompresses and activates" [ -n "${VIRTUAL_ENV:-}" ]
    check "VIRTUAL_ENV is the scratch copy"       eq "${VIRTUAL_ENV:-}" "$CV_JOB_SCRATCH/sw"
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

echo "cvenv e2e: archive dir $TEST_ROOT, scratch $BASE_SCRATCH, backend $CV_BACKEND_EXT"
echo "== Core"
run t_module_load          "module load sets up functions and variables"
run t_create               "python -m venv creates symlink, archive and README"
run t_activate_deactivate  "activate/deactivate cycle and stub"
run t_pip_persist          "pip install is saved and survives reactivation"
run t_relocate             "env relocates to a new job scratch path"
run t_readonly             "CVENV_RO skips saving; default saves"
run t_gzip_backend         "gzip backend creates and reactivates .tar.gz archives"
run t_compress_failure     "compression failure retains active environment"
run t_read_only_node       "read-only node skips persistence"
run t_rm_guard             "rm refuses to delete the active env"
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
run t_uv_run               "uv run with auto-activated venv"
run t_conda                "conda create/activate/relocate"
run t_conda_mutations      "conda install/remove persistence"
run t_absolute_path        "absolute venv path"
run t_name_collision       "same basename in different dirs"
run t_backend_fallback     ".tar.zst archive found with gzip backend"
run t_uv_init_relocate     "uv init project relocates to new scratch"
run t_uv_project_run       "uv run in uv project"

echo
printf 'Single node tests: Passed: %d  Failed: %d  Skipped: %d\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
