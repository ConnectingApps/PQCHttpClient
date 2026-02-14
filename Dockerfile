# =============================================================================
# Stage 1: Build OpenSSL 3.5 from source
# =============================================================================
FROM ubuntu:24.04 AS openssl-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    perl \
    && rm -rf /var/lib/apt/lists/*

ARG OPENSSL_VERSION=3.5.0
RUN curl -fsSL https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz \
    -o /tmp/openssl.tar.gz \
    && tar -xzf /tmp/openssl.tar.gz -C /tmp

WORKDIR /tmp/openssl-${OPENSSL_VERSION}

RUN ./Configure \
    --prefix=/opt/openssl-3.5 \
    --openssldir=/opt/openssl-3.5/ssl \
    linux-x86_64 \
    shared \
    no-tests \
    && make -j$(nproc) \
    && make install_sw install_ssldirs

# =============================================================================
# Stage 2: .NET 10 SDK with custom OpenSSL — build the app
# =============================================================================
FROM mcr.microsoft.com/dotnet/sdk:10.0-preview-noble AS build

# Copy OpenSSL 3.5 from builder stage
COPY --from=openssl-builder /opt/openssl-3.5 /opt/openssl-3.5

# Make the system use our OpenSSL 3.5
ENV LD_LIBRARY_PATH=/opt/openssl-3.5/lib64:/opt/openssl-3.5/lib
ENV PATH="/opt/openssl-3.5/bin:${PATH}"

WORKDIR /src

# Copy project file first for layer caching
COPY pqcheader.csproj ./
RUN dotnet restore

# Copy source and build
COPY Program.cs ./
RUN dotnet publish -c Release -o /app --no-restore

# =============================================================================
# Stage 3: Runtime image with custom OpenSSL
# =============================================================================
FROM mcr.microsoft.com/dotnet/runtime:10.0-preview-noble AS runtime

# Install minimal runtime dependencies for OpenSSL
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy OpenSSL 3.5 libraries
COPY --from=openssl-builder /opt/openssl-3.5 /opt/openssl-3.5

# Configure dynamic linker to find OpenSSL 3.5 FIRST (before system OpenSSL)
RUN echo "/opt/openssl-3.5/lib64" > /etc/ld.so.conf.d/openssl-3.5.conf \
    && echo "/opt/openssl-3.5/lib" >> /etc/ld.so.conf.d/openssl-3.5.conf \
    && ldconfig

# Also set LD_LIBRARY_PATH as belt-and-suspenders
ENV LD_LIBRARY_PATH=/opt/openssl-3.5/lib64:/opt/openssl-3.5/lib
ENV SSL_CERT_DIR=/etc/ssl/certs

WORKDIR /app
COPY --from=build /app .

# Verify OpenSSL version at build time
RUN /opt/openssl-3.5/bin/openssl version

ENTRYPOINT ["dotnet", "pqcheader.dll"]
