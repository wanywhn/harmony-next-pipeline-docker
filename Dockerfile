# 使用 Ubuntu 22.04 作为基础镜像
# Qt for OpenHarmony 在 22.04 上编译,需要 GLIBC_2.33/2.34 与 GLIBCXX_3.4.29,
# 20.04 的 glibc/libstdc++ 太老会报 "version not found",故基础镜像必须 >= 22.04。
FROM ubuntu:22.04

# 设置环境变量以避免交互式安装提示
ENV DEBIAN_FRONTEND=noninteractive

# 安装必要的工具
RUN apt-get update && \
    apt-get install -y \
        wget \
        unzip \
        openjdk-17-jdk \
        git \
        && rm -rf /var/lib/apt/lists/*

# 设置 JDK 17 环境变量
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# 下载并安装 HarmonyOS CLI 工具
RUN mkdir -p /opt/harmonyos-tools && \
    wget -q -O /tmp/commandline-tools-linux.zip https://image.cdn.dog/commandline-tools-linux-x64-6.0.2.642.zip && \
    echo "181d283be91392e0a5dc09caf5ebda34c778cccc9985d8a97a814808452e2471  /tmp/commandline-tools-linux.zip" | sha256sum -c - || { echo "ERROR: SHA256 checksum verification failed for HarmonyOS CLI tools"; exit 1; } && \
    unzip -q /tmp/commandline-tools-linux.zip -d /opt/harmonyos-tools/ && \
    chmod -R +x /opt/harmonyos-tools/command-line-tools/bin && \
    rm /tmp/commandline-tools-linux.zip

# 设置 HarmonyOS CLI 工具的环境变量
ENV COMMANDLINE_TOOL_DIR=/opt/harmonyos-tools
ENV PATH=$COMMANDLINE_TOOL_DIR/command-line-tools/bin:$PATH
ENV HDC_HOME=$COMMANDLINE_TOOL_DIR/command-line-tools/sdk/default/openharmony/toolchains
ENV PATH=$HDC_HOME:$PATH
ENV OHOS_BASE_SDK_HOME=$COMMANDLINE_TOOL_DIR/command-line-tools/sdk/default/openharmony

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
      # 外层 zip 解压出内层 .tar.gz
      unzip -q /tmp/qt-$arch.zip -d /tmp/qt-$arch && \
      inner_tar=$(find /tmp/qt-$arch -name '*.tar.gz' | head -1) && \
      # 内层 tar.gz 解压到目标目录(无 --strip,因 tar 内是 ./bin ./lib ...)
      mkdir -p "$dest" && tar -xzf "$inner_tar" -C "$dest" && \
      rm -rf /tmp/qt-$arch /tmp/qt-$arch.zip ; \
    } && \
    # --- x86_64 ---(URL 为占位符 <填入...> 时跳过,便于填值前先验证镜像其余部分)
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

# ============================================================================
# 镜像版本烙印:构建时通过 IMAGE_TAG 传入(git ref 名,如 qt5.15.12-ohos18-1)
# 容器内 cat /opt/image-tag 可查本镜像由哪次构建产出,用于排查 Qt 版本差异。
# ============================================================================
ARG IMAGE_TAG=unknown
ENV IMAGE_TAG=$IMAGE_TAG
RUN echo "$IMAGE_TAG" > /opt/image-tag

# 设置工作目录
WORKDIR /workspace

# 设置默认命令
CMD ["bash"]
