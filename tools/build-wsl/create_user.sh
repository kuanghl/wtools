#!/bin/bash

# ==========================================
# Ubuntu 20.04 Automatic User Creation Script (Functional Version)
# ==========================================

# Global Variables
USERNAME=""
PASSWORD=""
ADD_SUDO="false"

# ------------------------------------------
# Function: usage (Print help information)
# Notes:
# sudo usermod -aG docker $USER
# Method 1: (ubuntu_24.04.4.tar images 1) / (ngis-aig.tar images 2)
# docker import ngis-aig.tar ubuntu_24.04.4:ngis_aig
# docker run -it --name ngis_aig_build -v ~/:/workspace ubuntu_24.04.4:ngis_aig /bin/bash
# docker exec -it ngis_aig_build /bin/bash
# Method 2:
# docker load -i ngis-aig.tar
# docker run -it --name ngis_aig_build -v ~/:/workspace ubuntu_24.04.4:ngis_aig bash
# docker exec -it ngis_aig_build /bin/bash
# Image 2:
# docker load -i ubuntu_24.04.4.tar
# docker run -it --name ngis_aig_build -v ~/:/workspace ubuntu_24.04.4:ngis_aig bash
# docker exec -it ngis_aig_build /bin/bash
# ------------------------------------------
usage() {
    cat << EOF
Usage: $0 [options]

Options:
  -u, --username <name>    Specify the username to create (required)
  -p, --password <pass>    Specify the user password (optional, prompts interactively if omitted)
  -s, --sudo               Add the user to the sudo group (optional)
  -h, --help               Display this help message

Example:
  $0 -u newuser -p MyPass123 -s
  $0 --username newuser --sudo
EOF
    exit 0
}

# ------------------------------------------
# Function: check_root
# Description: Check if the script is run with root privileges
# ------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: Please run this script with sudo or as root." >&2
        exit 1
    fi
}

# ------------------------------------------
# Function: user_exists
# Description: Check if the user already exists
# ------------------------------------------
user_exists() {
    local user=$1
    if id "$user" &>/dev/null; then
        echo "Error: User $user already exists!" >&2
        exit 1
    fi
}

# ------------------------------------------
# Function: create_user
# Description: Create user and set password/permissions
# ------------------------------------------
create_user() {
    local user=$1
    local pass=$2
    local is_sudo=$3

    echo ">>> Creating user: $user ..."
    # Create user and skip interactive prompts
    if ! adduser --gecos "" --disabled-password "$user"; then
        echo "Error: Failed to create user $user!" >&2
        exit 1
    fi

    # Set password
    if [ -n "$pass" ]; then
        echo "$user:$pass" | chpasswd
        echo ">>> Password has been set."
    else
        echo ">>> Please set a password for $user:"
        passwd "$user"
    fi

    # Configure sudo privileges
    if [ "$is_sudo" = "true" ]; then
        usermod -aG sudo "$user"
        
        # Optional: Add to docker group if it exists
        if getent group docker > /dev/null; then
            usermod -aG docker "$user"
            echo ">>> User $user successfully added to sudo / docker groups."
        else
            echo ">>> User $user successfully added to sudo group (docker group not found)."
        fi
    fi

    echo ">>> User $user created successfully!"
}

# ------------------------------------------
# Function: parse_args
# Description: Parse command-line arguments
# ------------------------------------------
parse_args() {
    # Use getopt to parse long and short arguments
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
                echo "Internal Error: Argument parsing failed."
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$USERNAME" ]; then
        echo "Error: Username is required (-u/--username)." >&2
        echo "Use -h for help information."
        exit 1
    fi
}

# ==========================================
# Main Function / Program Entry
# ==========================================
main() {
    parse_args "$@"
    check_root
    user_exists "$USERNAME"
    create_user "$USERNAME" "$PASSWORD" "$ADD_SUDO"
}

# Execute the main function
main "$@"