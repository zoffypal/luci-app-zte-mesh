#!/bin/sh
# build-glibc-legacy.sh -- rebuild the vendor glibc 2.26 for Linux 4.4.
#
# The vendor ships Buildroot glibc 2.26 built for a minimum kernel of 5.4.0,
# which refuses to run on a 4.4.60 router ("FATAL: kernel too old"). This
# rebuilds the *same* glibc snapshot (Buildroot 2018.02.12's
# glibc-2.26-193, commit a0bc5dd3bed4b04814047265b3bcead7ab973b87) with
# --enable-kernel=4.4.0, for arm-linux-gnueabi (soft-float, EABI5 -- the
# vendor ELF's e_flags 0x5000200, no Tag_ABI_VFP_args, INTERP
# /lib/ld-linux.so.3), then repacks the runtime tarball with the five
# rebuilt libraries and the patched ns-run.c.
#
#   sh legacy/19.07/tools/build-glibc-legacy.sh [WORKDIR]
#
# WORKDIR defaults to ./legacy-glibc-build under the repository root. It
# downloads the ARM toolchain, the glibc snapshot and the Linux 4.4 headers
# (all SHA256-checked where the upstream publishes one), builds glibc
# (~8 min on 2 cores), and writes:
#
#   $WORKDIR/runtime-new-lib/{ld-linux.so.3,libc.so.6,libdl.so.2,libm.so.6,libpthread.so.0}
#   $WORKDIR/zte-mesh-runtime-legacy.tar.gz   (ready to drop into legacy/19.07/)
#
# The CI ipk job does NOT run this script: it uses the committed
# legacy/19.07/zte-mesh-runtime-legacy.tar.gz, whose five libraries are
# exactly the bytes this script produced on 2026-11-11 (verified on a real
# QWRT 4.4.60 router). Run this when the vendor tarball changes, or to
# audit that the committed libraries really come from this source.
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=${1:-$REPO/legacy-glibc-build}
LEGACY=$REPO/legacy/19.07
mkdir -p "$WORK/dl" "$WORK/out"

TC_URL="https://developer.arm.com/-/media/Files/downloads/gnu-a/8.3-2019.03/binrel/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabi.tar.xz"
GLIBC_URL="https://github.com/bminor/glibc/archive/glibc-2.26-193-ga0bc5dd3bed4b04814047265b3bcead7ab973b87.tar.gz"
GLIBC_SHA256="6c982204f990bef280359be29702143f22f41bd57491619970b70c315957812b"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.4.302.tar.xz"
LINUX_SHA256="35017bb40b604e0b577fc2b87e727632b46608a2ba3a4f5858b9177f58f376b3"

fetch() { # URL DEST [SHA256]
    if [ -f "$2" ]; then echo "have $2"; else
        echo "fetch $1"
        curl -L --retry 3 -o "$2" "$1"
    fi
    if [ -n "${3:-}" ]; then
        echo "$3  $2" | sha256sum -c - || { echo "sha256 mismatch for $2" >&2; exit 1; }
    fi
}

fetch "$TC_URL" "$WORK/dl/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabi.tar.xz"
fetch "$GLIBC_URL" "$WORK/dl/glibc-2.26-193.tar.gz" "$GLIBC_SHA256"
fetch "$LINUX_URL" "$WORK/dl/linux-4.4.302.tar.xz" "$LINUX_SHA256"

[ -d "$WORK/dl/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabi" ] || \
    tar -C "$WORK/dl" -xf "$WORK/dl/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabi.tar.xz"
[ -d "$WORK/glibc-2.26-193" ] || {
    mkdir -p "$WORK/glibc-src" && tar -C "$WORK/glibc-src" -xf "$WORK/dl/glibc-2.26-193.tar.gz"
    mv "$WORK/glibc-src/glibc-glibc-2.26-193-ga0bc5dd3bed4b04814047265b3bcead7ab973b87" "$WORK/glibc-2.26-193"
}
[ -d "$WORK/linux-4.4-headers" ] || {
    mkdir -p "$WORK/linux-4.4.302" && tar -C "$WORK" -xf "$WORK/dl/linux-4.4.302.tar.xz"
    (cd "$WORK/linux-4.4.302" && make ARCH=arm headers_install INSTALL_HDR_PATH="$WORK/linux-4.4-headers" >/dev/null)
}

TC=$WORK/dl/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabi/bin
export PATH=$TC:$PATH CC=arm-linux-gnueabi-gcc AR=arm-linux-gnueabi-ar
export RANLIB=arm-linux-gnueabi-ranlib AS=arm-linux-gnueabi-as
export LD=arm-linux-gnueabi-ld OBJCOPY=arm-linux-gnueabi-objcopy
export STRIP=arm-linux-gnueabi-strip

mkdir -p "$WORK/glibc-build" "$WORK/glibc-install"
cd "$WORK/glibc-build"
"$WORK/glibc-2.26-193/configure" \
    --host=arm-linux-gnueabi --build=x86_64-linux-gnu --prefix=/usr \
    --enable-kernel=4.4.0 --with-headers="$WORK/linux-4.4-headers/include" \
    --disable-werror --disable-nls \
    libc_cv_forced_unwind=yes libc_cv_c_cleanup=yes \
    > "$WORK/glibc-configure.log" 2>&1
make -j"$(nproc)" > "$WORK/glibc-build.log" 2>&1
make install DESTDIR="$WORK/glibc-install" > "$WORK/glibc-install.log" 2>&1

mkdir -p "$WORK/runtime-new-lib"
for lib in ld-linux.so.3 libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0; do
    cp "$WORK/glibc-install/usr/lib/$lib" "$WORK/runtime-new-lib/$lib"
    arm-linux-gnueabi-strip --strip-debug "$WORK/runtime-new-lib/$lib"
done
echo "rebuilt libraries:"
ls -l "$WORK/runtime-new-lib"
"$TC/arm-linux-gnueabi-readelf" -n "$WORK/runtime-new-lib/libc.so.6" | grep -A2 'NT_GNU_ABI_TAG' || true

# Repack: start from the committed vendor tarball, swap the five libraries,
# swap in the patched ns-run.c, regenerate SHA256SUMS.
rm -rf "$WORK/repack" && mkdir -p "$WORK/repack"
tar -C "$WORK/repack" -xzf "$REPO/openwrt/zte-mesh/zte-mesh-runtime.tar.gz"
for p in "$LEGACY"/patches/*.diff; do
    patch -p1 --batch -d "$WORK/repack" < "$p" || { echo "patch failed: $p" >&2; exit 1; }
done
python3 "$REPO/openwrt/repack-runtime.py" --archive "$REPO/openwrt/zte-mesh/zte-mesh-runtime.tar.gz" \
    --output "$WORK/zte-mesh-runtime-legacy.tar.gz" \
    --replace root/lib/ld-linux.so.3="$WORK/runtime-new-lib/ld-linux.so.3" \
    --replace root/lib/libc.so.6="$WORK/runtime-new-lib/libc.so.6" \
    --replace root/lib/libdl.so.2="$WORK/runtime-new-lib/libdl.so.2" \
    --replace root/lib/libm.so.6="$WORK/runtime-new-lib/libm.so.6" \
    --replace root/lib/libpthread.so.0="$WORK/runtime-new-lib/libpthread.so.0" \
    --replace ns-run.c="$WORK/repack/ns-run.c"
echo "legacy tarball: $WORK/zte-mesh-runtime-legacy.tar.gz"
sha256sum "$WORK/zte-mesh-runtime-legacy.tar.gz"
