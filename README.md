# cvenv: Compressed Virtual Environments (Python + conda)

`cvenv` is an [Lmod](https://lmod.readthedocs.io) module that transparently
wraps Python virtual environments **and conda environments** so the **expanded
environment lives in job-local scratch** (typically `/tmp`, but any node-local
path such as `$LOCALSCRATCH` or `$SCRATCH` can be used) while only a **single
compressed tar archive** is kept on the parallel filesystem.

On HPC systems with shared parallel filesystems (Lustre, GPFS, BeeGFS, …) a
Python or conda environment contains thousands of small files. Creating,
reading, or activating an environment directly on such a filesystem generates a
storm of metadata operations that saturates the metadata servers and degrades
performance for every user. `cvenv` avoids this by keeping the expanded
environment on node-local scratch (e.g. `/tmp`, `$LOCALSCRATCH`) and storing
only one `.tar.zst` archive on the parallel filesystem.

## Features

- **Node-local expansion**: the environment is decompressed into node-local
  scratch (`/tmp` by default, or any path set via `CV_JOB_SCRATCH`,
  `$LOCALSCRATCH`, `$SCRATCH`) on every node.
- **Single compressed archive**: only one `.tar.zst` file is written back to
  the parallel filesystem at `deactivate` time.
- **Parallel zstd compression**: uses `pzstd` with
  `SLURM_CPUS_ON_NODE` (or 1) threads at compression level `-3`.
- **Slurm integration**: automatically detects the job-local scratch
  directory (`/tmp/<job-id>` inside a Slurm allocation, `/tmp/cvenv_<user>`
  outside). Override with `CV_JOB_SCRATCH` to use any node-local path such as
  `$LOCALSCRATCH` or `$SCRATCH`.
- **Multi-node support**: each node decompresses its own independent copy;
  only the head node (`SLURM_NODEID 0`) recompresses the shared archive.
  At activation, the environment is automatically propagated to all nodes via
  `srun`, so plain `srun <cmd>` works on every node.
- **uv support**: when `uv` is found on `PATH`, `uv venv`, `uv init`, and
  `uv run` are supported automatically. Changing directory away from the venv
  directory auto-deactivates and archives it.
- **conda / miniconda support**: when `conda` is found on `PATH`, `conda
  create`, `conda env create`, and `conda activate` are supported
  automatically. Environments are expanded into node-local scratch and stored
  as a single compressed archive on the parallel filesystem. `conda install`
  / `conda remove` recompress the archive; `conda deactivate` archives and
  cleans up the scratch copy.

## Requirements

- [Lmod](https://lmod.readthedocs.io) (Tcl/Lua module system)
- Bash (the shell wrappers are Bash-specific)
- `pzstd` (parallel zstd) on `PATH`
- Python (`python3`) on `PATH`
- Optional: [uv](https://github.com/astral-sh/uv) for `uv venv` / `uv run` support
- Optional: [conda](https://docs.conda.io/projects/miniconda) / miniconda for
  `conda create` / `conda activate` support

### Module dependencies

`cvenv` relies on the environment set up by the following modules.
Load them **before** `cvenv`. The versions below are **samples only**;
use the versions available on your system:

```bash
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load NCCL/2.30.4-GCCcore-14.3.0-CUDA-13.0.0  # For GPU jobs
module load patchelf/0.18.0-GCCcore-14.3.0  # If NCCL is loaded
```

- **CUDA-only**: multi-GPU and multi-node GPU support is built exclusively on
  NVIDIA CUDA. Other GPU backends (ROCm, oneAPI, …) are **not supported**.
- `cvenv` relies on `LD_LIBRARY_PATH` (set by these modules **OpenMPI,
  NCCL**).

## Installation

The module is distributed as an [EasyBuild](https://easybuild.io) easyconfig
(`cvenv-1.0.1.eb`). Build and install it with `eb`:

```bash
eb cvenv-1.0.1.eb
```

This generates an Lmod module file with the Lua implementation embedded. Use
`module use` to add its location to your module search path (if needed), then
load the module:

```bash
module load cvenv/1.0.1
```

If you prefer a manual install, the Lua module file can be extracted from the
easyconfig's `modluafooter` and placed directly into your module tree:

```bash
mkdir -p /path/to/modulefiles/cvenv
# Extract the modluafooter content into /path/to/modulefiles/cvenv/1.0.1.lua
module use /path/to/modulefiles
module load cvenv/1.0.1
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

### conda from environment.yml

```bash
module load cvenv
conda env create -f environment.yml
conda activate myenv
conda deactivate
```

An existing archive can be reactivated with the same command used to create it:

```bash
source myenv/bin/activate      # Python venv / uv
conda activate myenv            # conda
```

## Environment variables

| Variable | Description |
|---|---|
| `CV_ARCHIVE_DIR` | Archive directory. If unset before module load, the current directory at creation/activation time is used. Do not use `/tmp`! |
| `CV_JOB_SCRATCH` | Expansion directory. Defaults to `/tmp/<job-id>` inside a Slurm allocation, or `/tmp/cvenv_<user>` outside Slurm. Each node decompresses into its own node-local `/tmp`. |
| `CV_JOB_CACHE` | Pip/uv cache directory. If set, overrides `PIP_CACHE_DIR` and `UV_CACHE_DIR`. Defaults to `$SCRATCH` if defined, otherwise `$LOCALSCRATCH` if defined, otherwise pip's default. |
| `CVENV_RO` | Set to `1` to skip recompression on deactivation when no packages were installed. Mutating commands (`pip install`, `uv add/remove/sync`, `conda install/remove`) always recompress regardless. `uv run` sets this automatically. Set to `0` to force recompression everywhere. Default: `1` for `uv run`, unset otherwise. |

## How it works

1. `module load cvenv` installs shell function wrappers for `python`,
   `python3`, `pip`, `pip3`, `source`, `uv`, `conda`, `rm`, `cd`, `pushd`,
   and `popd`.
   It also prints informational messages (job scratch path, node count,
   writer/read-only status, uv/conda detection, backend).
2. `python -m venv myenv` (or `uv venv`, `conda create`) creates the
   environment in node-local scratch (`/tmp/<job>` by default, or
   `CV_JOB_SCRATCH`) and places a symlink in the current directory.
3. `source myenv/bin/activate` (or `conda activate myenv`) activates the
   environment from scratch; if only an archive exists, it is decompressed
   first. On multi-node allocations the environment is then propagated to all
   nodes via `srun --ntasks-per-node=1` so that plain `srun <cmd>` works on
   every node.
4. `pip install …` / `uv add …` / `conda install …` install against the
   scratch copy. After install, the environment is recompressed and
   re-propagated to all nodes (force mode) so every node stays in sync.
5. `deactivate` (or `conda deactivate`) compresses the scratch copy back into
   the archive and removes the scratch expansion. On non-head nodes
   (`CV_IS_WRITER=0`), compression is skipped. A `<name>.README.md` file is
   written next to the archive recording the loaded Lmod modules and
   reactivation instructions. A minimal stub `myenv/bin/activate` is left
   behind so `source myenv/bin/activate` works again exactly as in a standard
   Python venv.

### Auto-generated README

Every time the environment is saved, cvenv writes a `<name>.README.md` file next
to the archive. This file records:

- The Lmod modules that were loaded (from `$LOADEDMODULES`) when the
  environment was last saved.
- The exact `module load` commands needed to reproduce the environment.
- Step-by-step reactivation instructions.

```bash
# After creating and deactivating a venv:
ls /path/to/dir
# myenv.tar.zst  myenv.README.md

cat /path/to/dir/myenv.README.md
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
# module load cvenv
# cd /path/to/dir
# source myenv/bin/activate
```

### Reactivating an existing environment

To reuse an environment that has already been created and archived, you must:

1. **Check the `<name>.README.md`** file next to the archive to see which
   modules were loaded when the environment was created.
2. **Load the same modules** listed in the README.
3. **`cd` into the directory** where the environment was created (the
   directory that contains the `.tar.zst` archive).
4. **`source myenv/bin/activate`** (Python venv / uv) or
   **`conda activate myenv`** (conda). If only an archive exists, cvenv
   decompresses it into node-local scratch first, then activates it.

```bash
# Example: reactivating a single-node venv
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

cd /path/to/dir          # where myenv.tar.zst lives
source myenv/bin/activate
```

### Dummy activate stub

After `deactivate`, cvenv leaves a minimal stub file at
`myenv/bin/activate` so that the standard Python venv usage pattern still
works:

```bash
deactivate                       # archives the venv, leaves a stub
source myenv/bin/activate        # cvenv detects the stub, decompresses, activates
```

The stub contains a `CVENV_STUB` marker. When the cvenv `source` wrapper sees
this marker, it removes the stub directory, decompresses the archive into
scratch, recreates the symlink, and activates the environment.

## Multi-node Slurm

In multi-node Slurm allocations each node decompresses its own independent
copy of the environment. Only the head node
(`SLURM_NODEID 0`) is allowed to (re)compress the shared archive; all other
nodes run in read-only mode.

At activation time the environment is automatically propagated to all nodes
via `srun`, so after activation plain `srun` commands work on every node:

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
- Always run `deactivate` before leaving a job when practical.

## License

[MIT](LICENSE) © Richard Topouchian
