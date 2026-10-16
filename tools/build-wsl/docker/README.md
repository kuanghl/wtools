# 编译依赖环境

## docker 构建和使用

1. docker 构建

```sh
# docker 使用国内镜像源
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.1panel.dev",
    "https://docker.fxxk.dedyn.io",
    "https://docker.m.daocloud.io",
    "https://docker.zhai.cm",
    "https://docker.1panel.live",
    "https://hub.rat.dev",
    "https://mirror.iscas.ac.cn",
    "https://docker.1ms.run",
    "https://docker.jiaxin.site"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker

# 构建系统
cd 3rd/deps_run

# 纯净系统
docker build -f Dockerfile.centos7.9 -t semp-centos7 .
docker build -f Dockerfile.centos8.5 -t semp-centos8.5 .
docker build -f Dockerfile.ubuntu20.04 -t semp-ubuntu20.04 .

# 拥有完整依赖的系统
docker build -f Dockerfile.centos7.9.all -t semp-centos7-all .
docker build -f Dockerfile.centos8.5.all -t semp-centos8.5-all .
docker build -f Dockerfile.ubuntu20.04.all -t semp-ubuntu20.04-all .

# 验证 yum 源可用
docker run --rm semp-centos7 yum list installed
docker run --rm semp-centos8.5 yum list installed
docker run --rm semp-ubuntu20.04 apt-cache policy
注意：CentOS 8 已 EOL，如需后续安装依赖可能需要切换到 vault 镜像源
```

2. docker 测试编译

```sh
# 挂载项目 --> 安装依赖 --> 编译验证

# CentOS 7:
docker run --rm -it \
    -v /home1/khl/kuanghl-workspace/sempICP:/workspace \
    -w /workspace \
    semp-centos7 /bin/bash

# CentOS 8.5:
docker run --rm -it \
    -v /home1/khl/kuanghl-workspace/sempICP:/workspace \
    -w /workspace \
    semp-centos8.5 /bin/bash

# Ubuntu 20.04:
docker run --rm -it \
    -v /home1/khl/kuanghl-workspace/sempICP:/workspace \
    -w /workspace \
    semp-ubuntu20.04 /bin/bash

# 应用程序依赖，docker即可编译测试
# CentOS 7:
yum install -y make git \
    readline-devel libpcap-devel libaio-devel zlib-devel diffutils 
yum install -y devtoolset-9-gcc devtoolset-9-gcc-c++
source /opt/rh/devtoolset-9/enable
echo "source /opt/rh/devtoolset-9/enable" >> /etc/bashrc

# CentOS 8:
yum install -y gcc gcc-c++ make cmake git \
    readline-devel libpcap-devel libaio-devel zlib-devel diffutils

# Ubuntu 20.04:
apt-get update
apt-get install -y build-essential gcc make cmake git \
    libreadline-dev libpcap-dev libaio-dev zlib1g-dev diffutils

# 应用程序编译
./build.sh app

# 驱动编译示例
# 如果需要编译驱动（仅 x86_64，需要内核头文件）：
docker run --rm -it \
    -v /home1/khl/kuanghl-workspace/sempICP:/workspace \
    -v /usr/src:/usr/src:ro \
    -v /lib/modules:/lib/modules:ro \
    -w /workspace \
    semp-centos7 /bin/bash

# 驱动编译依赖，编译平台依赖虚拟机，因为涉及内核编译
# docker 中 uname -r 会默认使用宿主机的，所以不对，需要使用以下方式匹配一个最新的版本
# CentOS 7: 
# yum list --showduplicates kernel-devel
# yum list --showduplicates kernel-headers
# rpm -ql kernel-devel | head -20
# yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
yum install -y kernel-devel kernel-headers

# CentOS 8:
# yum list --showduplicates kernel-devel
# yum list --showduplicates kernel-headers
# rpm -ql kernel-devel | head -20
# yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
yum install -y kernel-devel kernel-headers

# Ubuntu 20.04:
# apt-cache search linux-headers- |grep "generic"
# ls /usr/src/
# apt install -y linux-headers-$(uname -r) build-essential
apt install -y linux-headers-generic build-essential

# CentOS 7/8，如果内核版本较旧，可能需要先更新
# sudo yum update -y kernel
# sudo reboot
# sudo yum install -y kernel-devel-$(uname -r)
```