#!/usr/bin/env bash

set -ex -o pipefail

OS=$(uname -s)
ARCH=$(uname -m)
TARGET_ARCH="$ARCH"
CROSS_COMPILING=0

echo "* OS:           $OS"
echo "* ARCH:         $ARCH"
echo "* Conda prefix: $PREFIX"
echo "* CC:           $CC"
echo "* CXX:          $CXX"
echo "* FC:           $FC"

if [[ "$host_alias" != "$build_alias" ]]; then # shellcheck disable=SC2154
  CROSS_COMPILING=1
  TARGET_ARCH="arm64"
  echo "* Cross-compiling from $ARCH to $TARGET_ARCH"
fi

# --- Patch Makefile.rules in both repos ---

for rules_file in SDDS/Makefile.rules elegant/Makefile.rules; do
  # Add conda prefix to library search paths (LIB_DIRS is used for wildcard
  # detection of system libraries like gsl, fftw, hdf5, etc.)
  sed -i'' -e "s|^LIB_DIRS := |LIB_DIRS := ${PREFIX}/lib |" "$rules_file"

  # Replace compilers with conda toolchain (Linux section)
  sed -i'' -e "s|^  CC = gcc\$|  CC = ${CC}|" "$rules_file"
  sed -i'' -e "s|^  CCC = g++\$|  CCC = ${CXX}|" "$rules_file"
  sed -i'' -e "s|^  AR = ar rcs\$|  AR = ${AR} rcs|" "$rules_file"
  sed -i'' -e "s|^  F77 = gfortran -m64 -ffixed-line-length-132\$|  F77 = ${FC} -m64 -ffixed-line-length-132|" "$rules_file"

  # Replace compilers with conda toolchain (Darwin section)
  sed -i'' -e "s|^  CC = clang\$|  CC = ${CC}|" "$rules_file"
  sed -i'' -e "s|^  CCC = clang++\$|  CCC = ${CXX}|" "$rules_file"
  sed -i'' -e "s|^  AR = libtool -static -o\$|  AR = ${AR} rcs|" "$rules_file"
  sed -i'' -e "s|^  F77 = gfortran-mp-14 -m64 -ffixed-line-length-132\$|  F77 = ${FC} -m64 -ffixed-line-length-132|" "$rules_file"

  # Replace ranlib (same pattern in both sections)
  sed -i'' -e "s|^  RANLIB = ranlib\$|  RANLIB = ${RANLIB}|" "$rules_file"

  # Remove -mcpu=native for reproducible builds
  sed -i'' -e 's/-mcpu=native//g' "$rules_file"

  # Fix LAPACKE include path: the default points to /usr/include/lapacke,
  # but conda's liblapacke puts lapacke.h in $PREFIX/include (already in
  # EXTRA_INC_DIRS via library detection).
  sed -i'' -e 's|-I/usr/include/lapacke||g' "$rules_file"
done

# Remove -m64 on non-x86_64 targets (would error on aarch64)
if [[ "$TARGET_ARCH" != "x86_64" ]]; then
  for rules_file in SDDS/Makefile.rules elegant/Makefile.rules; do
    sed -i'' -e 's/ -m64//g' "$rules_file"
  done
fi

# --- Stub out vendored libraries (use conda-forge packages instead) ---

for dir in SDDS/png SDDS/gd SDDS/tiff SDDS/zlib SDDS/lzma; do
  printf 'all:\ninstall:\nclean:\n' >"$dir/Makefile"
done

# --- Stub out Qt-based tools for now ---

printf 'all:\ninstall:\nclean:\n' >SDDS/SDDSaps/sddseditor/Makefile
printf 'all:\ninstall:\nclean:\n' >SDDS/SDDSaps/sddsplots/qtDriver/Makefile

# --- Remove hardcoded gcc rule in sddsplots ---
# SDDS/SDDSaps/sddsplots/Makefile has a special rule that hardcodes gcc and
# its own flags (missing $(EXTRA_INC_DIRS)) to work around an -O3 optimization
# bug. Remove it so the default rule from Makefile.build handles it with the
# correct compiler and flags.

sed -i'' -e '/^# Special compilation rule/d' SDDS/SDDSaps/sddsplots/Makefile
sed -i'' -e '/^O\.Linux-x86_64\/sddsplot\.o/d' SDDS/SDDSaps/sddsplots/Makefile
sed -i'' -e '/gcc -m64 -O0/d' SDDS/SDDSaps/sddsplots/Makefile

# --- Remove -Bstatic/-static-libgcc from elegant MPI Makefile ---
# We want dynamic linking

sed -i'' -e 's/-Bstatic //g' elegant/src/Makefile.mpi
sed -i'' -e 's/-static-libgcc //g' elegant/src/Makefile.mpi

# --- Set MPI environment ---

export MPICH_CC="$CC"
export MPICH_CXX="$CXX"
export OMPI_CC="$CC"
export OMPI_CXX="$CXX"

# --- Common make arguments ---

MAKE_ARGS=(
  "MPI_CC=mpicc"
  "MPI_CCC=mpicxx"
)

# --- Cross-compilation handling ---

if [[ "$CROSS_COMPILING" == "1" ]]; then
  echo "* Phase 1: Building all of SDDS for the build machine ($ARCH)"

  # nlpp is a code generator that must run on the build machine during the
  # elegant build. Build the entire SDDS tree natively so nlpp (and all
  # libraries it depends on) are available.
  make -C SDDS -j"${CPU_COUNT}" \
    "CC=${CC_FOR_BUILD}" \
    "CCC=${CXX_FOR_BUILD}" \
    "AR=$(which ar) rcs" \
    "RANLIB=$(which ranlib)"

  NLPP_NATIVE="SDDS/bin/${OS}-${ARCH}/nlpp"
  if [[ ! -f "$NLPP_NATIVE" ]]; then
    echo "* ERROR: nlpp was not built for the build machine"
    exit 1
  fi
  echo "* nlpp built successfully"
  "$NLPP_NATIVE" || true

  # Save native nlpp
  cp "$NLPP_NATIVE" "${SRC_DIR}/nlpp_native"

  # For mpich: patch wrappers to remove build-prefix library paths
  # that would cause the linker to find x86_64 libs before arm64 ones.
  # shellcheck disable=SC2154
  if [[ "${mpi}" == "mpich" ]]; then
    echo "* Patching mpicc/mpicxx for cross-compilation"
    echo "* Before patch:"
    grep -e "^final_ldflags=" "$(readlink -f "$(which mpicc)")" "$(readlink -f "$(which mpicxx)")" || true
    sed -i '' \
      's/^final_ldflags=".*$/final_ldflags=""/' \
      "$(readlink -f "$(which mpicc)")" \
      "$(readlink -f "$(which mpicxx)")"
    echo "* After patch:"
    grep -e "final_ldflags=" "$(readlink -f "$(which mpicc)")" "$(readlink -f "$(which mpicxx)")" || true
  fi

  echo "* Phase 2: Building SDDS for target ($TARGET_ARCH)"
  make -C SDDS -j"${CPU_COUNT}" "ARCH=${TARGET_ARCH}" "${MAKE_ARGS[@]}"

  echo "* Restoring native nlpp for elegant build"
  cp "${SRC_DIR}/nlpp_native" "SDDS/bin/${OS}-${TARGET_ARCH}/nlpp"
  chmod +x "SDDS/bin/${OS}-${TARGET_ARCH}/nlpp"

  echo "* Phase 2: Building elegant for target ($TARGET_ARCH)"
  make -C elegant -j"${CPU_COUNT}" "ARCH=${TARGET_ARCH}" "${MAKE_ARGS[@]}"

  ARCH="$TARGET_ARCH"
else
  # --- Native build ---

  echo "* Building SDDS"
  make -C SDDS -j"${CPU_COUNT}" "${MAKE_ARGS[@]}"

  echo "* Building elegant"
  make -C elegant -j"${CPU_COUNT}" "${MAKE_ARGS[@]}"
fi

# --- Install ---

echo "* Installing binaries to $PREFIX/bin"
mkdir -p "${PREFIX}/bin"
cp -f "SDDS/bin/${OS}-${ARCH}/"* "${PREFIX}/bin/" 2>/dev/null || true
cp -f "elegant/bin/${OS}-${ARCH}/"* "${PREFIX}/bin/" 2>/dev/null || true

# Make binaries writeable so patchelf/install_name_tool can modify them
chmod +w "${PREFIX}/bin/"* 2>/dev/null || true

echo "* Build and install complete"
