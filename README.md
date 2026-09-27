# API Recon Pipeline

A Bash-based API reconnaissance pipeline designed for **authorized security assessments** and testing of systems you own or have explicit permission to assess.

The script combines passive URL discovery, active API endpoint enumeration, HTTP validation, endpoint categorization, and optional retrieval of publicly accessible Swagger/OpenAPI specifications.

> **Important:** Use this tool only against systems you own or have explicit written authorization to test.

## Features

- Passive URL collection with:
  - `gau`
  - `waybackurls`
- API-related URL filtering
- Active API path discovery with `ffuf`
- Automatic HTTP/HTTPS selection
- TLS fallback for hosts with incomplete or invalid certificate chains
- Automatic `ffuf` calibration to reduce false positives
- Candidate merging from historical sources and `ffuf`
- HTTP validation with ProjectDiscovery `httpx`
- JSONL output for easier troubleshooting and parsing
- Detection of interesting HTTP responses such as:
  - `200`
  - `201`
  - `204`
  - `301`
  - `302`
  - `307`
  - `308`
  - `400`
  - `401`
  - `403`
  - `405`
- Automatic endpoint categorization:
  - authentication/login/token endpoints
  - Swagger/OpenAPI/documentation endpoints
  - internal/debug/actuator endpoints
- Technology, page title, and content-length collection
- Optional download of publicly accessible Swagger/OpenAPI specifications
- Scope validation for supplied subdomains
- Separate result and log files for easier analysis
- Explicit `--authorized` confirmation before execution

## Requirements

The following tools are required:

- Bash
- `curl`
- `jq`
- `ffuf`
- `gau`
- `waybackurls`
- ProjectDiscovery `httpx`
- Go, if you want the script to install Go-based tools automatically

On Debian/Kali-based systems, some dependencies can be installed with:

```bash
sudo apt update
sudo apt install -y jq curl ca-certificates golang-go ffuf
```

The script can also attempt to install the required tools:

```bash
./api_recon_fixed_v2.sh --authorized -d example.com --install-tools
```

## Usage

Make the script executable:

```bash
chmod +x api_recon_fixed_v2.sh
```

Run it against an authorized domain:

```bash
./api_recon_fixed_v2.sh --authorized -d example.com
```

### With a subdomain list

```bash
./api_recon_fixed_v2.sh \
  --authorized \
  -d example.com \
  -s subdomains.txt
```

The subdomain file must contain one hostname per line.

Only the root domain and subdomains belonging to the supplied root domain are accepted.

Example:

```text
api.example.com
dev.example.com
portal.example.com
```

### Change the number of threads

```bash
./api_recon_fixed_v2.sh \
  --authorized \
  -d example.com \
  -t 15
```

The supported range is `1` to `50`.

### Specify an output directory

```bash
./api_recon_fixed_v2.sh \
  --authorized \
  -d example.com \
  -o ./results
```

### Disable Swagger/OpenAPI downloads

```bash
./api_recon_fixed_v2.sh \
  --authorized \
  -d example.com \
  --no-download-specs
```

### Ignore TLS certificate verification

```bash
./api_recon_fixed_v2.sh \
  --authorized \
  -d example.com \
  --insecure
```

## Command-line Options

| Option | Description |
|---|---|
| `-d, --domain DOMAIN` | Root domain to test |
| `--authorized` | Confirms that you are authorized to test the target |
| `-s, --subdomains FILE` | Optional file containing permitted subdomains |
| `-o, --output DIR` | Custom output directory |
| `-t, --threads N` | Number of threads used by `ffuf`/`httpx` |
| `--insecure` | Disable TLS certificate verification where supported |
| `--no-download-specs` | Do not download discovered Swagger/OpenAPI files |
| `--install-tools` | Attempt to install required dependencies |
| `-h, --help` | Display usage information |

## Reconnaissance Workflow

The pipeline currently follows six main stages.

### 1. Historical URL Collection

The script queries:

```text
gau
waybackurls
```

The results are deduplicated and stored for later processing.

### 2. API Candidate Filtering

Historical URLs are filtered for API-related paths such as:

```text
/api/
/v1/
/v2/
/auth/
/login
/token
/oauth
/openid
/swagger
/openapi
/api-docs
/docs
/redoc
/admin
```

### 3. Active Endpoint Discovery

`ffuf` checks a built-in wordlist against:

```text
https://example.com/FUZZ
https://example.com/api/FUZZ
```

The script automatically determines whether HTTP or HTTPS should be used.

If HTTPS is reachable but certificate validation fails, HTTPS is still preferred and `ffuf` is executed with TLS verification disabled for that host. This avoids interpreting HTTP-to-HTTPS redirects as valid endpoint discoveries.

`ffuf` also uses automatic calibration to reduce false-positive matches caused by custom 404 pages or uniform responses.

### 4. Candidate Validation with httpx

Historical API candidates and `ffuf` results are merged into:

```text
candidates/all_candidates.txt
```

ProjectDiscovery `httpx` checks the candidates and stores its complete JSONL output in:

```text
candidates/httpx_results.jsonl
```

Only responses with configured interesting status codes are added to:

```text
candidates/active_hits.txt
```

This approach keeps the raw HTTP metadata available for debugging even when no endpoint is ultimately considered active.

### 5. Endpoint Categorization

Active endpoints are grouped into categories.

Authentication-related:

```text
auth
login
token
oauth
openid
```

API documentation:

```text
swagger
openapi
redoc
api-docs
docs
```

Internal/debug endpoints:

```text
internal
debug
actuator
```

### 6. Swagger/OpenAPI Collection

If publicly accessible API specification URLs are discovered, the script can download them into the `specs/` directory.

Downloads are limited to 50 specifications per run.

## Output Structure

A default run creates a timestamped directory similar to:

```text
api_recon_example.com_20260927_120000/
├── summary.txt
├── hosts_in_scope.txt
├── api_wordlist.txt
│
├── historical/
│   ├── gau.txt
│   ├── waybackurls.txt
│   ├── all_urls.txt
│   └── api_candidates.txt
│
├── ffuf/
│   ├── example.com_root.json
│   └── example.com_api.json
│
├── candidates/
│   ├── ffuf_hits_raw.txt
│   ├── ffuf_hits.txt
│   ├── all_candidates.txt
│   ├── httpx_results.jsonl
│   ├── active_hits.txt
│   ├── priority_hits.txt
│   ├── auth_login_token.txt
│   ├── swagger_openapi_docs.txt
│   ├── internal_debug.txt
│   ├── auth_details.txt
│   ├── api_docs_details.txt
│   └── internal_details.txt
│
├── specs/
│   ├── downloaded.tsv
│   ├── *.json
│   ├── *.yaml
│   └── *.headers.txt
│
└── logs/
    ├── gau.stderr.log
    ├── waybackurls.stderr.log
    ├── *_root.stdout.log
    ├── *_root.stderr.log
    ├── *_api.stdout.log
    ├── *_api.stderr.log
    ├── httpx_active.stderr.log
    └── httpx_details.stderr.log
```

## Important Output Files

### `summary.txt`

A high-level summary of the scan, including:

- number of hosts checked
- number of historical URLs
- number of historical API candidates
- number of `ffuf` hits
- total merged candidates
- number of active `httpx` hits
- authentication candidates
- documentation candidates
- internal/debug candidates
- downloaded API specifications

### `historical/all_urls.txt`

Combined and deduplicated URLs discovered by `gau` and `waybackurls`.

### `historical/api_candidates.txt`

Historical URLs that match API-related patterns.

### `candidates/ffuf_hits.txt`

Unique URLs discovered during active `ffuf` enumeration.

### `candidates/all_candidates.txt`

Combined candidate list from passive and active discovery.

### `candidates/httpx_results.jsonl`

Full JSONL response metadata returned by ProjectDiscovery `httpx`.

This file is especially useful when troubleshooting false positives, redirects, custom 404 pages, or unexpected response codes.

### `candidates/active_hits.txt`

Candidates that responded with one of the configured interesting HTTP status codes.

### `candidates/priority_hits.txt`

Higher-priority URLs containing keywords related to authentication, API documentation, internal interfaces, or debugging.

### `candidates/swagger_openapi_docs.txt`

Potential API documentation and specification endpoints.

### `specs/`

Downloaded public Swagger/OpenAPI specification files and associated HTTP response headers.

## Built-in API Wordlist

The current built-in wordlist includes common paths such as:

```text
swagger.json
swagger.yaml
openapi.json
openapi.yaml
v2/api-docs
api-docs
swagger-ui
swagger-ui.html
swagger-ui/index.html
docs
redoc
api
v1
v2
v3
auth
login
token
oauth
openid
admin/api
internal-api
internal
debug
health
healthz
status
actuator
actuator/health
```

The list is intentionally small and focused on common API and service endpoints.

## False Positive Handling

Many web servers respond to nonexistent paths using redirects, custom error pages, or identical `200 OK` responses.

The script attempts to reduce these false positives by:

1. preferring HTTPS when HTTPS is actually available;
2. tolerating broken TLS certificate chains during endpoint discovery;
3. using `ffuf` automatic calibration;
4. validating discovered URLs with ProjectDiscovery `httpx`;
5. excluding ordinary `404 Not Found` responses from `active_hits.txt`;
6. preserving complete `httpx` JSONL output for manual verification.

A URL appearing in the results does **not** automatically indicate a vulnerability.

## Scope Controls

The root domain is always added to the active scope.

When a subdomain file is provided, every hostname is validated before being added.

For a root domain such as:

```text
example.com
```

valid entries include:

```text
api.example.com
dev.example.com
```

while unrelated domains are rejected.

## Security and Legal Notice

This project is intended for:

- systems you own;
- authorized penetration testing;
- defensive security assessments;
- development and staging environments;
- security research performed with explicit permission.

The script requires the `--authorized` flag as an explicit confirmation that permission has been obtained.

The script is designed for reconnaissance and public API specification collection. It does not intentionally:

- exploit vulnerabilities;
- brute-force credentials;
- attempt password attacks;
- modify server-side data;
- send destructive requests;
- bypass authentication.

Authorization requirements still apply even when the performed requests are read-only.

The user is responsible for complying with all applicable laws, policies, contracts, and scope restrictions.

## Notes

- `httpx` must be the **ProjectDiscovery httpx** utility, not the Python package of the same name.
- TLS certificate problems can cause standard `curl` checks to fail even when the HTTPS service itself is reachable. The script contains fallback handling for this situation.
- Empty `active_hits.txt` does not necessarily mean the script failed. It can simply mean that all tested candidate paths returned responses such as `404 Not Found`.
- Always review `candidates/httpx_results.jsonl` and the `logs/` directory when troubleshooting unexpected results.

## Example

```bash
./api_recon_fixed_v2.sh \
  --authorized \
  -d example.com \
  -s subdomains.txt \
  -t 15
```

After the run, start with:

```bash
cat api_recon_example.com_*/summary.txt
```

Then review:

```bash
cat api_recon_example.com_*/candidates/active_hits.txt
cat api_recon_example.com_*/candidates/priority_hits.txt
```

For deeper troubleshooting:

```bash
jq . api_recon_example.com_*/candidates/httpx_results.jsonl
```

## Disclaimer

This software is provided for educational and authorized security testing purposes only.

Do not use it against systems without explicit authorization.
