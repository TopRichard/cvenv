# cvenv: Compressed Virtual Environments(Python)

`cvenv` is an [Lmod](https://lmod.readthedocs.io) module that transparently
wraps Python virtual environments so the **expanded environment lives in
job-local scratch** (typically `/tmp`, but any node-local path such as
`$LOCALSCRATCH` or `$SCRATCH` can be used) while only a **single compressed
tar archive** is kept on the parallel filesystem.

On HPC systems with shared parallel filesystems (Lustre, GPFS, BeeGFS, …) a
Python virtual environment contains thousands of small files. Creating,
reading, or activating a venv directly on such a filesystem generates a storm
of metadata operations that saturates the metadata servers and degrades
performance for every user. `cvenv` avoids this by keeping the expanded venv
on node-local scratch (e.g. `/tmp`, `$LOCALSCRATCH`) and storing only one
`.tar.zst` archive on the parallel filesystem.

## Features

- **Node-local expansion**: the venv is decompressed into node-local scratch
  (`/tmp` by default, or any path set via `CV_JOB_SCRATCH`, `$LOCALSCRATCH`,
  `$SCRATCH`) on every node.
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
  Use `cvexec` to launch MPI
  commands, it assures the venv is copied on every node.
- **uv support**: when `uv` is found on `PATH`, `uv venv`, `uv init`, and
  `uv run` are supported automatically. Changin directory away 
from the venv directory auto deactivates and archives it.

## Requirements

- [Lmod](https://lmod.readthedocs.io) (Tcl/Lua module system)
- Bash (the shell wrappers are Bash-specific)
- `pzstd` (parallel zstd) on `PATH`
- Python(`python3`) on `PATH`
- Optional: [uv](https://github.com/astral-sh/uv) for `uv venv` / `uv run` support

### Module dependencies

`cvenv` relies on the environment set up by the following modules.
Load them **before** `cvenv`. The versions below are **samples only**, use the
versions available on your system:

```bash
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load NCCL/2.30.4-GCCcore-14.3.0-CUDA-13.0.0
module load patchelf/0.18.0-GCCcore-14.3.0
```

- **NCCL** and **patchelf** are **only required for multi-node GPU** jobs.
  They are **not needed for single-node GPU** or any CPU-only job (including
  multi-node CPU-only MPI). However, if you intend to reuse the same compressed
  environment on multi-node GPUs later, load NCCL and patchelf **from the start**
  so the venv is created with the correct library paths.
- **CUDA-only**: multi-GPU and multi-node GPU support is built exclusively on
  NVIDIA CUDA. Other GPU backends (ROCm, oneAPI, …) are **not supported**.
- `cvenv` relies on `LD_LIBRARY_PATH` (set by these modules **OpenMPI, NCCL**).

## Installation

The module is distributed as an [EasyBuild](https://easybuild.io) easyconfig
(`cvenv-1.0.eb`). Build and install it with `eb`:

```bash
eb cvenv-1.0.eb
```

This generates an Lmod module file with the Lua implementation embedded. Use `module use` to add its location to your module search path(if needed), then load the module:

```bash
module load cvenv/1.0
```

If you prefer a manual install, the Lua module file can be extracted from the
easyconfig's `modluafooter` and placed directly into your module tree:

```bash
mkdir -p /path/to/modulefiles/cvenv
# Extract the modluafooter content into /path/to/modulefiles/cvenv/1.0.lua
module use /path/to/modulefiles
module load cvenv/1.0
```

## Quick Start

### Single-node (CPU-only)

For single-node, CPU-only jobs you only need Python and OpenMPI, **NCCL and
patchelf are not required**:

```bash
# 1. Load the minimal toolchain (no NCCL or patchelf needed)
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

# 2. Create a venv
python -m venv myenv

# 3. Activate, if only an archive exists, it is decompressed first
source myenv/bin/activate

# 4. Install packages against the scratch copy
pip install pytest==9.1.1 numpy==2.5.3

# 5. Run your workload (cvexec not needed on a single node)
srun -n 4 pytest numpy_test.py

# 6. Deactivate, compresses the scratch copy back into the archive and cleans up
deactivate
```

### Using uv

```bash
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

uv venv myenv
source myenv/bin/activate
uv pip install pytest==9.1.1 numpy==2.5.3
deactivate
```

### Multi-GPU (single-node)

For multi-GPU on a **single node**, NCCL and patchelf are **not required**,
just load Python and OpenMPI:

```bash
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

python -m venv myenv
source myenv/bin/activate
pip install torchvision==0.29

# Single-node multi-GPU with torchrun (cvexec not needed on a single node)
torchrun --standalone --nnodes=1 --nproc_per_node=4 \
    train_ddp.py --batch-size 1024 --epochs 100 --base-lr 0.04 \
    --target-accuracy 0.95 --patience 2

deactivate
```

> **Tip:** if you plan to reuse this same compressed environment on multiple
> nodes later, load NCCL and patchelf **now** (see below) so the venv is
> created with the correct library paths from the start.

### Multi-node GPU

For multi-node GPU jobs, **NCCL** and **patchelf** must be loaded in addition
to Python and OpenMPI. NCCL provides inter-node GPU communication, and
`patchelf` fixes up library paths in the expanded venv. GPU support is limited to CUDA.
 Other GPU backends (ROCm, oneAPI, …) are not supported.
`cvenv` relies on `LD_LIBRARY_PATH` set by the OpenMPI and NCCL modules.

```bash
# 1. Load the full toolchain (NCCL + patchelf required for multi-node GPU)
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load NCCL/2.30.4-GCCcore-14.3.0-CUDA-13.0.0
module load patchelf/0.18.0-GCCcore-14.3.0
module load cvenv

# 2. Create and activate the venv
python -m venv myenv
source myenv/bin/activate
pip install vllm==0.29.0 ray==2.58.0

# 3.a Multi-node: use cvexec so cvenv decompresses and activates the
#     venv on every node. Separate launcher options from the payload with '--'.
cvexec srun --overlap --nodes=1 --ntasks=1 --nodelist="${head_node}" \
    env RAY_ADDRESS="${head_node_ip}:6379" \
    -- vllm serve Qwen3.8-27B-FP8 \
        --tensor-parallel-size 4 \
        --pipeline-parallel-size 2 \
        --kv-cache-dtype fp8 \
        --max-model-len 16384 \
        --max-num-seqs 512 \
        --gpu-memory-utilization 0.90 \
        --reasoning-parser qwen3 \
        --served-model-name Qwen3.8-27B-FP8 \
        --distributed-executor-backend ray
# 3.b  When used without launcher options:
cvexec srun torchrun \
  --nnodes="${SLURM_JOB_NUM_NODES}" \
  --nproc_per_node="${SLURM_GPUS_ON_NODE}" \
  --rdzv_id="${SLURM_JOB_ID}" \
  --rdzv_backend=c10d \
  --rdzv_endpoint="${RDZV_ENDPOINT}" \
  train_ddp.py --epochs 100 --batch-size 2048 --base-lr 0.04 --target-accuracy 0.95 --patience 2

# 4. Deactivate, compresses the scratch copy back into the archive
deactivate
```

### When to use cvexec

`cvexec` is a wrapper around MPI launchers (`srun`, `mpirun`, …) that ensures
**every rank** decompresses and activates the venv on its own node.

- **Multi-node jobs**: always use `cvexec`. Without it, the venv will not be copied
to all nodes.
- **Single-node jobs**: `cvexec` is **not needed**. You can launch directly
  with `srun`, or just run `python script.py`, since the venv is
  already activated on the only node.

### Multi-node CPU-only

For multi-node CPU-only MPI jobs, just
load Python and OpenMPI. You still need `cvexec` so every rank decompresses and
activates the venv on its own node:

```bash
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

python -m venv myenv
source myenv/bin/activate
pip install pytest==9.1.1 numpy==2.5.3

cvexec srun -N 2 -n 80 --ntasks-per-node=40 -- pytest test_numpy.py

deactivate
```

## Key Environment Variables

| Variable | Description |
|---|---|
| `CV_ARCHIVE_DIR` | Archive directory. If unset before module load, the current directory at creation/activation time is used. Do **not** use `/tmp`, as doing so will cause an error. |
| `CV_JOB_SCRATCH` | Expansion directory (node-local scratch). Defaults to `/tmp/<job-id>` inside a Slurm allocation, or `/tmp/cvenv_<user>` outside Slurm. Can be set to any node-local path such as `$LOCALSCRATCH` or `$SCRATCH`. Each node decompresses into its own copy. |
| `CV_MULTI_NODE` | Set automatically to `1` inside a multi-node Slurm allocation, `0` otherwise. Read-only — used internally by `cvexec` and the wrappers. |
| `CV_JOB_CACHE` | Cache directory for pip and uv. If set, overrides both `PIP_CACHE_DIR` and `UV_CACHE_DIR`. Defaults to `$SCRATCH` if defined, otherwise `$LOCALSCRATCH` if defined, otherwise pip's default. |

## How It Works

1. `module load cvenv` installs Bash shell wrappers for `python`, `python3`,
   `pip`, `pip3`, `source`, `uv`, `rm`, `cd`, `pushd`, `popd`, and `cvexec`.
   It also prints informational messages (job scratch path, node count,
   writer/read-only status, uv detection, backend).
2. `python -m venv myenv` creates the venv with `--copies` in node-local
   scratch (`/tmp/<job>` by default, or `CV_JOB_SCRATCH`) and places a
   symlink in the current directory.
3. `source myenv/bin/activate` activates the venv from scratch; if only an
   archive exists, it is decompressed first.
4. `pip install …` installs run against the scratch copy.
5. `deactivate` compresses the scratch copy back into the archive and removes
   the scratch expansion. On non-head nodes (`CV_IS_WRITER=0`), compression is
   skipped.

### Reactivating an existing venv

To reuse a venv that has already been created and archived, you must:

1. **Load the same modules** that were loaded when the venv was created.
2. **`cd` into the directory** where the venv was created (the directory that
   contains the `.tar.zst` archive).
3. **`source myenv/bin/activate`** if only an archive exists, `cvenv`
   decompresses it into node-local scratch first, then activates it.

```bash
# Example: reactivating a single-node venv
module load Python/3.13.5-GCCcore-14.3.0
module load OpenMPI/5.0.10-GCC-14.3.0
module load cvenv

cd /path/to/dir          # where myenv.tar.zst lives
source myenv/bin/activate
```

## Caveats

- **Memory consumption**: when the scratch directory is RAM-backed (e.g.
  `/tmp` on some systems), the entire expanded venv
  occupies node memory for the lifetime of the job. A large environment
  (PyTorch, CUDA, scipy, …) can reach several GB, reducing memory available to
  the workload.
- **Loss on node failure**: if the node crashes or the job is preempted
  before `deactivate` runs, unsaved changes in the scratch copy are lost. Only
  the last compressed archive survives.
- **Concurrency hazard**: activating the same archive from multiple jobs
  simultaneously is unsafe: each job expands its own scratch copy, but the
  last job to deactivate overwrites the archive, silently discarding changes
  from the others.
- **Module compatibility**: loaded modules such as NCCL that depend on CUDA should match (or be close to) the CUDA version required by the installed packages. A mismatch can lead to runtime errors or subtle numerical issues.
- Always run `deactivate` before leaving a job when practical.

## License

[MIT](LICENSE) © Richard Topouchian
