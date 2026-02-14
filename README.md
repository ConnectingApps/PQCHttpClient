# PQCHttpClient

A proof-of-concept .NET 10 console application that demonstrates **Post-Quantum Cryptography (PQC)** support in real HTTPS connections using **ML-KEM** (Module-Lattice-Based Key Encapsulation Mechanism, formerly CRYSTALS-Kyber) — the first NIST-standardized post-quantum key exchange algorithm.

## Purpose

This project proves that **.NET 10 can perform TLS handshakes using post-quantum hybrid key exchange** (ML-KEM + classical ECDH) when backed by OpenSSL 3.5. It serves as a minimal, reproducible demonstration that:

1. **ML-KEM is supported** by the .NET 10 runtime (via `System.Security.Cryptography.MLKem.IsSupported`)
2. **Real-world HTTPS connections** can negotiate post-quantum key exchange with servers that support it
3. The entire setup works inside a **Docker container** with no host dependencies beyond Docker itself

## Source Code

### Program.cs

```csharp
// HttpClient GET request demonstration
// Performs a GET request to GitHub API and displays status code and response headers

using (var client = new HttpClient())
{
    Console.WriteLine($"ML-KEM supported: {System.Security.Cryptography.MLKem.IsSupported}");
    try
    {
        // Set User-Agent header (required by GitHub API)
        client.DefaultRequestHeaders.Add("User-Agent", "pqcheader-console-app");

        // Execute GET request
        Console.WriteLine("Sending GET request to https://www.quantumsafeaudit.com..");
        Console.WriteLine();
        
        var response = await client.GetAsync("https://www.quantumsafeaudit.com");
        
        // Ensure the request was successful
        response.EnsureSuccessStatusCode();
        
        // Display status code
        Console.WriteLine($"Status Code: {(int)response.StatusCode} {response.StatusCode}");
        Console.WriteLine();
        
        // Display response headers
        Console.WriteLine("Response Headers:");
        Console.WriteLine(new string('-', 50));
        
        foreach (var header in response.Headers)
        {
            Console.WriteLine($"{header.Key}: {string.Join(", ", header.Value)}");
        }
        
        // Also display content headers if present
        if (response.Content.Headers.Any())
        {
            Console.WriteLine();
            Console.WriteLine("Content Headers:");
            Console.WriteLine(new string('-', 50));
            
            foreach (var header in response.Content.Headers)
            {
                Console.WriteLine($"{header.Key}: {string.Join(", ", header.Value)}");
            }
        }
    }
    catch (HttpRequestException ex)
    {
        Console.WriteLine($"Error making HTTP request: {ex.Message}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Unexpected error: {ex.Message}");
    }
}
```

The application does three things:

1. **Checks `System.Security.Cryptography.MLKem.IsSupported`** — this is a .NET 10 API that probes the underlying native cryptographic library to determine whether ML-KEM is available. On Linux, .NET delegates cryptography to OpenSSL via P/Invoke. This property returns `true` only when the loaded OpenSSL version implements ML-KEM (i.e., OpenSSL 3.5+). If the system has OpenSSL 3.0–3.4, this returns `false`.

2. **Sends an HTTPS GET request** to `https://www.quantumsafeaudit.com` — a server configured to support post-quantum TLS key exchange. During the TLS handshake, OpenSSL 3.5 automatically offers hybrid PQC key exchange groups (like `X25519MLKEM768`) in the client's `supported_groups` extension. If the server supports it, the handshake negotiates this hybrid algorithm.

3. **Prints all response headers** — the server at `quantumsafeaudit.com` includes a custom `X-Key-Exchange-Group` header that reports which key exchange algorithm was actually negotiated. This provides independently verifiable, server-side proof of the algorithm used.

### Dockerfile

```dockerfile
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
```

The Dockerfile uses a **3-stage multi-stage build**:

#### Stage 1: `openssl-builder`

Downloads and compiles **OpenSSL 3.5.0** from source on Ubuntu 24.04. This is necessary because Ubuntu 24.04 ships OpenSSL 3.0.x, which does **not** include ML-KEM support. The build installs to `/opt/openssl-3.5` as an isolated prefix so it doesn't conflict with the system OpenSSL.

#### Stage 2: `build`

Uses the **.NET 10 Preview SDK** to compile the application. The custom OpenSSL is copied in and `LD_LIBRARY_PATH` is set so that the SDK uses it during build. The project is published as a Release build.

#### Stage 3: `runtime`

This is the final image that runs the application. It:

1. Installs `ca-certificates` so the app can validate TLS server certificates
2. Copies the compiled OpenSSL 3.5 libraries from stage 1
3. **Configures the dynamic linker** via `/etc/ld.so.conf.d/` and `ldconfig` to ensure OpenSSL 3.5's `libssl.so` and `libcrypto.so` are found **before** any system-provided OpenSSL libraries
4. Sets `LD_LIBRARY_PATH` as a redundant safety net

This linker configuration is the critical piece. When .NET's `SslStream` (used internally by `HttpClient`) loads `libssl.so` at runtime, it picks up the OpenSSL 3.5 version. This is what makes `System.Security.Cryptography.MLKem.IsSupported` return `true`.

## How `MLKem.IsSupported` Works

`System.Security.Cryptography.MLKem.IsSupported` is a static boolean property introduced in .NET 10. Under the hood, the .NET runtime:

1. Loads the system's native OpenSSL library (`libssl.so` / `libcrypto.so`) via P/Invoke
2. Queries OpenSSL for ML-KEM algorithm support
3. Returns `true` only if OpenSSL reports that ML-KEM is available

This creates a **dependency chain**:

```
MLKem.IsSupported == true
  ← .NET 10 runtime (exposes the API)
    ← OpenSSL 3.5+ loaded at runtime (implements the algorithm)
      ← LD_LIBRARY_PATH / ldconfig (ensures the right OpenSSL is found)
```

**Both** components are required:

| Component | Without it |
|-----------|-----------|
| **.NET 10** | The `MLKem` class doesn't exist — older .NET versions have no PQC APIs |
| **OpenSSL 3.5** | `MLKem.IsSupported` returns `false` — the API exists but the native backend can't fulfill it |

This is why the project targets `net10.0` in the project file and suppresses the `SYSLIB5006` warning (which flags ML-KEM APIs as experimental). And it's why the Dockerfile goes through the effort of compiling OpenSSL 3.5 from source — without it, the .NET 10 runtime would fall back to system OpenSSL 3.0.x and `MLKem.IsSupported` would return `false`.

## Output & Explanation

Running the application produces the following output:

```
ML-KEM supported: True
Sending GET request to https://www.quantumsafeaudit.com..

Status Code: 200 OK

Response Headers:
--------------------------------------------------
Accept-Ranges: bytes
Access-Control-Expose-Headers: date,content-type,content-length,server,connection,x-key-exchange-group
Alt-Svc: h3=":443"; ma=2592000
Cache-Control: public, max-age=0
Date: Sat, 14 Feb 2026 21:27:33 GMT
ETag: W/"2ae-19c34d65660"
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
Vary: Origin
X-Key-Exchange-Group: X25519MLKEM768

Content Headers:
--------------------------------------------------
Content-Length: 686
Content-Type: text/html; charset=utf-8
Last-Modified: Fri, 06 Feb 2026 21:23:08 GMT
```

### Breaking Down the Key Parts

| Output | What It Means |
|--------|---------------|
| **`ML-KEM supported: True`** | The .NET 10 runtime detected OpenSSL 3.5 and confirmed that the ML-KEM post-quantum algorithm is available for use. Without OpenSSL 3.5, this would print `False`. |
| **`Status Code: 200 OK`** | The HTTPS request succeeded — the TLS handshake completed and the server responded normally. |
| **`X-Key-Exchange-Group: X25519MLKEM768`** | **This is the critical header.** The server reports the actual key exchange algorithm that was negotiated during the TLS handshake. `X25519MLKEM768` is a **hybrid** algorithm that combines classical **X25519** (Elliptic Curve Diffie-Hellman) with post-quantum **ML-KEM-768** (NIST FIPS 203). |
| **`Strict-Transport-Security`** | The server enforces HTTPS with HSTS, including subdomains and preloading — standard security practice. |
| **`Access-Control-Expose-Headers`** | The server explicitly exposes the `x-key-exchange-group` header to clients, making the negotiated key exchange algorithm visible for inspection. |

### Why `X25519MLKEM768` Matters

The `X-Key-Exchange-Group: X25519MLKEM768` header is direct proof that a **post-quantum hybrid key exchange** took place. This hybrid approach provides:

- **Quantum resistance** via **ML-KEM-768** — secure against future quantum computers running Shor's algorithm
- **Classical security** via **X25519** — maintains protection against current conventional attacks
- **Defense in depth** — even if one algorithm is broken, the other still protects the session

This means the TLS session key was derived from **both** a classical ECDH exchange **and** a post-quantum KEM exchange. An attacker would need to break **both** algorithms to compromise the connection — providing security against both today's conventional threats and tomorrow's quantum threats.

## What This Proves

1. **Post-quantum TLS is production-ready in .NET 10** — the standard `HttpClient` negotiates PQC key exchange without any special configuration or third-party libraries
2. **The only infrastructure requirement is OpenSSL 3.5+** — once the right native library is present, .NET automatically offers PQC cipher suites during TLS negotiation
3. **Hybrid key exchange is backwards-compatible** — if the server doesn't support PQC, the handshake falls back to classical algorithms; if it does (like `quantumsafeaudit.com`), the connection is quantum-resistant
4. **ML-KEM is real and standardized** — this isn't theoretical; the NIST FIPS 203 standard is implemented in OpenSSL 3.5 and exposed through .NET 10's `System.Security.Cryptography` namespace
5. **The server confirms PQC was used** — the `X-Key-Exchange-Group: X25519MLKEM768` response header provides independently verifiable proof that the post-quantum hybrid handshake was negotiated, not just that the client *supports* it

## Running the Project

### Using Docker Compose (recommended)

```bash
docker compose build --no-cache && docker compose up
```

### Using Docker directly

```bash
docker build -t pqcheader-mlkem .
docker run --rm pqcheader-mlkem
```

## Requirements

- **Docker** (or Docker Desktop) — no local .NET SDK or OpenSSL installation needed
- Internet access to pull base images and reach `quantumsafeaudit.com`

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).