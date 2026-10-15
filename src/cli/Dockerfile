FROM public.ecr.aws/lambda/provided:al2023

ENV X86_64_ROOT="/" \
    AARCH64_ROOT="/aarch64-root"

RUN mkdir -p /build && cd /build && \
    crystal_deps='libunwind gc-devel gmp-devel libbsd-devel libevent-devel libxml2-devel libyaml-devel llvm-devel openssl-devel pcre2-devel' && \
    # Dump list of libs available by default in lambda
    ls -1 /lib64/ | sort -u > default_libs && \
    # Install necessary packages on base container
    dnf install -y git zip tar xz make autoconf automake libtool python3-dnf $crystal_deps && \
    # Replace microdnf with dnf
    dnf download dnf && \
    rpm -i dnf-*.rpm --force --nodeps && \
    rm dnf-*.rpm && \
    # Install crystal for current root
    curl -fsSL https://crystal-lang.org/install.sh | DISTRO_REPO=Fedora_Rawhide bash && \
    # Initialize root for aarch64
    releasever="$(rpm -q --qf '%{VERSION}' system-release)" && \
    dnf -y install --releasever="$releasever" --forcearch=aarch64 --installroot=$AARCH64_ROOT basesystem && \
    dnf -y install --releasever="$releasever" --forcearch=aarch64 --installroot=$AARCH64_ROOT --setopt=tsflags=noscripts $crystal_deps && \
    # Install zig to link the cross compiled object into an executable
    latest_zig_release="$(curl -SsL https://api.github.com/repos/ziglang/zig/releases/latest | sed -nE 's/.*"tag_name"\s*:\s*"([^"]*)".*/\1/p')" && \
    curl -L https://ziglang.org/download/$latest_zig_release/zig-x86_64-linux-$latest_zig_release.tar.xz | tar xJf - && \
    mv zig* zig && \
    # bdwgc at the version crystal's release scripts pin, built for zig's baseline glibc (older than al2023's)
    gc_version="$(curl -fsSL https://raw.githubusercontent.com/crystal-lang/distribution-scripts/master/linux/Makefile | sed -nE 's/^GC_VERSION = (.*)/\1/p')" && \
    git clone --depth 1 --branch "$gc_version" https://github.com/ivmai/bdwgc && \
    (cd bdwgc && ./autogen.sh) && \
    for root in x86_64:/usr/lib64/crystal aarch64:$AARCH64_ROOT/usr/lib64; do \
      arch="${root%%:*}" && mkdir "gc-$arch" && cd "gc-$arch" && \
      ../bdwgc/configure --host="$arch-linux-gnu" --disable-debug --disable-shared --enable-large-config \
        --with-libatomic-ops=none CC="/build/zig/zig cc -target $arch-linux-gnu" AR="/build/zig/zig ar" \
        RANLIB="/build/zig/zig ranlib" CFLAGS="-fPIC -O2" && \
      make -j"$(nproc)" && cp .libs/libgc.a "${root#*:}/libgc.a" && cd .. || exit 1; \
    done && \
    cp /usr/lib64/crystal/libgc.a /usr/lib64/libgc.a && \
    rm -rf bdwgc gc-* /usr/lib64/libgc.so* $AARCH64_ROOT/usr/lib64/libgc.so*
