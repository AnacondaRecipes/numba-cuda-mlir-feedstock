#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "${SRC_DIR}/src"

PARALLEL="${PARALLEL:-${CPU_COUNT:-$(nproc)}}"
export PARALLEL
export PYTHON="${PREFIX}/bin/python"


export BUILD_ROOT="${SRC_DIR}/_build"
export LLVM_MODERN_BUILD_ROOT="${BUILD_ROOT}/llvm"
export LLVM_MODERN_INSTALL="${SRC_DIR}/llvm-modern-install"
export LLVM_MODERN_SRC="${SRC_DIR}/llvm-modern-src"

echo "=============================================================="
echo "Step 1a/2: Modern LLVM/MLIR + Python bindings"
echo "=============================================================="

cmake_args=(
    -G Ninja
    -S "${LLVM_MODERN_SRC}/llvm"
    -B "${LLVM_MODERN_BUILD_ROOT}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${LLVM_MODERN_INSTALL}"
    -DLLVM_ENABLE_PROJECTS=mlir
    -DLLVM_TARGETS_TO_BUILD=NVPTX
    -DLLVM_BUILD_TOOLS=OFF
    -DLLVM_BUILD_EXAMPLES=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_ZLIB=OFF
    -DLLVM_ENABLE_ZSTD=OFF
    -DMLIR_ENABLE_BINDINGS_PYTHON=ON
    -DCMAKE_CXX_FLAGS="-DMLIR_PYTHON_PACKAGE_PREFIX=numba_cuda_mlir._mlir."
    -DMLIR_BINDINGS_PYTHON_INSTALL_PREFIX="python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir"
    -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=numba_cuda_mlir
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON
    # MLIR (MLIRDetectPythonEnv.cmake) and the numba wheel each run find_package(Python3)
    # *and* an unversioned find_package(Python) (nanobind looks for Python_, not Python3_).
    # A free-threaded conda env ships only python3.14t (no python3.14), so an unpinned
    # search skips it and grabs a stray interpreter on PATH (e.g. /opt/conda/bin/python3.12).
    # Pin both so every find_package agrees on the conda interpreter.
    -DPython3_EXECUTABLE="${PYTHON}"
    -DPython_EXECUTABLE="${PYTHON}"
)

# The wheel's find_package(Python) can't take -D (setup.py hardcodes its cmake args) and
# CMake won't read this from the environment on its own, so pin-python-executable.patch
# forwards $ENV{Python_EXECUTABLE} / $ENV{Python_FIND_ABI}.
export Python_EXECUTABLE="${PYTHON}"

# CMake's FindPython gates each artifact on an ABI-accept list whose default excludes the
# free-threaded "t" ABI. On a free-threaded build set FIND_ABI's free-threading field ON so
# "t" is the required ABI (forcing this on a regular build would reject its interpreter,
# hence the guard). Fields are [pydebug;pymalloc;unicode;freethreading] = OFF;OFF;OFF;ON.
if [[ "$("${PYTHON}" -c 'import sysconfig; print(sysconfig.get_config_var("ABIFLAGS") or "")')" == *t* ]]; then
    freethread_abi="OFF;OFF;OFF;ON"
    cmake_args+=(
        -DPython3_FIND_ABI="${freethread_abi}"
        -DPython_FIND_ABI="${freethread_abi}"
    )
    export Python_FIND_ABI="${freethread_abi}"
fi

cmake "${cmake_args[@]}"
cmake --build "${LLVM_MODERN_BUILD_ROOT}" -j "${PARALLEL}"
cmake --install "${LLVM_MODERN_BUILD_ROOT}"

echo "=============================================================="
echo "Step 1b/2: LLVM 7"
echo "=============================================================="

# We don't have "libllvm7.1" package in the Anaconda main channel.
# Because of the pre-Blackwell GPUs whose libnvvm expects the LLVM 7
# dialect of NVVM IR, we have to build LLVM 7.1.0 as per the instructions
# on the 'INSTALL.md' file.
# Ref: https://github.com/NVIDIA/numba-cuda-mlir/tree/main/cext/mlir-llvm70

# Set LLVM7 variables
export LLVM7_BUILD_ROOT="${BUILD_ROOT}/llvm7"
export LLVM7_SRC="${SRC_DIR}/llvm7-src"
export LLVM7_INSTALL="${SRC_DIR}/llvm7-install"

# Patch CMP0051 OLD → NEW for modern CMake compatibility
sed -i 's/cmake_policy(SET CMP0051 OLD)/cmake_policy(SET CMP0051 NEW)/' \
    "${LLVM7_SRC}/llvm/CMakeLists.txt"

# Configure
cmake -G Ninja -S "${LLVM7_SRC}/llvm" -B "${LLVM7_BUILD_ROOT}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${LLVM7_INSTALL}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLLVM_TARGETS_TO_BUILD="NVPTX" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=ON

# Build only the LLVM shared lib
cmake --build "${LLVM7_BUILD_ROOT}" -j "${PARALLEL}" --target LLVM

# Inspired from: <project-repo>/ci/llvm7-install.sh
#
# LLVM 7's tools/llvm-shlib creates extra compatibility symlinks
# (libLLVM-7.so, libLLVM.so -> libLLVM-7.1.so)
# regardless of CMAKE_PLATFORM_NO_VERSIONED_SONAME.
# The narrow `cp` + manual `strip` avoids that entirely.
LLVM7_SO="$(ls "${LLVM7_BUILD_ROOT}"/lib/libLLVM-7*.so | head -1)"
strip --strip-unneeded "${LLVM7_SO}"
cp "${LLVM7_SO}" "${LLVM7_INSTALL}/lib/libLLVM-7.so"

# Leaving 'cmake --install ...' here for debugging purposes.
# Note that CMake automatically runs binary stripping when
# CMAKE_BUILD_TYPE is set to 'Release'.
#cmake --install "${LLVM7_BUILD_ROOT}"

echo "=============================================================="
echo "Step 2/2: numba_cuda_mlir wheel"
echo "=============================================================="

# CUDA headers come from the conda host env; FindCUDAToolkit.cmake honors
# $CUDAToolkit_ROOT for cuda.h.
export CUDAToolkit_ROOT="${PREFIX}"
export DLPACK_PATH="${PREFIX}"
export MLIR_DIR="${LLVM_MODERN_INSTALL}/lib/cmake/mlir"
# Since we don't have 'libllvm7.1' package in the main channel,
# we bundle it with the package.
export LIBLLVM7="${LLVM7_INSTALL}/lib/libLLVM-7.so"

"${PYTHON}" -m pip install . -vv --no-deps --no-build-isolation
