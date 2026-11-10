ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN source /etc/os-release; \
    case "$ID" in \
      ubuntu) \
        apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
          ca-certificates bash coreutils binutils python3 python3-secretstorage \
          gnome-keyring dbus-x11 libgtk-3-0t64 libstdc++6 libgl1-mesa-dri \
          libegl1 libgl1 libxkbcommon0 fonts-dejavu-core xvfb xauth xdotool; \
        rm -rf /var/lib/apt/lists/* ;; \
      fedora) \
        dnf -y --setopt=timeout=30 --setopt=retries=2 install \
          ca-certificates bash coreutils binutils python3 python3-secretstorage \
          gnome-keyring dbus-daemon gtk3 libstdc++ mesa-dri-drivers mesa-libEGL \
          mesa-libGL libxkbcommon dejavu-sans-fonts xorg-x11-server-Xvfb \
          xorg-x11-xauth xdotool; \
        dnf clean all ;; \
      arch) \
        pacman -Syu --noconfirm --needed ca-certificates bash coreutils binutils \
          python python-secretstorage gnome-keyring dbus gtk3 gcc-libs mesa \
          libglvnd libxkbcommon ttf-dejavu xorg-server-xvfb xorg-xauth xdotool; \
        pacman -Scc --noconfirm ;; \
      *) echo 'Unsupported CI distribution' >&2; exit 1 ;; \
    esac; \
    mkdir -p /home/pc-ci; chown 1000:1000 /home/pc-ci
# D-Bus EXTERNAL authentication resolves the process UID through passwd.
# These entries exist only in disposable test images, never on the user's host.
RUN getent group 1000 >/dev/null || echo 'pc-ci:x:1000:' >> /etc/group
RUN getent passwd 1000 >/dev/null || echo 'pc-ci:x:1000:1000:Disposable CI:/home/pc-ci:/bin/bash' >> /etc/passwd
USER 1000:1000
ENV HOME=/home/pc-ci LANG=C.UTF-8
WORKDIR /tmp
ENTRYPOINT ["dbus-run-session", "--", "bash", "/source/scripts/pc/runtime/smoke.sh"]
