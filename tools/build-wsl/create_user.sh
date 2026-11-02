#!/bin/bash

# ==========================================
# Ubuntu 20.04 自动新建用户脚本 (函数化版)
# ==========================================

# 全局变量
USERNAME=""
PASSWORD=""
ADD_SUDO="false"

# ------------------------------------------
# 函数：打印帮助信息
# sudo usermod -aG docker $USER
# 方法一: (ubuntu_24.04.4.tar images 1) / (ngis-aig.tar images 2)
# docker import ngis-aig.tar ubuntu_24.04.4:ngis_aig
# docker run -it --name ngis_aig_build -v ~/:/workspace ubuntu_24.04.4:ngis_aig /bin/bash
# docker exec -it ngis_aig_build /bin/bash
# 方法二:
# docker load -i ngis-aig.tar
# docker run -it --name ngis_aig_build -v ~/:/workspace ubuntu_24.04.4:ngis_aig bash
# docker exec -it ngis_aig_build /bin/bash
# 镜像二:
# docker load -i ubuntu_24.04.4.tar
# docker run -it --name ngis_aig_build -v ~/:/workspace ubuntu_24.04.4:ngis_aig bash
# docker exec -it ngis_aig_build /bin/bash
# ------------------------------------------
usage() {
    cat << EOF
用法: $0 [选项]

选项:
  -u, --username <名字>    指定要创建的用户名 (必填)
  -p, --password <密码>    指定用户密码 (可选，不填则交互式输入)
  -s, --sudo               将用户加入 sudo 组 (可选)
  -h, --help               显示此帮助信息

示例:
  $0 -u newuser -p MyPass123 -s
  $0 --username newuser --sudo
EOF
    exit 0
}

# ------------------------------------------
# 函数：检查是否为 root 权限
# ------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：请使用 sudo 或 root 权限运行此脚本。" >&2
        exit 1
    fi
}

# ------------------------------------------
# 函数：检查用户是否已存在
# ------------------------------------------
user_exists() {
    local user=$1
    if id "$user" &>/dev/null; then
        echo "错误：用户 $user 已存在！" >&2
        exit 1
    fi
}

# ------------------------------------------
# 函数：创建用户并设置密码/权限
# ------------------------------------------
create_user() {
    local user=$1
    local pass=$2
    local is_sudo=$3

    echo ">>> 正在创建用户: $user ..."
    # 创建用户并跳过交互提示
    if ! adduser --gecos "" --disabled-password "$user"; then
        echo "错误：创建用户 $user 失败！" >&2
        exit 1
    fi

    # 设置密码
    if [ -n "$pass" ]; then
        echo "$user:$pass" | chpasswd
        echo ">>> 密码已设置。"
    else
        echo ">>> 请为 $user 设置密码："
        passwd "$user"
    fi

    # 配置 sudo 权限
    if [ "$is_sudo" = "true" ]; then
        usermod -aG sudo "$user"
        usermod -aG docker "$user"
        echo ">>> 用户 $user 已成功加入 sudo / docker 组。"
    fi

    echo ">>> 用户 $user 创建完成！"
}

# ------------------------------------------
# 函数：解析命令行参数
# ------------------------------------------
parse_args() {
    # 使用 getopt 解析长短参数
    local TEMP
    TEMP=$(getopt -o u:p:sh --long username:,password:,sudo,help -n "$0" -- "$@")
    
    if [ $? != 0 ]; then
        usage
    fi

    eval set -- "$TEMP"

    while true; do
        case "$1" in
            -u | --username )
                USERNAME="$2"
                shift 2
                ;;
            -p | --password )
                PASSWORD="$2"
                shift 2
                ;;
            -s | --sudo )
                ADD_SUDO="true"
                shift
                ;;
            -h | --help )
                usage
                ;;
            -- )
                shift
                break
                ;;
            * )
                echo "内部错误：参数解析失败"
                exit 1
                ;;
        esac
    done

    # 校验必填参数
    if [ -z "$USERNAME" ]; then
        echo "错误：必须提供用户名 (-u/--username)。" >&2
        echo "使用 -h 查看帮助信息。"
        exit 1
    fi
}

# ==========================================
# 主函数 / 程序入口
# ==========================================
main() {
    parse_args "$@"
    check_root
    user_exists "$USERNAME"
    create_user "$USERNAME" "$PASSWORD" "$ADD_SUDO"
}

# 执行主函数
main "$@"