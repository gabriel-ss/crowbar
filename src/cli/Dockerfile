FROM public.ecr.aws/lambda/provided:al2023

ENV X86_64_ROOT="/" \
    AARCH64_ROOT="/aarch64-root"

RUN mkdir -p /build && cd /build && \
    crystal_deps='libunwind gc-devel gmp-devel libbsd-devel libevent-devel libxml2-devel libyaml-devel llvm-devel openssl-devel pcre2-devel' && \
    # Dump list of libs available by default in lambda
    ls -1 /lib64/ | sort -u > default_libs && \
    # Install necessary packages on base container
    dnf install -y git zip tar xz python3-dnf $crystal_deps && \
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
    # Crystal's threaded runtime needs specific symbols from bdwgc. Ship the static
    # libgc bundled in crystal's own releases instead of the distro one, and drop
    # the stale shared objects so that -lgc can't resolve back to them.
    crystal_version="$(crystal --version | sed -nE 's/^Crystal ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')" && \
    crystal_aarch64_url="$(curl -SsL https://api.github.com/repos/crystal-lang/crystal/releases/tags/$crystal_version | sed -nE 's/.*"(https:[^"]*linux-aarch64\.tar\.gz)".*/\1/p' | head -n1)" && \
    rm -f /usr/lib64/libgc.so* $AARCH64_ROOT/usr/lib64/libgc.so* && \
    cp /usr/lib64/crystal/libgc.a /usr/lib64/libgc.a && \
    curl -fL "$crystal_aarch64_url" | \
      tar xzf - -C $AARCH64_ROOT/usr/lib64 --strip-components=3 --wildcards '*/lib/crystal/libgc.a' && \
    # Install zig to link the cross compiled object into an executable
    latest_zig_release="$(curl -SsL https://api.github.com/repos/ziglang/zig/releases/latest | sed -nE 's/.*"tag_name"\s*:\s*"([^"]*)".*/\1/p')" && \
    curl -L https://ziglang.org/download/$latest_zig_release/zig-x86_64-linux-$latest_zig_release.tar.xz | tar xJf - && \
    mv zig* zig
