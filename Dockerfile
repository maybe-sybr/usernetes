# this dockerfile can be translated to `docker/dockerfile:1-experimental` syntax for enabling cache mounts:
# $ ./hack/translate-dockerfile-runopt-directive.sh < Dockerfile  | DOCKER_BUILDKIT=1 docker build  -f -  .

### Version definitions
# use ./hack/show-latest-commits.sh to get the latest commits

# 2021-03-02T07:35:48Z
ARG ROOTLESSKIT_COMMIT=2d0f327305a0cf36793d0c02c309b37761f00cf5
# 2021-03-01T22:52:27Z
ARG CONTAINERD_COMMIT=134f7a737074727a6e87214323629b87ba658658
# 2021-01-20T09:48:39Z
ARG CONTAINERD_FUSE_OVERLAYFS_COMMIT=6225620685cfce4e45e8ff858c2698aacab7b012
# 2021-03-01T19:48:51Z
ARG CRIO_COMMIT=c49f180264dd299cb16345dec0a18daaac326da3
# 2021-03-02T07:11:20Z
ARG KUBE_NODE_COMMIT=3727aa47d9f290cfb15d683cf61eb19ffb43c675

# Version definitions (cont.)
ARG SLIRP4NETNS_RELEASE=v1.1.9
ARG CONMON_RELEASE=2.0.26
ARG CRUN_RELEASE=0.18
ARG FUSE_OVERLAYFS_RELEASE=v1.4.0
ARG KUBE_MASTER_RELEASE=v1.21.0-beta.0
# Kube's build script requires KUBE_GIT_VERSION to be set to a semver string
ARG KUBE_GIT_VERSION=v1.21.0-usernetes
ARG CNI_PLUGINS_RELEASE=v0.9.1
ARG FLANNEL_RELEASE=v0.13.0
ARG ETCD_RELEASE=v3.5.0-alpha.0
ARG CFSSL_RELEASE=1.5.0

### Common base images (common-*)
FROM alpine:3.13 AS common-alpine
RUN apk add -q --no-cache git build-base autoconf automake libtool

FROM golang:1.15-alpine AS common-golang-alpine
RUN apk add -q --no-cache git

FROM common-golang-alpine AS common-golang-alpine-heavy
RUN apk -q --no-cache add bash build-base linux-headers libseccomp-dev libseccomp-static

### RootlessKit (rootlesskit-build)
FROM common-golang-alpine AS rootlesskit-build
RUN git clone -q https://github.com/rootless-containers/rootlesskit.git /go/src/github.com/rootless-containers/rootlesskit
WORKDIR /go/src/github.com/rootless-containers/rootlesskit
ARG ROOTLESSKIT_COMMIT
RUN git pull && git checkout ${ROOTLESSKIT_COMMIT}
ENV CGO_ENABLED=0
RUN mkdir /out && \
  go build -o /out/rootlesskit github.com/rootless-containers/rootlesskit/cmd/rootlesskit && \
  go build -o /out/rootlessctl github.com/rootless-containers/rootlesskit/cmd/rootlessctl

#### slirp4netns (slirp4netns-build)
FROM busybox AS slirp4netns-build
ARG SLIRP4NETNS_RELEASE
ADD https://github.com/rootless-containers/slirp4netns/releases/download/${SLIRP4NETNS_RELEASE}/slirp4netns-x86_64 /out/slirp4netns
RUN chmod +x /out/slirp4netns

### fuse-overlayfs (fuse-overlayfs-build)
FROM busybox AS fuse-overlayfs-build
ARG FUSE_OVERLAYFS_RELEASE
ADD https://github.com/containers/fuse-overlayfs/releases/download/${FUSE_OVERLAYFS_RELEASE}/fuse-overlayfs-x86_64 /out/fuse-overlayfs
RUN chmod +x /out/fuse-overlayfs

### crun (crun-build)
FROM busybox AS crun-build
ARG CRUN_RELEASE
ADD https://github.com/containers/crun/releases/download/${CRUN_RELEASE}/crun-${CRUN_RELEASE}-linux-amd64 /out/crun
RUN chmod +x /out/crun

### containerd (containerd-build)
FROM common-golang-alpine-heavy AS containerd-build
RUN git clone https://github.com/containerd/containerd.git /go/src/github.com/containerd/containerd
WORKDIR /go/src/github.com/containerd/containerd
ARG CONTAINERD_COMMIT
RUN git pull && git checkout ${CONTAINERD_COMMIT}
ENV CGO_ENABLED=0
RUN make --quiet EXTRA_FLAGS="-buildmode pie" EXTRA_LDFLAGS='-linkmode external -extldflags "-fno-PIC -static"' BUILDTAGS="netgo osusergo static_build no_devmapper no_btrfs no_aufs no_zfs" \
  bin/containerd bin/containerd-shim-runc-v2 bin/ctr && \
  mkdir /out && cp bin/containerd bin/containerd-shim-runc-v2 bin/ctr /out

### containerd-fuse-overlayfs (containerd-fuse-overlayfs-build)
FROM common-golang-alpine AS containerd-fuse-overlayfs-build
RUN git clone -q https://github.com/AkihiroSuda/containerd-fuse-overlayfs.git /go/src/github.com/AkihiroSuda/containerd-fuse-overlayfs
WORKDIR /go/src/github.com/AkihiroSuda/containerd-fuse-overlayfs
ARG CONTAINERD_FUSE_OVERLAYFS_COMMIT
RUN git pull && git checkout ${CONTAINERD_FUSE_OVERLAYFS_COMMIT}
ENV CGO_ENABLED=0
RUN mkdir /out && \
  go build -o /out/containerd-fuse-overlayfs-grpc github.com/AkihiroSuda/containerd-fuse-overlayfs/cmd/containerd-fuse-overlayfs-grpc

### CRI-O (crio-build)
FROM common-golang-alpine-heavy AS crio-build
RUN git clone -q https://github.com/cri-o/cri-o.git /go/src/github.com/cri-o/cri-o
WORKDIR /go/src/github.com/cri-o/cri-o
ARG CRIO_COMMIT
RUN git pull && git checkout ${CRIO_COMMIT}
COPY ./src/patches/crio /patches
# `git am` requires user info to be set
RUN git config user.email "nobody@example.com" && \
  git config user.name "Usernetes Build Script" && \
  git am /patches/* && git show --summary
RUN EXTRA_LDFLAGS='-linkmode external -extldflags "-static"' make binaries && \
  mkdir /out && cp bin/crio bin/crio-status bin/pinns /out

### conmon (conmon-build)
FROM busybox AS conmon-build
ARG CONMON_RELEASE
RUN wget -q https://github.com/containers/conmon/releases/download/v${CONMON_RELEASE}/conmon.amd64 && \
  mkdir /out && mv conmon.amd64 /out/conmon && \
  chmod +x /out/conmon

### CNI Plugins (cniplugins-build)
FROM busybox AS cniplugins-build
ARG CNI_PLUGINS_RELEASE
RUN mkdir -p /out/cni && \
 wget -q -O - https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_RELEASE}/cni-plugins-linux-amd64-${CNI_PLUGINS_RELEASE}.tgz | tar xz -C /out/cni && \
 cd /out/cni && ls | egrep -vx "(host-local|loopback|bridge|flannel|portmap)" | xargs rm -f

### Kubernetes master (kube-master-build)
FROM busybox AS kube-master-build
ARG KUBE_MASTER_RELEASE
RUN mkdir /out && \
  wget -q -O - https://dl.k8s.io/${KUBE_MASTER_RELEASE}/kubernetes-server-linux-amd64.tar.gz | tar xz -C / && \
  cd /kubernetes/server/bin && \
  cp kube-apiserver kube-controller-manager kube-scheduler kubectl /out

### Kubernetes node (kube-node-build)
FROM common-golang-alpine-heavy AS kube-node-build
RUN apk add -q --no-cache rsync
RUN git clone -q https://github.com/kubernetes/kubernetes.git /kubernetes
WORKDIR /kubernetes
ARG KUBE_NODE_COMMIT
RUN git pull && git checkout ${KUBE_NODE_COMMIT}
COPY ./src/patches/kubernetes /patches
# `git am` requires user info to be set
RUN git config user.email "nobody@example.com" && \
  git config user.name "Usernetes Build Script" && \
  git am /patches/* && git show --summary
ARG KUBE_GIT_VERSION
ENV KUBE_GIT_VERSION=${KUBE_GIT_VERSION}
# runopt = --mount=type=cache,id=u7s-k8s-build-cache,target=/root
RUN KUBE_STATIC_OVERRIDES=kubelet GOFLAGS=-tags=dockerless \
  make --quiet kube-proxy kubelet && \
  mkdir /out && cp _output/bin/kube* /out

#### flannel (flannel-build)
# TODO: use upstream binary when https://github.com/coreos/flannel/issues/1365 gets resolved
FROM common-golang-alpine-heavy AS flannel-build
RUN git clone -q https://github.com/coreos/flannel.git /go/src/github.com/coreos/flannel
WORKDIR /go/src/github.com/coreos/flannel
ARG FLANNEL_RELEASE
RUN git pull && git checkout ${FLANNEL_RELEASE}
ENV CGO_ENABLED=0
RUN make dist/flanneld && \
  mkdir /out && cp dist/flanneld /out

#### etcd (etcd-build)
FROM busybox AS etcd-build
ARG ETCD_RELEASE
RUN mkdir /tmp-etcd /out && \
  wget -q -O - https://github.com/etcd-io/etcd/releases/download/${ETCD_RELEASE}/etcd-${ETCD_RELEASE}-linux-amd64.tar.gz | tar xz -C /tmp-etcd && \
  cp /tmp-etcd/etcd-${ETCD_RELEASE}-linux-amd64/etcd /tmp-etcd/etcd-${ETCD_RELEASE}-linux-amd64/etcdctl /out

#### cfssl (cfssl-build)
FROM busybox AS cfssl-build
ARG CFSSL_RELEASE
RUN mkdir -p /out && \
  wget -q -O /out/cfssl https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_RELEASE}/cfssl_${CFSSL_RELEASE}_linux_amd64 && \
  chmod +x /out/cfssl && \
  wget -q -O /out/cfssljson https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_RELEASE}/cfssljson_${CFSSL_RELEASE}_linux_amd64 && \
  chmod +x /out/cfssljson

### Binaries (bin-main)
FROM scratch AS bin-main
COPY --from=rootlesskit-build /out/* /
COPY --from=slirp4netns-build /out/* /
COPY --from=fuse-overlayfs-build /out/* /
COPY --from=crun-build /out/* /
COPY --from=containerd-build /out/* /
COPY --from=containerd-fuse-overlayfs-build /out/* /
COPY --from=crio-build /out/* /
COPY --from=conmon-build /out/* /
# can't use wildcard here: https://github.com/rootless-containers/usernetes/issues/78
COPY --from=cniplugins-build /out/cni /cni
COPY --from=kube-master-build /out/* /
COPY --from=kube-node-build /out/* /
COPY --from=flannel-build /out/* /
COPY --from=etcd-build /out/* /
COPY --from=cfssl-build /out/* /

#### Test (test-main)
FROM fedora:33 AS test-main
ADD https://raw.githubusercontent.com/AkihiroSuda/containerized-systemd/6ced78a9df65c13399ef1ce41c0bedc194d7cff6/docker-entrypoint.sh /docker-entrypoint.sh
COPY hack/etc_systemd_system_user@.service.d_delegate.conf /etc/systemd/system/user@.service.d/delegate.conf
RUN chmod +x /docker-entrypoint.sh && \
# As of Feb 2020, Fedora has wrong permission bits on newuidmap and newgidmap.
  chmod +s /usr/bin/newuidmap /usr/bin/newgidmap && \
  dnf install -q -y findutils fuse3 git iproute iptables hostname procps-ng which \
# systemd-container: for machinectl
  systemd-container && \
  useradd --create-home --home-dir /home/user --uid 1000 -G systemd-journal user && \
  mkdir -p /home/user/.local /home/user/.config/usernetes && \
  chown -R user:user /home/user && \
  rm -rf /tmp/*
COPY --chown=user:user . /home/user/usernetes
COPY --from=bin-main --chown=user:user / /home/user/usernetes/bin
RUN ln -sf /home/user/usernetes/boot/docker-unsudo.sh /usr/local/bin/unsudo
VOLUME /home/user/.local
HEALTHCHECK --interval=15s --timeout=10s --start-period=60s --retries=5 \
  CMD ["unsudo", "systemctl", "--user", "is-system-running"]
ENTRYPOINT ["/docker-entrypoint.sh", "unsudo", "/home/user/usernetes/boot/docker-2ndboot.sh"]
