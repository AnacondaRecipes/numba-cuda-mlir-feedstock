"""Compile-only smoke test for both numba-cuda-mlir code generation paths.

Adapted from upstream tests/test_symbol_isolation.py (v0.5.4). It needs no GPU
and no CUDA driver, but it loads every runtime dependency that code generation
uses:

* cc=(8, 0) takes the legacy path (sm < 100): MLIRToLLVM70 plus the bundled
  libLLVM-7.so / LLVM-C.dll (and zlib through it), then libNVVM.
* cc=(10, 0) takes the modern path: the bundled MLIR C API (MLIRModernToNVVM
  on Windows), then libNVVM.
* Both paths use cuda-pathfinder to find libnvvm, libnvrtc and the cudart
  headers. They also link the PTX with nvJitLink through cuda-core.
"""

import platform
import sys

import numba_cuda_mlir
import numba_cuda_mlir.tools as nb_tools
from numba_cuda_mlir import cuda
from numba_cuda_mlir.numba_cuda import types

# resolve_gpu_target() asks the CUDA driver for the host compute capability even
# when cc= is given explicitly (tools.py:43), and CI runners have no GPU. Fill
# the module-level cache with a cc no higher than the lowest one compiled below,
# so the linker uses the requested arch. If upstream renames this private
# variable, the test fails loudly with CudaSupportError instead of passing
# silently.
nb_tools._cached_cc = (8, 0)


def add(x, y):
    return x + y


# Not run on win-arm64, where LLVM 7 is not built (see the selector in meta.yaml).
print(f"numba_cuda_mlir {numba_cuda_mlir.__version__} on {sys.platform}/{platform.machine()}")
for cc in [(8, 0), (10, 0)]:
    ptx, resty = cuda.compile_ptx(add, types.int32(types.int32, types.int32), device=True, cc=cc)
    target = f".target sm_{cc[0]}{cc[1]}"
    assert target in ptx, f"cc={cc}: {target!r} not found in PTX:\n{ptx[:2000]}"
    assert resty == types.int32, f"cc={cc}: unexpected return type {resty}"
    print(f"cc={cc}: OK ({len(ptx)} bytes of PTX)")
