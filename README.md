# harmony-next-pipeline-docker

HarmonyOS / OpenHarmony 应用 CI 构建镜像,内置:

- HarmonyOS CLI 工具(command-line-tools 6.1.1.280,含 hvigorw、ohpm、hdc)
- **OHOS 自带 LLVM clang + ld.lld**(已加进 PATH,供 Rust/C++ 交叉编译 link)
- JDK 17
- **Qt for OpenHarmony**(5.15.17,x86_64 与 arm64-v8a 两个架构)
- **Rust 工具链**(nightly-2025-12-11 + OHOS target 预装,供 cxx-qt/corrosion 交叉编译)
- curl / zstd / zip / python3 / build-essential / pkg-config 等 CI 常用工具

镜像发布到 GitHub Container Registry,公开可见:

```
ghcr.io/wanywhn/harmony-next-pipeline-docker/harmonyos-ci-image:<tag>
```

> 本仓库 fork 自 [ohosvscode/harmony-next-pipeline-docker](https://github.com/ohosvscode/harmony-next-pipeline-docker),
> 在上游基础上叠加 Qt、Rust 及镜像版本烙印。

## Qt 约定路径

两种架构的 Qt 统一安装到镜像内固定路径,作为单一信息源:

| 架构 | 路径 | 对应 CMake 变量 |
|---|---|---|
| x86_64 | `/opt/qt/x86_64` | `QT_PREFIX_X86` |
| arm64-v8a | `/opt/qt/arm64-v8a` | `QT_PREFIX_AARCH64` |

下游项目(如 [Anything](https://github.com/wanywhn/Anything))的 `entry/build-profile.json5` 里 `QT_PREFIX_*` 应指向这两个路径,本地原生构建则把本机 Qt 软链到 `/opt/qt/...` 即可,无需改 build-profile。

镜像内同时导出了环境变量 `QT_PREFIX_X86` / `QT_PREFIX_AARCH64`,供脚本读取。

## Qt 下载信息(明文存仓库,便于 AI 维护)

Qt 二进制包的下载地址与 SHA256 存放在仓库根的 [`qt-versions.env`](./qt-versions.env),**明文、进 git**,无需配 secret。Dockerfile 构建时 `COPY` 并 `source` 该文件。

升级 Qt 版本时,**只改 `qt-versions.env` 一个文件**,Dockerfile 和 workflow 都不用动。`qt-versions.env` 的 git 历史就是 Qt 版本变迁记录。

文件格式:

```sh
QT_VERSION="5.15.17_OHOS18"            # 可读标识,用于构建日志
QT_X86_URL="<下载链接>"                  # x86_64 包
QT_X86_SHA256="<sha256sum 输出>"         # x86_64 校验值
QT_ARM64_URL="<下载链接>"                # arm64-v8a 包
QT_ARM64_SHA256="<sha256sum 输出>"       # arm64-v8a 校验值
```

> 当值仍为占位符 `<填入...>` 时,Dockerfile 会跳过 Qt 下载。所以**填值前构建出的镜像不含 Qt**,仅用于验证 Dockerfile 其余部分;填值后才产出含 Qt 的生产镜像。

获取 SHA256:

```bash
sha256sum ubuntu-22.04-output-qt5.15.17-x86-64-18-release.zip
sha256sum ubuntu-22.04-output-qt5.15.17-arm64-v8a-18-release.zip
```

## Rust 工具链

镜像预装 `nightly-2025-12-11`(由下游 submodule `cardinal-qt` 的 `rust-toolchain.toml` 钉死)+ 两个 OHOS target:

- `aarch64-unknown-linux-ohos`(arm64-v8a)
- `x86_64-unknown-linux-ohos`(x86_64)

外加 `rustfmt`、`clippy` components。

> corrosion(cxx-qt 调用的)对未安装的 target 会 `FATAL_ERROR`、不自动装,所以 target 必须烤进镜像,不能靠运行时拉。

## OHOS clang / linker

镜像把 OHOS 自带的 LLVM(`$OHOS_LLVM_HOME/bin`,含 `ld.lld`)加进了 PATH。这样 cargo 调 OHOS clang 交叉 link OHOS target 时,clang 优先用 `ld.lld` 而非系统的 `ld.gold`,避免 `unsupported ELF machine number 183`(gold 不认 arm64)。

## 换 Qt 版本的标准操作流程

1. **改 `qt-versions.env`**:更新 `QT_VERSION`、两个 URL、两个 SHA256。
2. **提交**:`git commit -am "升级 Qt 至 5.15.18"`。
   - 提交到 main 只构建验证 Dockerfile,**不会自动推 `:latest`**(上游 workflow 设计:避免误覆盖)。
3. **打 git tag**(产出可消费的镜像):
   ```bash
   git tag qt5.15.18-ohos18-1   # tag 名要能看出 Qt 版本
   git push origin main qt5.15.18-ohos18-1
   ```
   push tag 会产出钉死版本镜像 `:qt5.15.18-ohos18-1`。
   - 想刷新 `:latest`?去 Actions 页面 **Run workflow**(`workflow_dispatch`)手动触发。
4. **下游升级**:在 Anything 等下游项目改 `container:` 引用的 tag 名。

### 标注镜像差异(镜像自查)

镜像构建时会把 git ref 名(tag 触发时即 tag 名,否则是分支名)通过 `IMAGE_TAG` 烙进镜像。容器内自查:

```bash
cat /opt/image-tag          # 如:qt5.15.17-ohos18-5
echo $IMAGE_TAG             # 同上,环境变量形式
```

排查"这台 CI 跑的是哪个 Qt"时直接 `cat /opt/image-tag` 即可。

## 下游项目引用

下游项目的 workflow 用 `container:` 引用本镜像:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container: ghcr.io/wanywhn/harmony-next-pipeline-docker/harmonyos-ci-image:qt5.15.17-ohos18-5
```

**建议钉具体 tag 而非 `:latest`**,避免镜像更新导致下游 CI 行为飘移、且便于回滚。升级 Qt 时:镜像仓库改 `qt-versions.env` + 打新 tag → 下游改引用的 tag 名即可。

## 本地构建镜像

```bash
# 直接构建(读仓库内 qt-versions.env;值未填时跳过 Qt)
docker build -t harmonyos-ci-image:test .

# 烙本地版本标识
docker build --build-arg IMAGE_TAG=local -t harmonyos-ci-image:test .
```

构建后验证:

```bash
docker run --rm harmonyos-ci-image:test ls /opt/qt/x86_64
docker run --rm harmonyos-ci-image:test rustc --version
docker run --rm harmonyos-ci-image:test cat /opt/image-tag
```
