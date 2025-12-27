#!/bin/bash
# Reinstall OpenVZ/LXC VPS to Debian Trixie (Testing)
# Static Network Config for User Provided Details

function print_help(){
    echo -ne "\e[1;32m"
    cat <<- EOF
		Target System: Debian Trixie (Testing) - amd64
		Network Mode: Static IPv6 (User Provided)
		[Warning] A fresh system will be installed and all old data will be wiped!
	EOF
    echo -ne "\e[m"
}

function install_requirement(){
    # Fix DNS for pure IPv6 environments momentarily
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

function get_debian_trixie_template(){
    echo -e '\e[1;32mFetching Debian Trixie (Testing) image URL...\e[m'
    server="http://images.linuxcontainers.org"
    arch="amd64" # User specified amd64

    # Search for debian;trixie;amd64;default
    path=$(wget -qO- ${server}/meta/1.0/index-system | \
        grep -v edge | \
        awk -F';' -v arch="$arch" '($1=="debian" && $2=="trixie" && $3==arch && $4=="default") {print $NF}' | \
        tail -n 1)

    if [ -z "$path" ]; then
        echo "Error: Could not find Debian Trixie image for $arch on linuxcontainers.org"
        echo "Trying fallback to Debian Bookworm (Stable) if Trixie is missing..."
        path=$(wget -qO- ${server}/meta/1.0/index-system | \
            grep -v edge | \
            awk -F';' -v arch="$arch" '($1=="debian" && $2=="bookworm" && $3==arch && $4=="default") {print $NF}' | \
            tail -n 1)
            
        if [ -z "$path" ]; then
             echo "Critical Error: Image not found."
             exit 1
        fi
        echo -e "\e[1;33mWarning: Trixie not found, falling back to Bookworm.\e[m"
    fi

    download_link="${server}/${path}/rootfs.tar.xz"
    echo -e "\e[1;36mTarget Image URL: $download_link\e[m"
}

function download_rootfs(){
    mkdir -p /x
    if [ -d "/x/bin" ]; then rm -rf /x/*; fi

    echo "Downloading and extracting rootfs..."
    # Check download first
    if ! wget -q --spider "$download_link"; then
        echo "Error: Download link is invalid or unreachable."
        exit 1
    fi
    
    wget -qO- "$download_link" | tar -C /x -xJv
    
    if [ ! -f /x/bin/bash ]; then
        echo "Error: Rootfs extraction failed (bash not found)."
        exit 1
    fi
}

function apply_static_network(){
    echo -e '\e[1;32mApplying Static Network Configuration...\e[m'
    
    mkdir -p /x/etc/network
    mkdir -p /x/etc/ssh

    # === CONFIGURATION FROM USER ===
    local IFACE="eth0"
    local IP6="2400:8a20:112:1::63/64"
    local GW6="2400:8a20:112:1::1"
    # ===============================

    echo "Interface: $IFACE"
    echo "IPv6: $IP6"
    echo "Gateway: $GW6"

    # Migrate Root Password / SSH Keys
    [ -f /x/etc/shadow ] && sed -i '/^root:/d' /x/etc/shadow
    grep '^root:' /etc/shadow >> /x/etc/shadow
    [ -d /root/.ssh ] && cp -a /root/.ssh /x/root/

    # Generate /etc/network/interfaces
    cat > /x/etc/network/interfaces <<- EOF
auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet6 static
    address $IP6
    gateway $GW6
    dns-nameservers 2001:4860:4860::8888 2606:4700:4700::1111 2a00:1098:2c::1
EOF

    # Set Hostname
    echo "debian-trixie" > /x/etc/hostname
    
    # Set Resolv.conf
    cat > /x/etc/resolv.conf <<- EOF
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
nameserver 2a00:1098:2c::1
EOF

    # Fix for LXC console login (tty)
    # Ensure securetty allows standard ttys
    echo "pts/0" >> /x/etc/securetty
    echo "pts/1" >> /x/etc/securetty
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
    
    # Careful cleanup
    chroot_run 'cd /oldroot; '`
        `'rm -rf $(ls /oldroot | grep -vE "(^dev|^proc|^sys|^run|^x)") ; '`
        `'cd /; '`
        `'mv -f $(ls / | grep -vE "(^dev|^proc|^sys|^run|^oldroot)") /oldroot'
    
    umount /x/oldroot
}

function post_install(){
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    
    echo "Finalizing Debian configuration..."
    
    # Install essential packages
    # Force install ifupdown to use our interfaces file
    chroot_run "apt-get update"
    chroot_run "DEBIAN_FRONTEND=noninteractive apt-get install -y ssh ifupdown curl wget nano"
    
    # Debian specific network cleanup
    # Disable systemd-networkd if present to prefer /etc/network/interfaces
    if [ -f /x/lib/systemd/system/systemd-networkd.service ]; then
        chroot_run "systemctl disable systemd-networkd.service"
    fi
    chroot_run "systemctl unmask networking"
    chroot_run "systemctl enable networking"
    
    # SSH Config
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /x/etc/ssh/sshd_config
    
    # Fstab
    echo "rootfs / auto defaults 0 1" > /x/etc/fstab

    rm -rf /x
    sync
    
    echo -e "\e[1;32mInstallation Complete. System ready.\e[m"
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
    get_debian_trixie_template
    download_rootfs
    apply_static_network
    replace_os
    post_install
}

main 2>&1 | tee reinstall.log
