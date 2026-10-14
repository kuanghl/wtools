# 系统环境构建

## docker 构建和使用

- [docker 构建和使用参考](./docker/README.md)
- [build centos7.9 docker images](./docker/Dockerfile.centos7)
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