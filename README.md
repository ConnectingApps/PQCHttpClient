# PQCHttpClient

A proof-of-concept .NET 10 console application that demonstrates **Post-Quantum Cryptography (PQC)** support in real HTTPS connections using **ML-KEM** (Module-Lattice-Based Key Encapsulation Mechanism, formerly CRYSTALS-Kyber) — the first NIST-standardized post-quantum key exchange algorithm.

## Purpose

This project proves that **.NET 10 can perform TLS handshakes using post-quantum hybrid key exchange** (ML-KEM + classical ECDH) when backed by OpenSSL 3.5. It serves as a minimal, reproducible demonstration that:

1. **ML-KEM is supported** by the .NET 10 runtime (via `System.Security.Cryptography.MLKem.IsSupported`)
2. **Real-world HTTPS connections** can negotiate post-quantum key exchange with servers that support it
3. The entire setup works inside a **Docker container** with no host dependencies beyond Docker itself

## How It Works

### The Application ([Program.cs](Program.cs))

The application performs three key actions:

1. **Checks ML-KEM support** — prints whether `System.Security.Cryptography.MLKem.IsSupported` returns `true`, confirming the runtime has access to a PQC-capable cryptographic backend
2. **Makes an HTTPS GET request** to `https://www.quantumsafeaudit.com` — a server that supports post-quantum TLS key exchange
3. **Prints response headers** — proving the TLS handshake succeeded and revealing which key exchange algorithm was actually negotiated

### The Build Pipeline ([Dockerfile](Dockerfile))

The Dockerfile uses a **3-stage build** to create a minimal runtime image:

| Stage | Purpose |
|-------|---------|
| **`openssl-builder`** | Compiles **OpenSSL 3.5.0** from source on Ubuntu 24.04 |
| **`build`** | Uses the .NET 10 Preview SDK to restore, build, and publish the app |
| **`runtime`** | Copies the published app and custom OpenSSL into a minimal .NET 10 runtime image |

The runtime stage configures the dynamic linker (`ldconfig`) and sets `LD_LIBRARY_PATH` so that OpenSSL 3.5 is loaded **before** any system-provided OpenSSL.

### The Project ([pqcheader.csproj](pqcheader.csproj))

- Targets **`net10.0`** — required because ML-KEM APIs are new in .NET 10
- Suppresses warning **`SYSLIB5006`** — the diagnostic that flags ML-KEM APIs as experimental/preview

## Why OpenSSL 3.5 Is Required

.NET's `SslStream` (used internally by `HttpClient`) delegates TLS operations to the platform's native TLS library. On Linux, that library is **OpenSSL**.

| OpenSSL Version | ML-KEM / PQC Support |
|-----------------|----------------------|
| 1.1.x | ❌ No |
| 3.0–3.4 | ❌ No (only classical algorithms) |
| **3.5.0+** | ✅ **Yes** — includes ML-KEM-768 and hybrid X25519+ML-KEM key exchange |

Ubuntu 24.04 ships OpenSSL 3.0.x by default, which does **not** support post-quantum algorithms. By compiling OpenSSL 3.5 from source and injecting it into the container's library path, the .NET runtime picks up PQC support transparently — no application code changes needed beyond checking `MLKem.IsSupported`.

The chain works as follows:

```
HttpClient.GetAsync()
  → SslStream (TLS handshake)
    → .NET interop to native OpenSSL
      → OpenSSL 3.5 negotiates hybrid PQC key exchange (X25519MLKEM768)
        → Server agrees → quantum-resistant TLS session established
```

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

1. **Post-quantum TLS is production-ready in .NET 10** — the standard `HttpClient` can negotiate PQC key exchange without any special configuration or third-party libraries
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