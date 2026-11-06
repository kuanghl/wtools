# 系统环境构建

## docker 构建和使用

- [docker 构建和使用参考](./docker/README.md)
- [build centos7.9 docker images](./docker/Dockerfile.centos7.9)
- [build centos8.5 docker images](./docker/Dockerfile.centos8.5)
- [build ubuntu20.04 docker images](./docker/Dockerfile.ubuntu20.04)

## wsl 构建和使用

- [build centos7.9 wsl rootfs](./build-wsl-centos7.9.sh)
- [build centos8.5 wsl rootfs](./build-wsl-centos8.5.sh)
- [build ubuntu20.04 wsl rootfs](./build-wsl-ubuntu20.04.sh)
- [build ubuntu24.04 wsl rootfs](./build-wsl-ubuntu24.04.sh)
- [build debian13 wsl rootfs](./build-wsl-debian13.sh)
- [build omarchy4.0.6 wsl rootfs](./build-wsl-omarchy4.0.6.sh)

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

测试系统镜像:

- [CentOS 7.9](https://mirrors.aliyun.com/centos-vault/7.9.2009/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso): CentOS 7.9 将用于测试 run 包
- [CentOS 8.5](https://mirrors.aliyun.com/centos-vault/8.5.2111/isos/x86_64/CentOS-8.5.2111-x86_64-dvd1.iso): CentOS 8.5 将用于测试 run 包
- [Ubuntu 20.04.6](https://mirrors.aliyun.com/oldubuntu-releases/releases/20.04.6/ubuntu-20.04.6-live-server-amd64.iso): Ubuntu 20.04 将用于测试 run 包

```sh
# 安装依赖
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils libudev-dev libvirt-daemon-system libvirt-clients bridge-utils cpu-checker
sudo systemctl enable --now libvirtd
sudo usermod -aG kvm $USER
kvm-ok
sudo add-apt-repository ppa:canonical-server/server-backports
sudo apt update
sudo apt upgrade libvirt-daemon-system libvirt-clients
libvirtd --version
sudo systemctl restart libvirtd
sudo add-apt-repository --remove ppa:canonical-server/server-backports
sudo apt install --reinstall update-notifier-common
sudo /usr/lib/update-notifier/update-motd-updates-available --force
sudo bash -x /etc/update-motd.d/98-fsck-at-reboot
sudo apt update
sudo apt install --only-upgrade coreutils

# 下载系统镜像
sudo apt install aria2
aria2c -x 16 -s 16 -k 1M --file-allocation=none "https://mirrors.nju.edu.cn/centos-vault/7.9.2009/isos/x86_64/CentOS-7-x86_64-Minimal-2009.iso"
aria2c -x 16 -s 16 -k 1M --file-allocation=none "https://mirrors.nju.edu.cn/centos-vault/8.5.2111/isos/x86_64/CentOS-8.5.2111-x86_64-dvd1.iso"
aria2c -x 16 -s 16 -k 1M --file-allocation=none "https://mirrors.nju.edu.cn/ubuntu-releases/20.04.6/ubuntu-20.04.6-live-server-amd64.iso"

# 安装webkvm: https://github.com/Slaker19/webkvm.git
curl -fsSL https://raw.githubusercontent.com/Slaker19/webkvm/main/scripts/install-webkvm.sh | sudo WEBKVM_PORT=18090 bash
# or clone newest
sudo add-apt-repository ppa:longsleep/golang-backports -y
sudo apt update
sudo apt install -y golang nodejs npm
sudo apt install -y pkg-config libvirt-dev libvirt-daemon-system libvirt-clients
go env -w GOPROXY=https://mirrors.aliyun.com/goproxy,direct
go env -w GOPROXY=https://goproxy.cn,direct
git clone https://github.com/kuanghl/webkvm.git
cd webkvm/backend
go clean -modcache
go mod tidy
cd ../../webkvm
make -j$(nproc) build 
make install

# webkvm 安装和使用虚拟机
# "server.port": 18090, 端口号设置
# "server.bind_addr": "0.0.0.0", 监听所有网卡
sudo nano /opt/webkvm/config.json   # Ctrl + O 保存 --> Enter 确认文件名 --> Ctrl + X退出 
sudo ufw allow 18090/tcp
sudo systemctl status webkvm
sudo systemctl stop webkvm
sudo systemctl restart webkvm
sudo journalctl -u webkvm -f
sudo cat /opt/webkvm/admin-password.initial     # 查看密码
http://192.168.4.171:18090                      # 浏览器上打开webkvm，重设密码为 semptian1Q2w3e
http://192.168.4.171:18090/#/vms                # 虚拟机

# 创建虚拟机
# Storage --> Storage Pools --> Create Pool -->  /opt/webkvm/pools/webkvm-isos/     放置系统*.iso镜像
# Storage --> Storage Pools --> Create Pool -->  /opt/webkvm/pools/webkvm-disks/    放置系统*.qcow2镜像
# Virtual Machines --> VM --> Snapshots --> Create Snapshots 创建快照
Storage --> Storage Pools --> ISO Images --> Upload (Target pool: webkvm-isos) --> 上传*.iso系统镜像
Virtual Machines --> Create VM --> 系统配置...

# 配置ssh
# centos7.9
nmcli connection show
nmcli connection modify eth0 ipv4.method auto connection.autoconnect yes
nmcli connection up eth0
ip a # 查看虚拟机ip
sudo systemctl status sshd
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload
# centos8.5
# user: root / password: root
# user: kuanghl / password: 123456
nmcli connection show
nmcli connection modify enp1s0 ipv4.method auto connection.autoconnect yes
nmcli connection up enp1s0
ip a # 查看虚拟机ip
sudo systemctl status sshd
sudo firewall-cmd --zone=libvirt --add-service=ssh --permanent
sudo firewall-cmd --reload
# ubuntu20.04, ubuntu-20.04.6-live-server-amd64.iso 会报错 crash 不用管 --> Close report --> Shutdown
# user: kuanghl / password: 123456
# user: root / password: root
sudo passwd root     # 输入 kuanghl 密码 123456 --> 输入 root 密码 root

# 虚拟机备份，虚拟机先关机
cp /opt/webkvm/pools/webkvm-disks/*..qcow2  ~/kvm
cd ~/kvm
sudo qemu-img info centos7.9.qcow2 | grep -i backing    
# 如果是链接镜像(存在backing)，则需要进行以下转换成独立镜像，才可以移动到其他主机上使用
sudo qemu-img convert -f qcow2 -O qcow2 source.qcow2 standalone.qcow2
```

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