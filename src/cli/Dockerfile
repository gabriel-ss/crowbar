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
    curl -fsSL https://crystal-lang.org/install.sh | bash && \
    # Initialize root for aarch64
    dnf -y install --forcearch=aarch64 --installroot=$AARCH64_ROOT basesystem && \
    dnf -y install --forcearch=aarch64 --installroot=$AARCH64_ROOT --setopt=tsflags=noscripts $crystal_deps && \
    # Install zig to link the cross compiled object into an executable
    latest_zig_release="$(curl -SsL https://api.github.com/repos/ziglang/zig/releases/latest | sed -nE 's/.*"tag_name"\s*:\s*"([^"]*)".*/\1/p')" && \
    curl -L https://ziglang.org/download/$latest_zig_release/zig-linux-x86_64-$latest_zig_release.tar.xz | tar xJf - && \
    mv zig* zig
