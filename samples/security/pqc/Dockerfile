FROM docker.io/redhat/ubi9:9.6 AS builder

ARG LIBOQS_TAG=0.12.0
ARG OQSPROVIDER_TAG=0.8.0
ARG INSTALLDIR_OPENSSL=/usr/lib64
ARG INSTALLDIR_LIBOQS=/opt/liboqs

RUN dnf install -y git make cmake ninja-build
RUN dnf install -y openssl-devel
RUN dnf install -y gcc gcc-c++

WORKDIR /optbuild
RUN git clone --depth 1 --branch ${LIBOQS_TAG} https://github.com/open-quantum-safe/liboqs

WORKDIR /optbuild/liboqs/build
RUN cmake -G "Ninja" .. \
    -DOPENSSL_ROOT_DIR=${INSTALLDIR_OPENSSL} \
    -DCMAKE_INSTALL_PREFIX=${INSTALLDIR_LIBOQS} && \
    ninja install

WORKDIR /optbuild
RUN git clone --depth 1 --branch ${OQSPROVIDER_TAG} https://github.com/open-quantum-safe/oqs-provider.git

WORKDIR /optbuild/oqs-provider
RUN liboqs_DIR=${INSTALLDIR_LIBOQS} cmake \
    -DOPENSSL_ROOT_DIR=${INSTALLDIR_OPENSSL} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=${INSTALLDIR_OPENSSL} \
    -S . -B _build && \
    cmake --build _build && \
    cmake --install _build && \
    cp _build/lib/oqsprovider.so ${INSTALLDIR_OPENSSL}/ossl-modules

FROM registry.redhat.io/openshift-service-mesh/istio-proxyv2-rhel9:1.26.2 AS final

ARG INSTALLDIR_OPENSSL=/usr/lib64
ARG INSTALLDIR_LIBOQS=/opt/liboqs

COPY --from=builder ${INSTALLDIR_LIBOQS} ${INSTALLDIR_LIBOQS}
COPY --from=builder ${INSTALLDIR_OPENSSL}/ossl-modules ${INSTALLDIR_OPENSSL}/ossl-modules

USER root
RUN sed '/^default = default_sect$/a oqsprovider = oqsprovider_sect' /etc/pki/tls/openssl.cnf > /tmp/openssl.cnf && \
    printf "\n[oqsprovider_sect]\n" >> /tmp/openssl.cnf && \
    echo "module = /usr/lib64/ossl-modules/oqsprovider.so" >> /tmp/openssl.cnf && \
    echo "activate = 1" >> /tmp/openssl.cnf && \
    cp /tmp/openssl.cnf /etc/pki/tls/openssl.cnf
USER 1000
