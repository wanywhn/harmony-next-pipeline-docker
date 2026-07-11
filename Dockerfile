# 使用 Ubuntu 22.04 作为基础镜像
# Qt for OpenHarmony 在 22.04 上编译,需要 GLIBC_2.33/2.34 与 GLIBCXX_3.4.29,
# 20.04 的 glibc/libstdc++ 太老会报 "version not found",故基础镜像必须 >= 22.04。
FROM ubuntu:22.04

# 设置环境变量以避免交互式安装提示
ENV DEBIAN_FRONTEND=noninteractive

# 安装必要的工具
# curl: 部分构建脚本（如 prepare_ohos_sqlite_provider.sh 下载 SQLite amalgamation）依赖它，缺失会 exit 127。
# zstd: GitHub Actions 的 actions/cache 条目指纹包含压缩工具；ubuntu runner 保存的是 zstd 压缩，
#       容器里没有 zstd 时同 key 也会永远 miss（gzip-only 客户端），且不报错。
# build-essential: 提供 cc/gcc/g++/make/ld,Rust host target(编译 build script 如 proc-macro2/quote)
#       的默认 linker 是 `cc`,交叉编译时 host 仍需系统 cc,否则报 "linker `cc` not found"。
# pkg-config: 许多 Rust build script 通过它定位系统库。
RUN apt-get update && \
    apt-get install -y \
        wget \
        curl \
        zstd \
        zip \
        unzip \
        python3 \
        openjdk-17-jdk \
        build-essential \
        pkg-config \
        git \
        && rm -rf /var/lib/apt/lists/*

# 设置 JDK 17 环境变量
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# 下载并安装 HarmonyOS CLI 工具
RUN mkdir -p /opt/harmonyos-tools && \
    wget -q -O /tmp/commandline-tools-linux.zip https://image.cdn.dog/commandline-tools-linux-x64-6.1.1.280.zip && \
    echo "b9caf7b73c541b90e6c8f3c7c3de7f2bea9b35e41e80cd3525f2f759ebf16cf4  /tmp/commandline-tools-linux.zip" | sha256sum -c - || { echo "ERROR: SHA256 checksum verification failed for HarmonyOS CLI tools"; exit 1; } && \
    unzip -q /tmp/commandline-tools-linux.zip -d /opt/harmonyos-tools/ && \
    chmod -R +x /opt/harmonyos-tools/command-line-tools/bin && \
    chmod -R +x /opt/harmonyos-tools/command-line-tools/sdk/default/openharmony/native/llvm/bin && \
    rm /tmp/commandline-tools-linux.zip

# 设置 HarmonyOS CLI 工具的环境变量
# OHOS_LLVM_HOME/PATH: 把 OHOS 自带 llvm bin(含 ld.lld)加进 PATH,
#   这样 cargo 调 OHOS clang link OHOS target 时,clang 会优先用 ld.lld 而非系统的 ld.gold,
#   避免 "unsupported ELF machine number 183"(gold 不认 arm64)。
ENV COMMANDLINE_TOOL_DIR=/opt/harmonyos-tools
ENV PATH=$COMMANDLINE_TOOL_DIR/command-line-tools/bin:$PATH
ENV HDC_HOME=$COMMANDLINE_TOOL_DIR/command-line-tools/sdk/default/openharmony/toolchains
ENV PATH=$HDC_HOME:$PATH
ENV OHOS_BASE_SDK_HOME=$COMMANDLINE_TOOL_DIR/command-line-tools/sdk/default/openharmony
ENV OHOS_LLVM_HOME=$OHOS_BASE_SDK_HOME/native/llvm
ENV PATH=$OHOS_LLVM_HOME/bin:$PATH

# ============================================================================
# Qt for OpenHarmony 构建环境
# ============================================================================
# 约定路径:两种架构的 Qt 统一安装到 /opt/qt/{x86_64,arm64-v8a}
# Anything 项目的 entry/build-profile.json5 里 QT_PREFIX_X86 / QT_PREFIX_AARCH64
# 指向这两个固定路径,本地原生构建用 scripts/setup-qt-symlinks.sh 软链到此处。
#
# 下载地址与 SHA256 存放在仓库根的 qt-versions.env(明文,便于 AI 维护),
# 升级 Qt 版本时只改那个文件,本段逻辑无需改动。
COPY qt-versions.env /tmp/qt-versions.env
RUN set -a && . /tmp/qt-versions.env && set +a && \
    mkdir -p /opt/qt/x86_64 /opt/qt/arm64-v8a && \
    # 包结构两层压缩:外层 zip → 内层 .tar.gz → bin/ lib/ ...(无顶层包装目录)
    # install_qt <arch> <url> <sha256> <dest>
    install_qt() { \
      arch="$1"; url="$2"; sha="$3"; dest="$4"; \
      echo "Installing Qt $arch ($QT_VERSION) ..." && \
      wget -q -O /tmp/qt-$arch.zip "$url" && \
      echo "$sha  /tmp/qt-$arch.zip" | sha256sum -c - || { echo "ERROR: SHA256 mismatch for Qt $arch"; exit 1; } && \
      unzip -q /tmp/qt-$arch.zip -d /tmp/qt-$arch && \
      inner_tar=$(find /tmp/qt-$arch -name '*.tar.gz' | head -1) && \
      mkdir -p "$dest" && tar -xzf "$inner_tar" -C "$dest" && \
      rm -rf /tmp/qt-$arch /tmp/qt-$arch.zip ; \
    } && \
    # --- x86_64 ---
    if [ -n "$QT_X86_URL" ] && ! echo "$QT_X86_URL" | grep -q '<填入'; then \
      install_qt x86_64 "$QT_X86_URL" "$QT_X86_SHA256" /opt/qt/x86_64 ; \
    else \
      echo "Skipping Qt x86_64: QT_X86_URL not configured in qt-versions.env" ; \
    fi && \
    # --- arm64-v8a ---
    if [ -n "$QT_ARM64_URL" ] && ! echo "$QT_ARM64_URL" | grep -q '<填入'; then \
      install_qt arm64-v8a "$QT_ARM64_URL" "$QT_ARM64_SHA256" /opt/qt/arm64-v8a ; \
    else \
      echo "Skipping Qt arm64-v8a: QT_ARM64_URL not configured in qt-versions.env" ; \
    fi && \
    rm -f /tmp/qt-versions.env

ENV QT_PREFIX_X86=/opt/qt/x86_64
ENV QT_PREFIX_AARCH64=/opt/qt/arm64-v8a
# 把 Qt x86_64 的 bin 加进 PATH:lupdate/lrelease 是 host 工具(编译期跑,生成/编译 .ts→.qm),
# CMake 的 find_program 在 PATH 里找它们,不加 PATH 会 "Could not find LUPDATE_EXECUTABLE"。
# host 是 x86_64 Linux,故用 x86_64 那套 Qt 的 bin 即可,arm64-v8a 那套的 bin 不需要进 PATH。
ENV PATH=/opt/qt/x86_64/bin:$PATH

# ============================================================================
# Rust 工具链(rustup + 预装 OHOS target)
# ============================================================================
# cxx-qt 通过 corrosion 调 cargo 交叉编译 Rust crate 到 OHOS target。
# corrosion 对未安装的 target 会 FATAL_ERROR(不自动装),故必须预装:
#   - nightly-2025-12-11(submodule 的 rust-toolchain.toml 钉的版本)
#   - aarch64-unknown-linux-ohos / x86_64-unknown-linux-ohos(OHOS 交叉编译 target)
# components 也按 rust-toolchain.toml 预装(rustfmt, clippy),免得 CI 运行时拉。
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=$CARGO_HOME/bin:$PATH
RUN wget -q -O /tmp/rustup-init.sh https://sh.rustup.rs && \
    sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain nightly-2025-12-11 \
        --component rustfmt --component clippy --no-modify-path && \
    rustup target add --toolchain nightly-2025-12-11 \
        aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos && \
    rm /tmp/rustup-init.sh

# ============================================================================
# 镜像版本烙印:构建时通过 IMAGE_TAG 传入(git ref 名,如 qt5.15.17-ohos18-5)
# 容器内 cat /opt/image-tag 可查本镜像由哪次构建产出,用于排查 Qt 版本差异。
# ============================================================================
ARG IMAGE_TAG=unknown
ENV IMAGE_TAG=$IMAGE_TAG
RUN echo "$IMAGE_TAG" > /opt/image-tag

# 设置工作目录
WORKDIR /workspace

# 设置默认命令
CMD ["bash"]
