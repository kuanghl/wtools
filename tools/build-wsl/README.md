# 系统环境构建

## docker 构建和使用

- [docker 构建和使用参考](./docker/README.md)
- [build centos7.9 docker images](./docker/Dockerfile.centos7.9)
- [build centos8.5 docker images](./docker/Dockerfile.centos8.5)
- [build ubuntu20.04 docker images](./docker/Dockerfile.ubuntu20.04)

## wsl 构建和使用

- [build centos7.9 wsl rootfs](./build-wsl-centos7.9.sh)
- [build centos8.5 wsl rootfs](./build-wsl-centos8.5.sh)
- [build centos20.04 wsl rootfs](./build-wsl-ubuntu20.04.sh)

```sh
# 下载.zip包
# 双击 .\CentOS7.exe 即可部署完毕wsl
wsl -d CentOS7              # 启动wsl
wsl --terminate CentOS7     # 停止wsl
.\CentOS7.exe clean         # 清理wsl
```

## 离线编译依赖 (.run 包)

每个系统提供两个离线 `.run` 安装包，无需联网即可安装全部编译依赖：

| 系统 | app 编译依赖 | drv 编译依赖 |
|------|-------------|-------------|
| CentOS 7.9 | `centos7.9-app-deps.run` | `centos7.9-drv-deps.run` |
| CentOS 8.5 | `centos8.5-app-deps.run` | `centos8.5-drv-deps.run` |
| Ubuntu 20.04 | `ubuntu20.04-app-deps.run` | `ubuntu20.04-drv-deps.run` |

### 离线包安装和卸载机制

#### .run 包内部结构

`.run` 是一个自解压脚本，由 shell header + tar.gz payload 拼接而成。运行后解压到临时目录，包含以下文件：

```
install.sh          # 安装/卸载/列表入口脚本
packages/           # 所有离线包文件（.rpm 或 .deb），含顶层包及其递归依赖
packages.list       # 仅顶层包名列表（来自 conf 中的 APP_PACKAGES / DRV_PACKAGES）
extra/*.tar.gz      # 可选，需从二进制解压的组件（如 CMake）
```

#### 安装（install）

1. 将当前系统已安装的包快照写入 `STATE_FILE`（`/var/lib/<distro>-<type>-deps-pre-install.list`）
2. 逐个比较 `packages/` 中每个包与系统已安装版本（`sort -V`）：
   - 未安装或离线包版本更新 → 安装
   - 已安装版本相同或更新 → 跳过
   - 使用 `--force` 时跳过比较，强制安装所有包（rpm 使用 `--nodeps --force`，deb 使用 `dpkg -i`）
3. 执行 `post_install` 收尾：
   - CentOS 7.9 app：将 `source /opt/rh/devtoolset-9/enable` 写入 `/etc/bashrc`，新会话自动激活
   - CentOS app：解压 `extra/cmake.tar.gz` 到 `/` 并创建 `/usr/bin/cmake` 等符号链接

#### 卸载（uninstall）

卸载的核心思路是**只移除本次安装新增的包，不动系统原有的包**：

1. 读取 `packages.list` 获取顶层包名（不含递归拉入的依赖）
2. 与 `STATE_FILE` 做差集（`comm -23`），筛出安装前不存在的包
3. 用包管理器移除差集中的包（`yum remove` / `apt-get purge`）
4. 执行 `autoremove` 清理因本次安装而拉入的孤立依赖
5. CentOS 7.9 app 额外清理 `extra/` 解压的文件和 cmake 符号链接

> `packages.list` 仅包含 conf 中显式声明的顶层包名，不包含 `download_packages` 递归解析出的依赖。这确保卸载时由包管理器自行处理依赖关系，避免误删系统原有组件。

### 构建离线包

```sh
cd run/

# 脚本构建
# 构建单个发行版（自动构建基础镜像 → .all 镜像 → 打包 .run）
# Dockfile 更新时
./docker-build.sh centos7.9 --force
./docker-build.sh centos8.5 --force
./docker-build.sh ubuntu20.04 --force

# Dockfile 无更新时，使用缓存
./docker-build.sh centos7.9
./docker-build.sh centos8.5
./docker-build.sh ubuntu20.04

# 并行构建全部发行版
./docker-build.sh centos7.9 &
./docker-build.sh centos8.5 &
./docker-build.sh ubuntu20.04 &
wait

# 单步构建，以 centos7.9 为例
docker build -t semp-centos7 -f ../docker/Dockerfile.centos7.9 ../docker/
docker build -t semp-centos7.all -f ../docker/Dockerfile.centos7.9.all ../docker/
docker run --rm -v "$(pwd):$(pwd)" -w "$(pwd)" \
    semp-centos7.all bash ./build.sh config/centos7.9.conf
```

### 离线包使用

```sh
# 以 centos8.5 为例
./centos8.5-app-deps.run -h
sudo ./centos8.5-app-deps.run list
sudo ./centos8.5-app-deps.run install          # 智能安装：跳过已有相同或更新版本的包
sudo ./centos8.5-app-deps.run install --force  # 强制安装所有包，覆盖已有版本
sudo ./centos8.5-app-deps.run --force          # 等同于 install --force
sudo ./centos8.5-app-deps.run uninstall
```

> **CentOS 7.9** 安装 app 依赖后会自动配置 devtoolset-9 (GCC 9)，新会话自动激活，当前会话需执行 `source /opt/rh/devtoolset-9/enable`。