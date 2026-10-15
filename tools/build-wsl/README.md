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

### 使用方法

```sh
# 安装 app 编译依赖（gcc、make、cmake、git 等）
sudo ./centos7.9-app-deps.run

# 安装 drv 编译依赖（kernel-devel、kernel-headers）
sudo ./centos7.9-drv-deps.run
```

> CentOS 7.9 安装 app 依赖后会自动配置 devtoolset-9 (GCC 9)，新会话自动激活，当前会话需执行 `source /opt/rh/devtoolset-9/enable`。

### 本地构建 .run 包

构建相关文件位于 [run/](./run/) 目录：

```
run/
├── docker-build.sh                # Docker 编排入口（推荐）
├── build.sh                       # 打包脚本（容器内执行）
├── config/                        # 各发行版包列表配置
├── installers/                    # 安装脚本模板
└── Dockerfile.*                   # 构建环境 Dockerfile
```

#### 方式一：Docker 构建（推荐）

使用 `docker-build.sh` 一键完成镜像构建 + 打包，`.all` 镜像已预装依赖，打包速度快：

```sh
cd run/

# 构建单个发行版（自动构建基础镜像 → .all 镜像 → 打包 .run）
./docker-build.sh centos7.9
./docker-build.sh centos8.5
./docker-build.sh ubuntu20.04

# 并行构建全部发行版
./docker-build.sh centos7.9 &
./docker-build.sh centos8.5 &
./docker-build.sh ubuntu20.04 &
wait
```

产物输出到 `run/output/` 目录。

#### 方式二：手动构建

```sh
cd run/

# 1. 构建基础镜像（配源）
docker build -t semp-centos7 -f ../docker/Dockerfile.centos7.9 ../docker/

# 2. 构建 .all 镜像（预装编译依赖）
docker build -t semp-centos7.all -f ../docker/Dockerfile.centos7.9.all ../docker/

# 3. 在容器内打包 .run
docker run --rm -v "$(pwd):$(pwd)" -w "$(pwd)" \
    semp-centos7.all bash ./build.sh config/centos7.9.conf
```