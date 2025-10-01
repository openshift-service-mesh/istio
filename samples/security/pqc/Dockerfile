FROM fedora:41 AS builder

RUN dnf update -y && \
    dnf install -y oqsprovider && \
    dnf clean all

# Create directory structure for copying
RUN mkdir -p /oqs-libs/lib64 /oqs-libs/ossl-modules

# Copy OQS libraries and provider
RUN cp -av /usr/lib64/liboqs.so* /oqs-libs/lib64/
RUN cp -av /usr/lib64/ossl-modules/oqsprovider.so /oqs-libs/ossl-modules/

FROM registry.redhat.io/openshift-service-mesh/istio-proxyv2-rhel9@sha256:d518f3d1539f45e1253c5c9fa22062802804601d4998cd50344e476a3cc388fe AS final

# Copy OQS libraries and provider from builder stage
COPY --from=builder /oqs-libs/lib64/* /usr/lib64/
COPY --from=builder /oqs-libs/ossl-modules/* /usr/lib64/ossl-modules/

# Create OpenSSL configuration that includes OQS provider in /tmp (writable location)
RUN mkdir -p /tmp/ssl && \
    echo "# OpenSSL configuration with OQS provider support" > /tmp/ssl/openssl-oqs.cnf && \
    echo "openssl_conf = openssl_init" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "[openssl_init]" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "providers = provider_sect" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "[provider_sect]" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "default = default_sect" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "oqsprovider = oqsprovider_sect" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "[default_sect]" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "activate = 1" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "[oqsprovider_sect]" >> /tmp/ssl/openssl-oqs.cnf && \
    echo "activate = 1" >> /tmp/ssl/openssl-oqs.cnf && \
    chmod 644 /tmp/ssl/openssl-oqs.cnf

# Set environment variables for OQS OpenSSL
ENV OPENSSL_CONF=/tmp/ssl/openssl-oqs.cnf
ENV LD_LIBRARY_PATH=/usr/lib64
