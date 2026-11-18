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
docker build -f Dockerfile.ubuntu24.04 -t semp-ubuntu24.04 .
docker build -f Dockerfile.debian13 -t semp-debian13 .

# 拥有完整依赖的系统
docker build -f Dockerfile.centos7.9.all -t semp-centos7-all .
docker build -f Dockerfile.centos8.5.all -t semp-centos8.5-all .
docker build -f Dockerfile.ubuntu20.04.all -t semp-ubuntu20.04-all .
docker build -f Dockerfile.ubuntu24.04.all -t semp-ubuntu24.04-all .
docker build -f Dockerfile.debian13.all -t semp-debian13-all .

# 验证 yum 源可用
docker run --rm semp-centos7 yum list installed
docker run --rm semp-centos8.5 yum list installed
docker run --rm semp-ubuntu20.04 apt-cache policy
docker run --rm semp-ubuntu24.04 apt-cache policy
docker run --rm semp-debian13 apt-cache policy
注意：CentOS 8 已 EOL，如需后续安装依赖可能需要切换到 vault 镜像源
注意：run 包打包只使用纯净系统镜像（依赖解析需贴近目标机），*.all 镜像仅用于 docker 内直接编译

# ubuntu 基础依赖
sudo apt-get install -y build-essential gcc g++ make cmake git diffutils libreadline-dev libpcap-dev libaio-dev zlib1g-dev vim
sudo apt-get install -y linux-headers-generic libelf-dev libssl-dev bc flex kmod

# debian 13 基础依赖（内核 headers 的 meta 包为 linux-headers-amd64，无 -generic）
sudo apt-get install -y build-essential gcc g++ make cmake git diffutils libreadline-dev libpcap-dev libaio-dev zlib1g-dev vim
sudo apt-get install -y linux-headers-amd64 libelf-dev libssl-dev bc flex kmod
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

# Ubuntu 24.04:
docker run --rm -it \
    -v /home1/khl/kuanghl-workspace/sempICP:/workspace \
    -w /workspace \
    semp-ubuntu24.04 /bin/bash

# Debian 13:
docker run --rm -it \
    -v /home1/khl/kuanghl-workspace/sempICP:/workspace \
    -w /workspace \
    semp-debian13 /bin/bash

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

# Ubuntu 24.04 / Debian 13: 依赖名与 Ubuntu 20.04 一致
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

# Ubuntu 24.04:
# apt-cache search linux-headers- |grep "generic"
# ls /usr/src/
# apt install -y linux-headers-$(uname -r) build-essential
apt install -y linux-headers-generic build-essential

# Debian 13: meta 包名为 linux-headers-amd64；其版本化 headers 包硬依赖同版本的
# linux-image-*，离线 drv 包因此会带上整个内核镜像（约 108MB）
# apt-cache search linux-headers- |grep "amd64"
# ls /usr/src/
# apt install -y linux-headers-$(uname -r) build-essential
apt install -y linux-headers-amd64 build-essential

# CentOS 7/8，如果内核版本较旧，可能需要先更新
# sudo yum update -y kernel
# sudo reboot
# sudo yum install -y kernel-devel-$(uname -r)
```

## VM / 实体机检查依赖

1. Centos7.9

```sh
yum install yum-utils -y

# app 构建依赖
yum install --assumeno make git diffutils curl readline-devel libpcap-devel libaio-devel zlib-devel \
  devtoolset-9-gcc devtoolset-9-gcc-c++ 2>/dev/null \
  | awk '/^Installing/{f=1} /^Transaction Summary/{f=0} f' \
  | grep -E ' (x86_64|noarch|i686) ' \
  | awk '{v=$3; sub(/^[0-9]+:/,"",v); print $1"-"v"."$2}' \
  | sort -u > centos7.9-app_deps.txt

# drv 构建依赖
yum install --assumeno kernel-devel-$(uname -r) kernel-headers-$(uname -r)
yum install --assumeno kernel-devel kernel-headers elfutils-libelf-devel openssl-devel bc flex perl 2>/dev/null \
  | awk '/^Installing/{f=1} /^Transaction Summary/{f=0} f' \
  | grep -E ' (x86_64|noarch|i686) ' \
  | awk '{v=$3; sub(/^[0-9]+:/,"",v); print $1"-"v"."$2}' \
  | sort -u > centos7.9-drv_deps.txt

# 1. 查看应用独有的包（不在驱动列表中）
comm -23 centos7.9-app_deps.txt centos7.9-drv_deps.txt

# 2. 查看驱动独有的包（不在应用列表中）
comm -13 centos7.9-app_deps.txt centos7.9-drv_deps.txt

# 3. 查看两者共同依赖的包（如 glibc, bash, coreutils 等）
comm -12 centos7.9-app_deps.txt centos7.9-drv_deps.txt
```

2. Centos8.5

```sh
yum install yum-utils -y

# app 构建依赖
yum install --assumeno gcc gcc-c++ make cmake git diffutils \
    readline-devel libpcap-devel libaio-devel zlib-devel 2>/dev/null \
  | awk '/^Installing/{f=1} /^Transaction Summary/{f=0} f' \
  | grep -E ' (x86_64|noarch|i686) ' \
  | awk '{v=$3; sub(/^[0-9]+:/,"",v); print $1"-"v"."$2}' \
  | sort -u > centos8.5-app_deps.txt

# drv 构建依赖
yum install --assumeno kernel-devel-$(uname -r) kernel-headers-$(uname -r)
yum install --assumeno kernel-devel kernel-headers elfutils-libelf-devel openssl-devel bc flex 2>/dev/null \
  | awk '/^Installing/{f=1} /^Transaction Summary/{f=0} f' \
  | grep -E ' (x86_64|noarch|i686) ' \
  | awk '{v=$3; sub(/^[0-9]+:/,"",v); print $1"-"v"."$2}' \
  | sort -u > centos8.5-drv_deps.txt

# 1. 查看应用独有的包（不在驱动列表中）
comm -23 centos8.5-app_deps.txt centos8.5-drv_deps.txt

# 2. 查看驱动独有的包（不在应用列表中）
comm -13 centos8.5-app_deps.txt centos8.5-drv_deps.txt

# 3. 查看两者共同依赖的包（如 glibc, bash, coreutils 等）
comm -12 centos8.5-app_deps.txt centos8.5-drv_deps.txt
```

3. Ubuntu20.04

```sh
# app 构建依赖
apt-get install -y --dry-run build-essential gcc g++ make cmake git diffutils libreadline-dev libpcap-dev libaio-dev zlib1g-dev 2>/dev/null \
| awk '/^Inst /{
    p=$2
    if(match($0,/\([^)]*\)/)){
      s=substr($0,RSTART+1,RLENGTH-1)          
      a=""; if(match(s,/\[[^]]*\]/)) a=substr(s,RSTART+1,RLENGTH-2)
      v=s; sub(/ .*/,"",v); sub(/^[0-9]+:/,"",v)
      if(p!="" && v!="") print p"_"v"_"a".deb"
    }
  }' | sort -u > ubuntu20.04-app_deps.txt

# drv 构建依赖
apt-get install -y --dry-run "linux-headers-$(uname -r)"
apt-get install -y --dry-run linux-headers-generic libelf-dev libssl-dev bc flex kmod 2>/dev/null \
| awk '/^Inst /{
    p=$2
    if(match($0,/\([^)]*\)/)){
      s=substr($0,RSTART+1,RLENGTH-1)          
      a=""; if(match(s,/\[[^]]*\]/)) a=substr(s,RSTART+1,RLENGTH-2)
      v=s; sub(/ .*/,"",v); sub(/^[0-9]+:/,"",v)
      if(p!="" && v!="") print p"_"v"_"a".deb"
    }
  }' | sort -u > ubuntu20.04-drv_deps.txt

# 查看应用独有的包
comm -23 ubuntu20.04-app_deps.txt ubuntu20.04-drv_deps.txt

# 查看驱动独有的包
comm -13 ubuntu20.04-app_deps.txt ubuntu20.04-drv_deps.txt

# 查看两者共同依赖的包
comm -12 ubuntu20.04-app_deps.txt ubuntu20.04-drv_deps.txt
```

4. Ubuntu24.04

```sh
apt-get update

# app 构建依赖
apt-get install -y --dry-run build-essential gcc g++ make cmake git diffutils libreadline-dev libpcap-dev libaio-dev zlib1g-dev 2>/dev/null \
| awk '/^Inst /{
    p=$2
    if(match($0,/\([^)]*\)/)){
      s=substr($0,RSTART+1,RLENGTH-1)
      a=""; if(match(s,/\[[^]]*\]/)) a=substr(s,RSTART+1,RLENGTH-2)
      v=s; sub(/ .*/,"",v); sub(/^[0-9]+:/,"",v)
      if(p!="" && v!="") print p"_"v"_"a".deb"
    }
  }' | sort -u > ubuntu24.04-app_deps.txt

# drv 构建依赖
apt-get install -y --dry-run "linux-headers-$(uname -r)"
apt-get install -y --dry-run linux-headers-generic libelf-dev libssl-dev bc flex kmod 2>/dev/null \
| awk '/^Inst /{
    p=$2
    if(match($0,/\([^)]*\)/)){
      s=substr($0,RSTART+1,RLENGTH-1)
      a=""; if(match(s,/\[[^]]*\]/)) a=substr(s,RSTART+1,RLENGTH-2)
      v=s; sub(/ .*/,"",v); sub(/^[0-9]+:/,"",v)
      if(p!="" && v!="") print p"_"v"_"a".deb"
    }
  }' | sort -u > ubuntu24.04-drv_deps.txt

# 查看应用独有的包
comm -23 ubuntu24.04-app_deps.txt ubuntu24.04-drv_deps.txt

# 查看驱动独有的包
comm -13 ubuntu24.04-app_deps.txt ubuntu24.04-drv_deps.txt

# 查看两者共同依赖的包
comm -12 ubuntu24.04-app_deps.txt ubuntu24.04-drv_deps.txt
```

5. Debian13

```sh
apt-get update

# app 构建依赖
apt-get install -y --dry-run build-essential gcc g++ make cmake git diffutils libreadline-dev libpcap-dev libaio-dev zlib1g-dev 2>/dev/null \
| awk '/^Inst /{
    p=$2
    if(match($0,/\([^)]*\)/)){
      s=substr($0,RSTART+1,RLENGTH-1)
      a=""; if(match(s,/\[[^]]*\]/)) a=substr(s,RSTART+1,RLENGTH-2)
      v=s; sub(/ .*/,"",v); sub(/^[0-9]+:/,"",v)
      if(p!="" && v!="") print p"_"v"_"a".deb"
    }
  }' | sort -u > debian13-app_deps.txt

# drv 构建依赖（Debian 的 meta 包为 linux-headers-amd64）
apt-get install -y --dry-run "linux-headers-$(uname -r)"
apt-get install -y --dry-run linux-headers-amd64 libelf-dev libssl-dev bc flex kmod 2>/dev/null \
| awk '/^Inst /{
    p=$2
    if(match($0,/\([^)]*\)/)){
      s=substr($0,RSTART+1,RLENGTH-1)
      a=""; if(match(s,/\[[^]]*\]/)) a=substr(s,RSTART+1,RLENGTH-2)
      v=s; sub(/ .*/,"",v); sub(/^[0-9]+:/,"",v)
      if(p!="" && v!="") print p"_"v"_"a".deb"
    }
  }' | sort -u > debian13-drv_deps.txt

# 查看应用独有的包
comm -23 debian13-app_deps.txt debian13-drv_deps.txt

# 查看驱动独有的包
comm -13 debian13-app_deps.txt debian13-drv_deps.txt

# 查看两者共同依赖的包
comm -12 debian13-app_deps.txt debian13-drv_deps.txt
```