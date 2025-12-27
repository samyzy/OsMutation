#!/bin/bash
# Reinstall OpenVZ/LXC VPS to Ubuntu 24.04 LTS (Noble) - IPv6 ONLY Version
# Based on OsMutation by Lloyd@nodeseek.com

function print_help(){
    echo -ne "\e[1;32m"
    cat <<- EOF
		Reinstall VPS to Ubuntu 24.04 LTS (Noble);
		[Mode] IPv6 ONLY Auto-Configuration
		[Warning] A fresh system will be installed and all old data will be wiped!
	EOF
    echo -ne "\e[m"
}

function read_virt_tech(){
    # Check for virt-what, install if missing
    if ! command -v virt-what &> /dev/null; then
        if command -v apt-get &> /dev/null; then apt-get update && apt-get install -y virt-what; fi
    fi
    
    cttype=$(virt-what | sed -n 1p)
    if [[ $cttype == "lxc" || $cttype == "openvz" ]]; then
        [[ $cttype == "lxc" ]] && echo -e '\e[1;33mYour container type: lxc\e[m' || echo -e '\e[1;33mYour container type: openvz\e[m'
    else
        # Fallback detection
        if [ -f /proc/user_beancounters ]; then
            cttype="openvz"
        elif grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
            cttype="lxc"
        else
            echo -ne "\e[1;33mUnable to detect container type. Input (lxc/openvz):\e[m"
            read cttype
        fi
    fi
}

function install_requirement(){
    # Fix DNS for pure IPv6 environments momentarily to fetch packages
    # Using NAT64 DNS to access IPv4-only repos if necessary
    echo -e "nameserver 2a00:1098:2c::1\nnameserver 2001:4860:4860::8888" > /etc/resolv.conf

    if [ -n "$(command -v apk)" ] ; then
        apk add curl sed gawk wget gzip xz tar virt-what iproute2
    elif [ -n "$(command -v apt-get)" ] ; then
        apt-get update
        apt-get install -y curl sed gawk wget gzip xz-utils tar virt-what iproute2
    else
        yum install -y curl sed gawk wget gzip xz virt-what iproute
    fi
}

function get_ubuntu_noble_template(){
    echo -e '\e[1;32mFetching Ubuntu 24.04 LTS (Noble) image URL...\e[m'
    server="http://images.linuxcontainers.org"
    
    if [ "$(uname -m)" == "aarch64" ] ; then
        arch="arm64"
    else
        arch="amd64"
    fi

    path=$(wget -qO- ${server}/meta/1.0/index-system | \
        grep -v edge | \
        awk -F';' -v arch="$arch" '($1=="ubuntu" && $2=="noble" && $3==arch && $4=="default") {print $NF}' | \
        tail -n 1)

    if [ -z "$path" ]; then
        echo "Error: Could not find Ubuntu 24.04 image for $arch"
        exit 1
    fi

    download_link="${server}/${path}/rootfs.tar.xz"
    echo -e "\e[1;36mTarget: Ubuntu 24.04 ($arch)\nURL: $download_link\e[m"
}

function download_rootfs(){
    mkdir -p /x
    if [ -d "/x/bin" ]; then rm -rf /x/*; fi

    echo "Downloading and extracting rootfs..."
    wget -qO- "$download_link" | tar -C /x -xJv
}

function migrate_configuration(){
    echo -e '\e[1;32mAuto-detecting IPv6 network configuration...\e[m'

    # 1. Detect Network Interface (IPv6 priority)
    # Try finding interface from default IPv6 route
    dev=$(ip -6 route show default | grep default | awk '{print $5}' | head -n 1)
    
    # Fallback: Find any interface with a global IPv6 address if no default route found yet
    if [ -z "$dev" ]; then
        dev=$(ip -6 addr | grep 'scope global' | awk '{print $NF}' | head -n 1)
    fi
    
    if [ -z "$dev" ]; then
        echo "Error: Could not detect any IPv6-capable network interface!"
        exit 1
    fi
    echo "IPv6 Interface detected: $dev"

    # 2. Capture IPv6 Details
    ip6_addr=$(ip -6 addr show dev "$dev" scope global | grep inet6 | awk '{print $2}' | head -n 1)
    ip6_gw=$(ip -6 route show default | grep default | awk '{print $3}' | head -n 1)

    if [ -z "$ip6_addr" ]; then
        echo "Error: Could not find a global IPv6 address on interface $dev"
        exit 1
    fi

    # 3. Prepare Target Directory
    mkdir -p /x/etc/network
    mkdir -p /x/etc/ssh

    # 4. Migrate User Credentials
    [ -f /x/etc/shadow ] && sed -i '/^root:/d' /x/etc/shadow
    grep '^root:' /etc/shadow >> /x/etc/shadow
    [ -d /root/.ssh ] && cp -a /root/.ssh /x/root/

    # 5. Generate /etc/network/interfaces (IPv6 ONLY)
    echo "Generating IPv6-only configuration..."
    cat > /x/etc/network/interfaces <<- EOF
auto lo
iface lo inet loopback

auto $dev
iface $dev inet6 static
    address $ip6_addr
EOF

    if [ -n "$ip6_gw" ]; then
        echo "    gateway $ip6_gw" >> /x/etc/network/interfaces
    fi
    
    # Add IPv6 DNS + NAT64 DNS
    echo "    dns-nameservers 2001:4860:4860::8888 2606:4700:4700::1111 2a00:1098:2c::1" >> /x/etc/network/interfaces

    # 6. Set Hostname and DNS
    hostname_val=$(hostname)
    echo "$hostname_val" > /x/etc/hostname
    
    # Resolv.conf with IPv6 Nameservers
    cat > /x/etc/resolv.conf <<- EOF
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
nameserver 2a00:1098:2c::1
EOF
}

function chroot_run(){
    if [ ! -f /x/bin/bash ]; then
        chroot "/x/" sh -c "apt-get update && apt-get install -y bash"
    fi
    chroot "/x/" /bin/bash -c "$*"
}

function replace_os(){
    mkdir -p /x/oldroot
    mount --bind / /x/oldroot
    
    chroot_run 'cd /oldroot; '`
        `'rm -rf $(ls /oldroot | grep -vE "(^dev|^proc|^sys|^run|^x)") ; '`
        `'cd /; '`
        `'mv -f $(ls / | grep -vE "(^dev|^proc|^sys|^run|^oldroot)") /oldroot'
    
    umount /x/oldroot
}

function post_install(){
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    
    if grep -qiE "debian|ubuntu" /x/etc/issue; then
        echo "Finalizing Ubuntu configuration..."
        
        # Install ifupdown for interfaces support
        chroot_run "apt-get update"
        chroot_run "DEBIAN_FRONTEND=noninteractive apt-get install -y ssh ifupdown nano curl wget"
        
        # Disable systemd-networkd to rely on /etc/network/interfaces
        chroot_run "systemctl disable systemd-networkd.service"
        chroot_run "systemctl unmask networking"
        chroot_run "systemctl enable networking"
        
        sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /x/etc/ssh/sshd_config
        touch /x/etc/fstab
    fi

    rm -rf /x
    sync
    
    echo -e "\e[1;32mInstallation Complete! IPv6-Only Network Configured.\e[m"
    echo -ne "\e[1;33mReboot now? (yes/no):\e[m"
    read reboot_ans < /dev/tty

    if [ "$reboot_ans" == 'yes' ] ; then
        reboot -f
    fi
}

function main(){
    print_help
    
    if [ "$(id -u)" != "0" ]; then
       echo "Run as root!" 1>&2
       exit 1
    fi

    install_requirement
    read_virt_tech

    if [ "$cttype" == 'kvm' ]; then
        echo "Error: This script supports LXC/OpenVZ only."
        exit 1
    fi

    get_ubuntu_noble_template
    download_rootfs
    migrate_configuration
    replace_os
    post_install
}

main 2>&1 | tee reinstall.log
