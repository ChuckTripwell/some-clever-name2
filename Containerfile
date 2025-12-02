##################################################################################
##################################################################################
####                        this is just a template                            ###
###   please go down to the "Changes go here" section to add your stuff!       ###
##################################################################################
###             a complete image will be published every week.                 ###
##################################################################################
##################################################################################

FROM docker.io/cachyos/cachyos-v3:latest AS output

ENV DRACUT_NO_XATTR=1

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && \
mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# force-refresh and add the chaotic-aur (where we get 'bootc' from)
RUN curl https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-mirrorlist/cachyos-mirrorlist -o /etc/pacman.d/cachyos-mirrorlist
RUN pacman -Syy --needed --overwrite "*" --noconfirm cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist cachyos-hooks archlinux-keyring pacman-mirrorlist
RUN pacman -Syy --noconfirm

# install basic stuff
RUN pacman -S --noconfirm base dracut linux-firmware ostree systemd btrfs-progs e2fsprogs xfsprogs binutils dosfstools skopeo dbus dbus-glib glib2 shadow udev wget
RUN pacman -S --noconfirm librsvg libglvnd qt6-multimedia-ffmpeg plymouth acpid ddcutil dmidecode mesa-utils ntfs-3g vulkan-tools wayland-utils playerctl curl
RUN pacman -S --noconfirm distrobox podman shim networkmanager firewalld flatpak gamescope scx-scheds scx-manager sudo bash bash-completion fastfetch unzip ptyxis

RUN pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
RUN pacman-key --init && pacman-key --lsign-key 3056513887B78AEB
RUN pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' --noconfirm
RUN pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' --noconfirm
RUN echo -e '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
RUN pacman -Sy --noconfirm chaotic-aur/bootc


# add post-transaction flatpsks
RUN mkdir -p /usr/share/flatpak/preinstall.d/

# Bazaar | Get most of your software here, flatpaks that are easy to install and use~
RUN echo -e "[Flatpak Preinstall io.github.kolunmi.Bazaar]\nBranch=stable\nIsRuntime=false" > /usr/share/flatpak/preinstall.d/Bazaar.preinstall

# Systemd flatpak preinstall service
RUN echo -e '[Unit]\n\
Description=Preinstall Flatpaks\n\
After=network-online.target\n\
Wants=network-online.target\n\
ConditionPathExists=/usr/bin/flatpak\n\
Documentation=man:flatpak-preinstall(1)\n\
\n\
[Service]\n\
Type=oneshot\n\
ExecStart=/usr/bin/flatpak preinstall -y\n\
RemainAfterExit=true\n\
Restart=on-failure\n\
RestartSec=30\n\
\n\
StartLimitIntervalSec=600\n\
StartLimitBurst=3\n\
\n\
[Install]\n\
WantedBy=multi-user.target' > /usr/lib/systemd/system/flatpak-preinstall.service

# Set up zram, this will help users not run out of memory.
RUN echo -e '[zram0]\nzram-size = min(ram, 8192)' >> /usr/lib/systemd/zram-generator.conf
RUN echo -e 'enable systemd-resolved.service' >> usr/lib/systemd/system-preset/91-resolved-default.preset
RUN echo -e 'L /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf' >> /usr/lib/tmpfiles.d/resolved-default.conf
RUN systemctl preset systemd-resolved.service

# brew setup 
RUN curl -s https://api.github.com/repos/ublue-os/packages/releases/latest \
    | jq -r '.assets[] | select(.name | test("homebrew-x86_64.*\\.tar\\.zst")) | .browser_download_url' \
    | xargs -I {} wget -O /usr/share/homebrew.tar.zst {}

RUN echo '[[ -d /home/linuxbrew/.linuxbrew && $- == *i* ]] && \
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' > /etc/profile.d/brew.sh

RUN echo -e "[Unit]\n\
Description=Setup Homebrew from tarball\n\
After=local-fs.target\n\
ConditionPathExists=!/var/home/linuxbrew/.linuxbrew\n\
ConditionPathExists=/usr/share/homebrew.tar.zst\n\
\n\
[Service]\n\
Type=oneshot\n\
ExecStart=/usr/bin/mkdir -p /tmp/homebrew\n\
ExecStart=/usr/bin/mkdir -p /var/home/linuxbrew\n\
ExecStart=/usr/bin/tar --zstd -xf /usr/share/homebrew.tar.zst -C /tmp/homebrew\n\
ExecStart=/usr/bin/cp -R -n /tmp/homebrew/linuxbrew/.linuxbrew /var/home/linuxbrew\n\
ExecStart=/usr/bin/chown -R 1000:1000 /var/home/linuxbrew\n\
ExecStart=/usr/bin/rm -rf /tmp/homebrew\n\
ExecStart=/usr/bin/touch /etc/.linuxbrew\n\
\n\
[Install]\n\
WantedBy=multi-user.target" > /usr/lib/systemd/system/brew-setup.service

RUN systemctl enable brew-setup.service


# This fixes a user/groups error with rebasing from other problematic images.
# FIXME Do NOT remove until fixed upstream or fixed universally.
RUN mkdir -p /usr/lib/systemd/system-preset /usr/lib/systemd/system

RUN echo -e '#!/bin/sh\ncat /usr/lib/sysusers.d/*.conf | grep -e "^g" | grep -v -e "^#" | awk "NF" | awk '\''{print $2}'\'' | grep -v -e "wheel" -e "root" -e "sudo" | xargs -I{} sed -i "/{}/d" $1' > /usr/libexec/os-group-fix
RUN chmod +x /usr/libexec/os-group-fix
RUN echo -e '[Unit]\n\
Description=Fix groups\n\
Wants=local-fs.target\n\
After=local-fs.target\n\
[Service]\n\
Type=oneshot\n\
ExecStart=/usr/libexec/os-group-fix /etc/group\n\
ExecStart=/usr/libexec/os-group-fix /etc/gshadow\n\
ExecStart=systemd-sysusers\n\
[Install]\n\
WantedBy=default.target multi-user.target' > /usr/lib/systemd/system/os-group-fix.service

RUN echo -e "enable os-group-fix.service" > /usr/lib/systemd/system-preset/01-os-group-fix.preset

# fix sudo
RUN echo -e '%wheel ALL=(ALL:ALL) ALL'


# System services (Machine Boot level)
RUN systemctl enable polkit.service \
    NetworkManager.service \
    firewalld.service \
    flatpak-preinstall.service \
    os-group-fix.service

# Activate NTSync
RUN echo -e 'ntsync' > /etc/modules-load.d/ntsync.conf

# CachyOS bbr3 Config Option
RUN echo -e 'net.core.default_qdisc=fq \n\
net.ipv4.tcp_congestion_control=bbr' > /etc/sysctl.d/99-bbr3.conf

########################################################################################################################################
# Changes go here:
# (for stability, it is recommended not to use the AUR - that's what distrobox is for.)
########################################################################################################################################

# ONLY ADD ONE KERNEL!!!
# adding more than one will break the build.
#
# note: only cachyos-based kernels are tested, but you can pretty much use any kernel you want.
# adding kernel headers is also recommended.
#
RUN pacman -Sy --noconfirm linux-cachyos linux-cachyos-headers

# install packages here! :)
# available repos:
# Archlinux default repo
# CachyOS package repo
# Chaotic-aur
#
# I added micro for you. go nuts:
#
RUN pacman -S --noconfirm micro

# Place logo at plymouth folder location to appear on boot and shutdown.
#
RUN mkdir -p /etc/plymouth && \
      echo -e '[Daemon]\nTheme=spinner' | tee /etc/plymouth/plymouthd.conf && \
      wget --tries=5 -O /usr/share/plymouth/themes/spinner/watermark.png \
https://raw.githubusercontent.com/ChuckTripwell/cachyos-bootc-template/refs/heads/main/Text_Logo.png # this URL above leads to the logo shown on boot. you can use ours, or upload yours.


## enable your services
# example:
#
systemctl enable docker

########################################################################################################################################
# end of changes
########################################################################################################################################

# finalize
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
      printf 'hostonly=no\nadd_dracutmodules+=" ostree bootc "' | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-modules.conf && \
      sh -c 'export KERNEL_VERSION="$(basename "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")" && \
      dracut --force --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION"  "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"'

RUN rm -rf /home/build/.cache/* && \
    rm -rf \
        /tmp/* \
        /var/cache/pacman/pkg/*

# Necessary for general behavior expected by image-based systems
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /boot /home /root /usr/local /srv /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -s sysroot/ostree /ostree && ln -s var/roothome /root && ln -s var/srv /srv && ln -s var/opt /opt && ln -s var/mnt /mnt && ln -s var/home /home && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

RUN bootc container lint
