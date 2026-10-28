# cvenv: Compressed Virtual Environments (Python + conda)

`cvenv` is an [Lmod](https://lmod.readthedocs.io) module that transparently
wraps Python virtual environments and conda environments so the **expanded
environment lives in job-local scratch** (typically `/tmp`, or another
node-local path selected with `CV_JOB_SCRATCH` such as `$LOCALSCRATCH`) while
only a **single compressed tar archive** is kept on the parallel filesystem.

On HPC systems with shared parallel filesystems (Lustre, GPFS, BeeGFS, …) a
Python or conda environment contains thousands of small files. Creating,
reading, or activating an environment directly on such a filesystem generates a
storm of metadata operations that saturates the metadata servers and degrades
performance for every user. `cvenv` avoids this by keeping the expanded
environment on node-local scratch (e.g. `/tmp`, `$LOCALSCRATCH`) and storing
only one compressed archive (`.tar.zst` or `.tar.gz`) on the parallel
filesystem.

## Features

- **Node-local expansion**: the environment is decompressed into node-local
  scratch (`/tmp` by default, or a path selected with `CV_JOB_SCRATCH` or
  `$LOCALSCRATCH`) on every node.
- **Single compressed archive**: one `.tar.zst` (or `.tar.gz` if `pzstd` is
  unavailable) file is created with the environment, updated after successful
  mutating commands, and updated at `deactivate` time.
- **Parallel zstd compression**: derives a thread count from
  `SLURM_CPUS_ON_NODE`, `OMP_NUM_THREADS`, or `nproc` (defaulting to 1);
  uses compression level `-3` when available and falls back to `gzip`
  otherwise.
- **Slurm integration**: selects the node-local scratch path at module load:
  `CV_JOB_SCRATCH` first, then `$LOCALSCRATCH`, then a private
  `/tmp/cvenv-*` directory. The selected value is exported as
  `CV_JOB_SCRATCH`; changing `LOCALSCRATCH` afterward has no effect.
- **Multi-node support**: each node decompresses its own independent copy;
  only the head node (`SLURM_NODEID 0`) recompresses the shared archive.
  At activation, cvenv attempts to propagate the environment to all nodes via
  `srun`; when propagation succeeds, plain `srun <cmd>` works on every node.
- **uv support**: when `uv` is found on `PATH`, `uv venv`, `uv init <path>`,
  and `uv run` are supported automatically. Auto-activated `uv run` saves once and
  then deactivates; changing directory away from the venv directory
  auto-deactivates and archives it.
- **conda / miniconda support**: when `conda` is found on `PATH`, `conda
  create`, `conda env create`, and `conda activate` are supported
  automatically. Environments are expanded into node-local scratch and stored
  as a single compressed archive on the parallel filesystem. `conda install`,
  `conda remove`, `conda uninstall`, `conda update`, `conda upgrade`, and
  `conda env update` recompress the archive; `conda`
  deactivate` archives and cleans up the scratch copy.

## Requirements

- [Lmod](https://lmod.readthedocs.io) with Lua module support
- Bash (the shell wrappers are Bash-specific)
- Python (`python` or `python3`) on `PATH`
- `sha256sum` or `shasum` on `PATH`
- EasyBuild is only needed when using the provided easyconfig
  to install the module
- Optional: `pzstd` (parallel zstd) for faster `.tar.zst` archives; falls
  back to `gzip` (`.tar.gz`) if unavailable
- Optional: [uv](https://github.com/astral-sh/uv) for `uv venv`, `uv init <path>`, and `uv run` support
- Optional: [conda](https://docs.conda.io/projects/miniconda) / miniconda for
  `conda create` / `conda activate` support
- Optional: `patchelf` and `readelf` (binutils) for NCCL `rpath`/`runpath`
  patching

### Optional runtime modules

`cvenv` has no hard Lmod module dependencies, but it uses the Python
interpreter found on `PATH`. The modules below are only needed for workloads
that require their runtime libraries. Load them **before** `cvenv` when they
are needed. The versions are **samples only**; use the versions available on
your system:

```bash
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load NCCL/2.30.4-GCCcore-14.3.0-CUDA-13.0.0  # For GPU jobs
module load patchelf/0.18.0-GCCcore-14.3.0  # If NCCL is loaded
```

- **CUDA-only**: the documented GPU workflow is built exclusively on NVIDIA
  CUDA. Other GPU backends (ROCm, oneAPI, …) are **not supported**.
- OpenMPI and NCCL are workload dependencies, not `cvenv` dependencies.
- `patchelf` and `readelf` are optional and are used only to patch NCCL
  `rpath`/`runpath` when an NCCL library is visible through
  `LD_LIBRARY_PATH`.

## Installation

The module is distributed as an [EasyBuild](https://easybuild.io) easyconfig
(`cvenv-0.1.0.eb`). EasyBuild is not required to use `cvenv`; it is simply one
installation method. If EasyBuild is available, build and install with `eb`:

```bash
eb cvenv-0.1.0.eb
```

This generates an Lmod module file with the Lua implementation embedded. Use
`module use` to add its location to your module search path (if needed), then
load the module:

```bash
module load cvenv/0.1.0
```

For a manual install, extract the Lua module file from the easyconfig's
`modluafooter` and place it directly into your module tree. EasyBuild is not
needed after the module file is installed:

```bash
mkdir -p /path/to/modulefiles/cvenv
awk '/^modluafooter = r"""$/{inside=1;next} /^"""$/{if(inside){inside=0}} inside' \
  cvenv-0.1.0.eb > /path/to/modulefiles/cvenv/0.1.0.lua
module use /path/to/modulefiles
module load cvenv/0.1.0
```

## Quick start

### Python venv

```bash
module load cvenv
python -m venv myenv
source myenv/bin/activate
pip install pytest==9.1.1 numpy==2.5.3
deactivate
```

### uv

```bash
module load cvenv
uv venv myenv
source myenv/bin/activate
uv pip install pytest==9.1.1 numpy==2.5.3
deactivate
```

### conda

```bash
module load cvenv
conda create -n myenv python=3.13
conda activate myenv
conda install numpy pytest
conda deactivate
```

```bash
module load cvenv
conda env create -f environment.yml
conda activate myenv
conda deactivate
```

An existing archive can be reactivated with the same command used to create it:

```bash
source myenv/bin/activate      # Python venv / uv
conda activate myenv           # conda
```

### Portable export

Use `cvenv_export` when you want to give a compressed environment to another
user or move it to a different directory:

```bash
module load cvenv
python -m venv myenv
source myenv/bin/activate
pip install numpy
deactivate
cvenv_export myenv /path/to/export
```

The recipient only needs the generated archive:

```bash
mkdir ~/myenvs
chmod a+r /path/to/export/myenv-<hash>.tar.zst
cp /path/to/export/myenv-<hash>.tar.zst ~/myenvs/
cd ~/myenvs
module load cvenv
unset CV_ARCHIVE_DIR              # or set it to ~/myenvs
source myenv/bin/activate
```

For a portable conda archive, use `conda activate myenv` instead of `source`.
If several portable archives have the same display name, select one exactly:

```bash
export CVENV_ARCHIVE_NAME='myenv-<hash>'
source myenv/bin/activate
```

Each `cvenv_export` creates a new portable identity. Copying the exported file
preserves that identity, but recipients still get separate scratch expansions
and save changes to their own copy of the archive.

## Environment variables

`CV_JOB_SCRATCH`, `CV_ARCHIVE_DIR`, `CV_JOB_CACHE`, `CV_COMPRESS_CPUS`,
`PIP_CACHE_DIR`, and `UV_CACHE_DIR` are restored to their prior values when
the module is unloaded.

| Variable | Description |
|---|---|
| `CV_ARCHIVE_DIR` | Archive directory. If unset before module load, the current directory at creation/activation time is used. `/tmp` and `CV_JOB_SCRATCH` paths are rejected. |
| `CV_JOB_SCRATCH` | Expansion directory. Uses `CV_JOB_SCRATCH`, then `$LOCALSCRATCH`, then a private `/tmp` directory. Each node decompresses into its own configured node-local scratch path. |
| `CV_JOB_CACHE` | Absolute pip/uv cache directory. When set, it overrides `PIP_CACHE_DIR` and `UV_CACHE_DIR`, including changes made after module load. Defaults to `$LOCALSCRATCH`, then `$SCRATCH`; when neither is defined, pip uses its default and uv uses `${CV_JOB_SCRATCH}/uv-cache`. |
| `CV_COMPRESS_CPUS` | Positive integer compression thread count. Set it before module load; otherwise it is derived from `SLURM_CPUS_ON_NODE`, `OMP_NUM_THREADS`, or `nproc`, defaulting to 1. |
| `CVENV_RO` | Set to `1` to skip recompression on deactivation. Set to `0` to preserve normal recompression, including after `uv run`. Successful mutating commands (`pip install/uninstall`, `pip3 install/uninstall`, `python -m pip install/uninstall`, `uv pip install/uninstall`, `uv add/remove/sync/run`, `conda install/remove/uninstall/update/upgrade`, `conda env update`) recompress on writer nodes regardless. |
| `CVENV_ARCHIVE_NAME` | Exact archive basename for portable activation when multiple portable archives share a display name. The `.tar.zst` or `.tar.gz` suffix is optional. |
| `CV_DEBUG` | Set to `1` to enable additional diagnostic messages. |

### Env-var persistence

When the environment is compressed, cvenv snapshots the built-in allow-listed
variables (`PYTHONHASHSEED` and `PYTHONUNBUFFERED`) into
`.cvenv-envvars.sh` inside the archive. On the next activation those variables
are restored automatically; variables already set in the shell take
precedence. Secrets such as `HF_TOKEN` are excluded. To persist your own
variables, prefix them with `CV_USER_` (e.g.
`export CV_USER_MY_CONFIG=/path/to/config`).

### Archive naming

Archives are named `<basename>-<hash>.tar.zst` (or `.tar.gz`). The hash is a
SHA-256-derived identity for the canonical python/uv path or the conda name,
prefix, or environment-file path. Scratch directories use a second
deterministic identity, so equal basenames in different directories remain
separate.

Each archive contains `.cvenv-manifest` with the source identity. cvenv checks
the exact archive name and validates this manifest before reuse, reserves
scratch atomically, and reports an explicit error if two environments resolve
to the same identity or if a generated name collides with another identity.
Creating an environment that already exists is refused; activate it instead.
Existing ordinary files, directories, and unrelated symlinks are never replaced;
cvenv only uses an absent path, a marked stub, a symlink to its expected
job-scratch target, or a stale symlink within the current job-scratch root.

Older archives without a manifest remain usable through their stub or legacy
name. The first successful save adds a manifest while retaining the original
archive filename. A new creation that would collide with an unmanifested
legacy archive is refused rather than overwriting it.

## How it works

1. `module load cvenv` installs shell function wrappers for `python`,
   `python3`, `pip`, `pip3`, `source`, `uv`, `conda`, `rm`, `cd`, `pushd`,
   `popd`, `deactivate`, and `cvenv_export`.
   It also prints informational messages (job scratch path, node count,
   writer/read-only status, uv/conda detection, backend).
2. `python -m venv myenv` (or `uv venv`, `conda create`) creates the
   environment in node-local scratch (`CV_JOB_SCRATCH`, `$LOCALSCRATCH`, or
   `/tmp/<job>` by default) and places a symlink in the current directory.
3. `source myenv/bin/activate` (or `conda activate myenv`) activates the
   environment from scratch; if only an archive exists, it is decompressed
   first. On multi-node allocations cvenv then attempts to propagate the
   environment to all nodes via `srun --ntasks-per-node=1`; successful
   propagation makes plain `srun <cmd>` work on every node.
4. `pip install …` / `uv add …` / `conda install …` / `conda env update …` install against the
   scratch copy. After install, the environment is recompressed and
   re-propagated to all nodes (force mode) so successful propagation keeps
   every node in sync.
5. `deactivate` (or `conda deactivate`) compresses the scratch copy back into
   the archive and removes the scratch expansion. On non-head nodes
   (`CV_IS_WRITER=0`), compression is skipped. A `<archive-name>.README.md` file is
   written next to the archive recording the loaded Lmod modules and
   reactivation instructions. A minimal stub
   `myenv/bin/activate` is left behind so `source myenv/bin/activate` works
   again exactly as in a standard Python venv.

### Auto-generated README

When the environment is saved, cvenv attempts to write a
`<archive-name>.README.md` file next to the archive. Write failures are logged
and do not prevent the archive from being saved. This file records:

- The Lmod modules that were loaded (from `$LOADEDMODULES`) when the
  environment was last saved.
- The exact `module load` commands needed to reproduce the environment.
- The `cvenv` module version used when the environment was saved.
- Step-by-step reactivation instructions.

```bash
# After creating and deactivating a venv:
ls /path/to/dir
# <archive-name>.tar.zst  <archive-name>.README.md

cat /path/to/dir/<archive-name>.README.md
# # myenv
#
# This file was auto-generated by **cvenv**.
# ...
# ## Loaded modules
# module load Python/3.13.5-GCCcore-14.3.0
# module load OpenMPI/5.0.10-GCC-14.3.0
# ...
# ## Reactivation
# module load Python/3.13.5-GCCcore-14.3.0
# module load OpenMPI/5.0.10-GCC-14.3.0
# module load cvenv/0.1.0
# cd /path/to/dir
# source myenv/bin/activate
```

### Reactivating an existing environment

To reuse an environment that has already been created and archived, you must:

1. **Check the `<archive-name>.README.md`** file next to the archive to see which
   modules were loaded when the environment was last saved.
2. **Load the same modules** listed in the README.
3. **Change to the environment directory**. The generated README provides the
   exact `cd` command; activating from an unrelated directory can select a
   same-named archive from that directory.
4. **`source myenv/bin/activate`** (Python venv / uv) or
   **`conda activate myenv`** (conda). If only an archive exists, cvenv
   decompresses it into node-local scratch first, then activates it.

```bash
# Example: reactivating a single-node venv
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

cd /path/to/dir
source myenv/bin/activate
```

### Dummy activate stub

After `deactivate` on a writer node, cvenv leaves a minimal stub file at
`myenv/bin/activate` so that the standard Python venv usage pattern still
works:

```bash
deactivate                       # archives the venv, leaves a stub
source myenv/bin/activate        # cvenv detects the stub, decompresses, activates
```

The stub contains a `CVENV_STUB` marker. When the cvenv `source` wrapper sees
this marker, it removes the stub directory, decompresses the archive into
scratch, recreates the symlink, and activates the environment.

Stub directories are placeholders. Reactivation replaces them, so do not store
unrelated files inside them.

### Wrapper option order

Managed mutating commands require the managed subcommand first. cvenv rejects
forms such as `python -B -m pip install`, `uv pip --offline install`, and
`conda --json install` because their option placement hides the mutation from
the wrapper. Place tool-specific options after the managed command, for example
`python -m pip install`, `uv pip install --offline`, or `conda install --json`.

## Multi-node Slurm

In multi-node Slurm allocations each node decompresses its own independent
copy of the environment. Only the head node
(`SLURM_NODEID 0`) is allowed to (re)compress the shared archive; all other
nodes run in read-only mode.

At activation time cvenv attempts to propagate the environment to all nodes
via `srun`. After successful propagation, plain `srun` commands work on every
node:

```bash
source myenv/bin/activate    # head node: decompress + propagate
srun -n 4 python script.py   # works on every node
```

## Caveats

- **Memory consumption**: when the scratch directory is RAM-backed (e.g.
  `/tmp` on some systems), the entire expanded environment occupies node
  memory for the lifetime of the job. A large environment (PyTorch, CUDA,
  scipy, …) can reach several GB, reducing memory available to the workload.
- **Loss on node failure**: if the node crashes or the job is preempted
  before `deactivate` runs, unsaved changes in the scratch copy are lost.
  Only the last compressed archive survives.
- **Concurrency hazard**: activating the same archive from multiple jobs
  simultaneously is unsafe: each job expands its own scratch copy, but the
  last job to deactivate overwrites the archive, silently discarding changes
  from the others.
- **Module compatibility**: loaded modules such as NCCL that depend on CUDA
  should match (or be close to) the CUDA version required by the installed
  packages. A mismatch can lead to runtime errors or subtle numerical issues.
- **Compression failure**: if compression fails on `deactivate` or `cd` away
  (e.g. quota exceeded), the scratch copy is preserved and an error is
  logged; changes are not silently lost.
- **Propagation failure**: if multi-node propagation fails, activation
  continues with a warning and plain `srun` may not work on every node.
- **Conda relocation**: cvenv rewrites text prefix references but skips binary
  files; conda packages that embed absolute prefixes in native binaries may not
  work after reactivation.
- **Module unload**: deactivate active environments and archive expanded uv
  environments before unloading `cvenv`; they rely on its wrapper functions.
- Always run `deactivate` before leaving a job when practical.

## License

[MIT](LICENSE) © Richard Topouchian
