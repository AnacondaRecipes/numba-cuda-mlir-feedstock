@echo off
setlocal enableextensions
rem SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
rem SPDX-License-Identifier: Apache-2.0

if not defined LIBRARY_PREFIX set "LIBRARY_PREFIX=%PREFIX%\Library"

echo Building with PARALLEL=%CPU_COUNT% compile jobs

rem LLVM 23 configuration variables
set "LLVM_MODERN_BUILD_ROOT=%SRC_DIR%\llvm-modern-build"
set "LLVM_MODERN_SRC=%SRC_DIR%\llvm-modern-src"
set "LLVM_MODERN_INSTALL=%SRC_DIR%\llvm-modern-install"
set "MLIR_PKG=%LLVM_MODERN_INSTALL%\python_packages\numba_cuda_mlir_mlir\numba_cuda_mlir\_mlir"
set "MLIR_LIBS=%MLIR_PKG%\_mlir_libs"
set "BRIDGE_BUILD=%SRC_DIR%\mlir-modern-to-nvvm-build"

rem LLVM 7 configuration variables
set "LLVM7_BUILD_ROOT=%SRC_DIR%\llvm7-build"
set "LLVM7_SRC=%SRC_DIR%\llvm7-src"
set "LLVM7_INSTALL=%SRC_DIR%\llvm7-install"
set "LLVM_C_OUT=%SRC_DIR%\llvm-c-install"

rem We don't use it, but keep it for compatibility with CF
set "LAUNCHER_ARGS="

rem pin-python-executable.patch reads $ENV{Python_EXECUTABLE} in the wheel's cmake.
set "Python_EXECUTABLE=%PYTHON%"
echo Python executable is %PYTHON%

rem On a free-threaded build ("t" ABI) tell FindPython to require that ABI, matching
rem build.sh. Fields are [pydebug;pymalloc;unicode;freethreading].
"%PYTHON%" -c "import sysconfig; ft = 't' if 't' in (sysconfig.get_config_var('ABIFLAGS') or '') else ''; open('_ft.tmp', 'w').write(ft)"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

set /p FT=<_ft.tmp
del _ft.tmp

set "FIND_ABI_ARGS="
if "%FT%"=="t" (
  set "FIND_ABI_ARGS=-DPython_FIND_ABI=OFF;OFF;OFF;ON -DPython3_FIND_ABI=OFF;OFF;OFF;ON"
  set "Python_FIND_ABI=OFF;OFF;OFF;ON"
)

echo ==============================================================
echo Step 1a: Build modern LLVM/MLIR + Python bindings
echo ==============================================================

rem Delete build root if exists
if exist "%LLVM_MODERN_BUILD_ROOT%" rmdir /s /q "%LLVM_MODERN_BUILD_ROOT%"

rem Configure
cmake -G Ninja ^
  -S "%LLVM_MODERN_SRC%\llvm" ^
  -B "%LLVM_MODERN_BUILD_ROOT%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%LLVM_MODERN_INSTALL%" ^
  -DCMAKE_C_COMPILER=cl ^
  -DCMAKE_CXX_COMPILER=cl ^
  %LAUNCHER_ARGS% ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL ^
  -DLLVM_USE_CRT_RELEASE=MD ^
  -DLLVM_ENABLE_PROJECTS=mlir ^
  -DLLVM_TARGETS_TO_BUILD=NVPTX ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DLLVM_ENABLE_PIC=ON ^
  -DLLVM_BUILD_TOOLS=OFF ^
  -DLLVM_BUILD_EXAMPLES=OFF ^
  -DLLVM_INCLUDE_TESTS=OFF ^
  -DLLVM_INCLUDE_BENCHMARKS=OFF ^
  -DLLVM_INCLUDE_DOCS=OFF ^
  -DLLVM_ENABLE_ZLIB=OFF ^
  -DLLVM_ENABLE_ZSTD=OFF ^
  -DMLIR_ENABLE_BINDINGS_PYTHON=ON ^
  -DCMAKE_CXX_FLAGS="-DMLIR_PYTHON_PACKAGE_PREFIX=numba_cuda_mlir._mlir. -DMLIR_USE_FALLBACK_TYPE_IDS=1" ^
  -DMLIR_BINDINGS_PYTHON_INSTALL_PREFIX="python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir" ^
  -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=numba_cuda_mlir ^
  -DMLIR_PYTHON_STUBGEN_ENABLED=OFF ^
  -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON ^
  -DPython_ROOT_DIR="%PREFIX%" ^
  -DPython_EXECUTABLE="%PYTHON%" ^
  -DPython_FIND_REGISTRY=NEVER ^
  -DPython3_ROOT_DIR="%PREFIX%" ^
  -DPython3_EXECUTABLE="%PYTHON%" ^
  -DPython3_FIND_REGISTRY=NEVER ^
  %FIND_ABI_ARGS%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Build
cmake --build "%LLVM_MODERN_BUILD_ROOT%" --parallel "%CPU_COUNT%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Install
cmake --install "%LLVM_MODERN_BUILD_ROOT%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo ==============================================================
echo Step 1b: Stage MLIR Python bindings into the install tree
echo ==============================================================

"%PYTHON%" "%RECIPE_DIR%\stage_mlir_bindings.py" --build-root "%LLVM_MODERN_BUILD_ROOT%" --install-root "%LLVM_MODERN_INSTALL%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo ==============================================================
echo Step 1c: Modern-to-NVVM bridge (MLIRModernToNVVM)
echo ==============================================================

rem Delete build root if exists
if exist "%BRIDGE_BUILD%" rmdir /s /q "%BRIDGE_BUILD%"

rem Configure
cmake -G Ninja ^
  -S "%SRC_DIR%\src\cext\mlir-modern" ^
  -B "%BRIDGE_BUILD%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_PREFIX_PATH="%LLVM_MODERN_INSTALL%" ^
  -DMLIR_DIR="%LLVM_MODERN_INSTALL%\lib\cmake\mlir" ^
  -DLLVM_DIR="%LLVM_MODERN_INSTALL%\lib\cmake\llvm" ^
  -DCMAKE_C_COMPILER=cl ^
  -DCMAKE_CXX_COMPILER=cl ^
  %LAUNCHER_ARGS% ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Build
cmake --build "%BRIDGE_BUILD%" --target MLIRModernToNVVM MLIRModernToNVVMSmoke --parallel "%CPU_COUNT%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Install
for %%E in (dll lib) do for /f "delims=" %%F in ('dir /b /s "%BRIDGE_BUILD%\MLIRModernToNVVM.%%E" 2^>nul') do copy /y "%%F" "%MLIR_LIBS%\" >nul

rem Verify
if not exist "%MLIR_LIBS%\MLIRModernToNVVM.dll" (echo ERROR: MLIRModernToNVVM.dll was not produced & exit /b 1)

echo ==============================================================
echo Step 2a: Build LLVM7
echo ==============================================================

rem Delete build root if exists
if exist "%LLVM7_BUILD_ROOT%" rmdir /s /q "%LLVM7_BUILD_ROOT%"

rem Patch CMP0051 OLD to NEW for modern CMake compatibility
rem Use python's str replace instead of 'sed' or 'powershell' commands
"%PYTHON%" -c "import re, pathlib; p = pathlib.Path(r'%LLVM7_SRC%\llvm\CMakeLists.txt'); p.write_text(p.read_text().replace('cmake_policy(SET CMP0051 OLD)', 'cmake_policy(SET CMP0051 NEW)'))"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Configure
cmake -G Ninja ^
  -S "%LLVM7_SRC%\llvm" ^
  -B "%LLVM7_BUILD_ROOT%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%LLVM7_INSTALL%" ^
  -DCMAKE_C_COMPILER=cl ^
  -DCMAKE_CXX_COMPILER=cl ^
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
  -DLLVM_USE_CRT_RELEASE=MT ^
  -DLLVM_TARGETS_TO_BUILD=NVPTX ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DLLVM_ENABLE_PIC=ON ^
  -DLLVM_BUILD_TOOLS=OFF ^
  -DLLVM_BUILD_UTILS=OFF ^
  -DLLVM_BUILD_EXAMPLES=OFF ^
  -DLLVM_INCLUDE_TESTS=OFF ^
  -DLLVM_INCLUDE_BENCHMARKS=OFF ^
  -DLLVM_INCLUDE_DOCS=OFF ^
  -DLLVM_ENABLE_TERMINFO=OFF ^
  -DLLVM_ENABLE_ZLIB=OFF ^
  -DLLVM_ENABLE_ZSTD=OFF ^
  -DLLVM_ENABLE_DIA_SDK=OFF
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Build
cmake --build "%LLVM7_BUILD_ROOT%" --target install --parallel "%CPU_COUNT%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo ==============================================================
echo Step 2b: Synthesize LLVM-C.dll for LLVM7
echo ==============================================================

rem Synthesize LLVM-C.dll from llvmdev's static LLVM 7 libs, because
rem LLVM 7 cannot build LLVM-C.dll on Windows itself. This is the Windows
rem equivalent of Linux's libLLVM-7.so
"%PYTHON%" "%RECIPE_DIR%\build_llvm_c_dll.py" --lib-dir "%LLVM7_INSTALL%\lib" --out-dir "%LLVM_C_OUT%" --dll-name LLVM-C
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo ==============================================================
echo Step 3: Build numba_cuda_mlir wheel
echo ==============================================================

cd /d "%SRC_DIR%\src"

rem CUDA headers + dlpack come from the conda host env (Library prefix on Windows).
set "CUDAToolkit_ROOT=%LIBRARY_PREFIX%"
set "DLPACK_PATH=%LIBRARY_PREFIX%"
set "MLIR_DIR=%LLVM_MODERN_INSTALL%\lib\cmake\mlir"
rem setup.py._stage_libllvm7 bundles this DLL into numba_cuda_mlir\lib\ (keeps the
rem basename on Windows). At runtime CAPILoader LoadLibrary's it. No symlink step
rem (that is Linux-only).
set "LIBLLVM7=%LLVM_C_OUT%\LLVM-C.dll"

"%PYTHON%" -m pip install . -vv --no-deps --no-build-isolation
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
