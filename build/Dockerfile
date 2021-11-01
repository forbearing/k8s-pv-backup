FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

ADD repos/sources.list-focal-aliyun restic-0.12.1-linux-amd64.tar.xz /

RUN mv /sources.list-focal-aliyun /etc/apt/sources.list && \
    mv /restic-0.12.1-linux-amd64 /usr/local/bin/ && \
    ln -sf /usr/local/bin/restic-0.12.1-linux-amd64 /usr/local/bin/restic && \
    apt-get update && \
    apt-get install --no-install-recommends -y \
        apt-transport-https software-properties-common ca-certificates apt-file  \
        inotify-tools \
        iputils-ping bash-completion wget curl zip unzip bzip2  \
        coreutils rsync psmisc procps fuse dnsutils lvm2 sysstat tree lsof netcat locales \
        vim net-tools jq && \
    apt-get autoclean -y && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin && \
    echo "* soft nofile 655360" >> /etc/security/limits.conf && \
    echo "* hard nofile 131072" >> /etc/security/limits.conf && \
    echo "* soft nproc 655360" >> /etc/security/limits.conf && \
    echo "* hard nproc 655360" >> /etc/security/limits.conf && \
    echo "* soft memlock unlimited" >> /etc/security/limits.conf && \
    echo "* hard memlock unlimited" >> /etc/security/limits.conf

RUN mkdir -p /opt/k8s-pv-backup/script /opt/k8s-pv-backup/restic /opt/k8s-pv-backup/template
ADD template /opt/k8s-pv-backup/template
ADD script /opt/k8s-pv-backup/script
ADD restic /opt/k8s-pv-backup/restic
ADD k8s-pv-backup.kubeconfig /



ADD docker-entrypoint.sh kubectl.tar.xz /

ENTRYPOINT ["/docker-entrypoint.sh"]
