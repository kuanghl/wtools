# 基于Docker-VM测试环境

## 在目标系统上打包并制作本地镜像

```sh
# 1. 打包当前系统的根文件系统
sudo ./make_rootfs.sh

# 2. 导入为 Docker 本地镜像
# 假设你把 {OS_STRING}-rootfs.tar 拷到了宿主机当前目录
docker import -c 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
              -c 'WORKDIR /workspace' \
              -c 'CMD ["/bin/bash"]' \
              ./CentOS_Linux-7-minimal-rootfs.tar local-centos:7.9


docker import -c 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
              -c 'WORKDIR /workspace' \
              -c 'CMD ["/bin/bash"]' \
              ./CentOS_Linux-8-minimal-rootfs.tar local-centos:8.5


docker import -c 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
              -c 'WORKDIR /workspace' \
              -c 'CMD ["/bin/bash"]' \
              ./Ubuntu-20.04-minimal-rootfs.tar local-ubuntu:20.04
```

## 构建镜像

```sh
# 1. 构建镜像
docker build -f Dockerfile.centos7.9 -t test-env:centos7.9 .
docker build -f Dockerfile.centos8.5 -t test-env:centos8.5 .
docker build -f Dockerfile.ubuntu20.04 -t test-env:ubuntu20.04 .

# 2. 启动镜像
docker run -it --rm \
  --network none \
  -v ~/:/workspace \
  test-env:centos7.9

docker run -it --rm \
  --network none \
  -v ~/:/workspace \
  test-env:centos8.5

docker run -it --rm \
  --network none \
  -v ~/:/workspace \
  test-env:ubuntu20.04
```

## 在容器内安装离线包并建立软链接

```sh
# 获取当前容器（即宿主机）的内核版本
KVER=$(uname -r)
echo "当前内核版本: $KVER"

# 查看离线包安装的 kernel-devel 路径
ls -d /usr/src/kernels/*
# 输出通常类似：/usr/src/kernels/3.10.0-1160.119.1.0.1.an7.x86_64

# 2. 建立软链接（最关键的一步）
# 设置变量（假设 ls 查看到的版本是 3.10.0-xxx）
DEVEL_VER=$(ls /usr/src/kernels/ | head -n 1)

# 创建目录（如果 /lib/modules 下没这个版本目录的话）
mkdir -p /lib/modules/$KVER

# 强制建立软链接
ln -sf /usr/src/kernels/$DEVEL_VER /lib/modules/$KVER/build

# 验证链接是否成功
ls -l /lib/modules/$KVER/build

# 注意：Ubuntu 系统的 kernel-devel 被称为 linux-headers，通常会自动创建好软链接，你可以直接 ls -l /lib/modules/$(uname -r)/build 检查。如果没有，手动指向上文提到的 /usr/src/linux-headers-xxx。
```