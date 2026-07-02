# Zeek JSON Field Reference

This reference covers the JSON fields emitted by Zeek on Firewalla firmware for
`dns.log` and `conn.log`. All fields are present in the raw `log` string that
Fluent Bit ships to Axiom — parse it with `parse_json(log)` in APL queries.

## Field name gotchas

### Bracket notation is required in APL

Zeek uses dotted field names like `id.orig_h`. In APL, the dot is a nested-path
separator, so `parsed.id.orig_h` silently returns `null` instead of the value
you want. Always use bracket notation:

```kusto
| extend source_ip = tostring(parsed["id.orig_h"])   // correct
| extend source_ip = tostring(parsed.id.orig_h)       // wrong — returns null
```

### MAC addresses are lowercased by Zeek

Zeek writes MAC addresses in lowercase (e.g., `e8:4c:4a:db:9c:e8`). Firewalla's
Redis device inventory stores them in uppercase (`E8:4C:4A:DB:9C:E8`). The
`device_lookup_export.sh` script normalises Redis MACs to lowercase before
writing to the `firewalla-devices` dataset, so joins work correctly.

### Integer fields arrive as strings in some contexts

Fields like `qtype`, `rcode`, `orig_bytes`, and `resp_bytes` are numeric in
Zeek's JSON but APL's `parse_json()` may return them as strings depending on
the Axiom ingest path. Use explicit casts:

```kusto
| extend orig_bytes = tolong(parsed["orig_bytes"])
| extend qtype      = toint(parsed["qtype"])
```

### Boolean fields

Boolean Zeek fields (`AA`, `TC`, `RD`, `RA`, `rejected`) are emitted as JSON
`true`/`false`. In APL, cast with `tobool()`:

```kusto
| extend recursion_desired = tobool(parsed["RD"])
```

### Absent vs. null fields

Zeek omits fields that have no value rather than writing `null`. Always use
`isnotempty()` or `isnotnull()` guards when a field may be absent:

```kusto
| where isnotempty(tostring(parsed["query"]))
```

---

## dns.log fields

Each row in `dns.log` represents a single DNS query/response pair observed on
the network.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch timestamp of the first DNS packet. Fluent Bit maps this to `_time` in Axiom. |
| `uid` | string | Unique connection identifier (e.g., `CnQevD3eFtgYtgY7Cc`). Links related log entries across log types. |
| `id.orig_h` | string | Source (client) IP address — the device that made the DNS query. Requires bracket notation. |
| `id.orig_p` | int | Source port of the DNS client (typically ephemeral, e.g., `54321`). |
| `id.resp_h` | string | Destination IP address — the DNS server that received the query (e.g., `8.8.8.8`). |
| `id.resp_p` | int | Destination port — always `53` for standard DNS. |
| `proto` | string | Transport protocol: `udp` (most DNS) or `tcp` (large responses, zone transfers). |
| `trans_id` | int | DNS transaction ID (0–65535). Matches query to response within a session. |
| `rtt` | float | Round-trip time in seconds from query sent to response received. Absent if no response was seen. |
| `query` | string | The domain name that was queried (e.g., `api.example.com`). This is the primary field for domain analysis. |
| `qclass` | int | Numeric DNS query class. Almost always `1` (Internet). |
| `qclass_name` | string | Human-readable query class: `C_INTERNET` for class 1. |
| `qtype` | int | Numeric DNS query type (e.g., `1` = A, `28` = AAAA, `5` = CNAME). |
| `qtype_name` | string | Human-readable query type: `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `PTR`, `SRV`, `NS`, etc. |
| `rcode` | int | Numeric DNS response code. `0` = NOERROR, `3` = NXDOMAIN, `2` = SERVFAIL. |
| `rcode_name` | string | Human-readable response code: `NOERROR`, `NXDOMAIN`, `SERVFAIL`, `REFUSED`, etc. |
| `AA` | bool | Authoritative Answer flag — `true` if the response came directly from the zone's authoritative server. |
| `TC` | bool | Truncation flag — `true` if the response was truncated and the client should retry over TCP. |
| `RD` | bool | Recursion Desired flag — `true` if the client asked the server to resolve recursively (almost always `true`). |
| `RA` | bool | Recursion Available flag — `true` if the server supports recursive queries. |
| `Z` | int | Reserved bits in the DNS header. Should always be `0`; non-zero values may indicate malformed packets. |
| `answers` | array | Array of resource record strings in the DNS response (e.g., `["93.184.216.34"]`, `["api.cdn.example.com", "203.0.113.1"]`). Empty array if no answer section. |
| `TTLs` | array | Array of TTL values (in seconds) for each answer record. Parallel array to `answers`. |
| `rejected` | bool | `true` if Zeek's internal DNS analysis determined the response was rejected or invalid. |
| `orig_l2_addr` | string | Source MAC address of the querying device (e.g., `e8:4c:4a:db:9c:e8`). **Key field for device joins** — more reliable than IP because it works for both IPv4 and IPv6 clients. |
| `resp_l2_addr` | string | Destination MAC address — typically the router/gateway MAC for upstream DNS queries. |

### Example dns.log event (raw JSON)

```json
{
  "ts": 1741737600.123456,
  "uid": "CnQevD3eFtgYtgY7Cc",
  "id.orig_h": "192.168.1.42",
  "id.orig_p": 54321,
  "id.resp_h": "8.8.8.8",
  "id.resp_p": 53,
  "proto": "udp",
  "trans_id": 12345,
  "rtt": 0.012,
  "query": "api.example.com",
  "qclass": 1,
  "qclass_name": "C_INTERNET",
  "qtype": 1,
  "qtype_name": "A",
  "rcode": 0,
  "rcode_name": "NOERROR",
  "AA": false,
  "TC": false,
  "RD": true,
  "RA": true,
  "Z": 0,
  "answers": ["93.184.216.34"],
  "TTLs": [3600.0],
  "rejected": false,
  "orig_l2_addr": "e8:4c:4a:db:9c:e8",
  "resp_l2_addr": "dc:a6:32:01:23:45"
}
```

---

## conn.log fields

Each row in `conn.log` represents a completed network connection (TCP session,
UDP flow, or ICMP exchange). This log is used for bandwidth analysis and tying
DNS queries to actual traffic.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch timestamp of the first packet in the connection. |
| `uid` | string | Unique connection identifier. Matches `uid` values in other Zeek log types (e.g., `ssl.log`, `http.log`) for the same connection. |
| `id.orig_h` | string | Source (originator) IP address. |
| `id.orig_p` | int | Source port of the originator. |
| `id.resp_h` | string | Destination (responder) IP address. |
| `id.resp_p` | int | Destination port (e.g., `443` for HTTPS, `80` for HTTP, `53` for DNS). |
| `proto` | string | Transport protocol: `tcp`, `udp`, or `icmp`. |
| `service` | string | Application-layer protocol detected by Zeek (e.g., `dns`, `ssl`, `http`, `dhcp`). Absent if Zeek couldn't classify the traffic. |
| `duration` | float | Total connection duration in seconds. Absent for connections that were still open when Zeek logged them. |
| `orig_bytes` | int | Payload bytes sent by the originator (does not include IP/TCP headers). Absent for UDP or if Zeek couldn't determine the value. |
| `resp_bytes` | int | Payload bytes sent by the responder. Absent for UDP or if unknown. |
| `conn_state` | string | Summary of the connection's final state (see conn_state values below). |
| `local_orig` | bool | `true` if the originator IP is in a locally-defined network. |
| `local_resp` | bool | `true` if the responder IP is in a locally-defined network. |
| `missed_bytes` | int | Bytes that Zeek missed due to packet loss or capture gaps. `0` means no gaps. |
| `history` | string | Single-character sequence encoding the connection's packet history (e.g., `ShADadFf` for a normal TCP session). See history codes below. |
| `orig_pkts` | int | Total packets sent by the originator. |
| `orig_ip_bytes` | int | Total IP-layer bytes sent by the originator (includes headers). |
| `resp_pkts` | int | Total packets sent by the responder. |
| `resp_ip_bytes` | int | Total IP-layer bytes sent by the responder (includes headers). |
| `orig_l2_addr` | string | Source MAC address (e.g., `e8:4c:4a:db:9c:e8`). **Key field for device joins.** |
| `resp_l2_addr` | string | Destination MAC address. |

### conn_state values

| Value | Meaning |
|-------|---------|
| `S0` | SYN sent, no response — likely a blocked or dropped connection |
| `S1` | TCP connection established, never cleanly closed |
| `SF` | Normal TCP session: SYN, SYN-ACK, data, FIN — clean close by both sides |
| `REJ` | SYN was rejected with RST |
| `S2` | Connection established, originator sent FIN but responder didn't respond |
| `S3` | Connection established, responder sent FIN but originator didn't respond |
| `RSTO` | Connection reset by originator |
| `RSTR` | Connection reset by responder |
| `RSTOS0` | Originator sent SYN then reset before getting a SYN-ACK |
| `RSTRH` | Responder sent SYN-ACK then reset without seeing a SYN |
| `SH` | Originator sent SYN and FIN without SYN-ACK — half-open scan |
| `SHR` | Responder sent SYN-ACK and FIN — unusual |
| `OTH` | No SYN seen (mid-stream capture) |

### history codes

The `history` field encodes each side's packet events as a string. Uppercase
letters = originator, lowercase = responder:

| Letter | Event |
|--------|-------|
| `S`/`s` | SYN packet |
| `H`/`h` | SYN-ACK packet |
| `A`/`a` | Pure ACK (no data) |
| `D`/`d` | Data packet |
| `F`/`f` | FIN packet |
| `R`/`r` | RST packet |
| `C`/`c` | ICMP unreachable |
| `T`/`t` | Retransmitted packet |

A normal HTTP/S connection looks like `ShADadFf` (SYN → SYN-ACK → ACKs → data both ways → FINs).

### Example conn.log event (raw JSON)

```json
{
  "ts": 1741737612.456789,
  "uid": "C5GXBP2kWuMqN1MwMb",
  "id.orig_h": "192.168.1.42",
  "id.orig_p": 54890,
  "id.resp_h": "93.184.216.34",
  "id.resp_p": 443,
  "proto": "tcp",
  "service": "ssl",
  "duration": 2.341,
  "orig_bytes": 1248,
  "resp_bytes": 45120,
  "conn_state": "SF",
  "local_orig": true,
  "local_resp": false,
  "missed_bytes": 0,
  "history": "ShADadFf",
  "orig_pkts": 12,
  "orig_ip_bytes": 1888,
  "resp_pkts": 38,
  "resp_ip_bytes": 47280,
  "orig_l2_addr": "e8:4c:4a:db:9c:e8",
  "resp_l2_addr": "dc:a6:32:01:23:45"
}
```

---

## APL query patterns

### Extract common dns.log fields

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed     = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend source_ip  = tostring(parsed["id.orig_h"])
| extend domain     = tostring(parsed["query"])
| extend qtype      = tostring(parsed["qtype_name"])
| extend rcode      = tostring(parsed["rcode_name"])
| extend answers    = tostring(parsed["answers"])
```

### Extract common conn.log fields

```kusto
['firewalla']
| where log_source == "zeek_conn"
| extend parsed       = parse_json(log)
| extend source_mac   = tostring(parsed["orig_l2_addr"])
| extend source_ip    = tostring(parsed["id.orig_h"])
| extend dest_ip      = tostring(parsed["id.resp_h"])
| extend dest_port    = toint(parsed["id.resp_p"])
| extend proto        = tostring(parsed["proto"])
| extend service      = tostring(parsed["service"])
| extend orig_bytes   = tolong(parsed["orig_bytes"])
| extend resp_bytes   = tolong(parsed["resp_bytes"])
| extend conn_state   = tostring(parsed["conn_state"])
| extend duration_sec = todouble(parsed["duration"])
```

### Join with device names

Both log types use `orig_l2_addr` as the device identifier for the join:

```kusto
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | distinct mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
```

---

## ssl.log fields

Each row in `ssl.log` represents a TLS handshake observed on the network. This is
the highest-signal log on an HTTPS-dominant network: DNS shows what got looked up,
SSL shows what actually got connected to (the `server_name` SNI), plus the
identifying handshake metadata that lets you fingerprint clients and services.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch timestamp of the handshake. |
| `uid` | string | Unique connection identifier. Joins to `conn.log` on the same `uid`. |
| `id.orig_h` / `id.orig_p` | string / int | Source IP/port. |
| `id.resp_h` / `id.resp_p` | string / int | Destination IP/port (typically `443`). |
| `version` | string | Negotiated TLS version (e.g., `TLSv13`, `TLSv12`). |
| `cipher` | string | Negotiated cipher suite (e.g., `TLS_AES_128_GCM_SHA256`). |
| `curve` | string | Negotiated elliptic curve (e.g., `x25519`). Absent for older ciphers. |
| `server_name` | string | **The SNI value sent by the client.** This is the field that tells you what site was visited even when DNS was over DoH/DoT. |
| `resumed` | bool | `true` if the session was resumed (skips full handshake). |
| `next_protocol` | string | ALPN-negotiated protocol (e.g., `h2`, `http/1.1`). |
| `established` | bool | `true` if the handshake completed; `false` for client-aborted / failed handshakes. |
| `ssl_history` | string | Compact character sequence describing handshake phases observed (Zeek's coarse JA3-equivalent). Useful for client fingerprinting. |
| `cert_chain_fps` | array | SHA-1 fingerprints of certs in the server's chain, leaf-first. |
| `client_cert_chain_fps` | array | Fingerprints of any client certs (rare). |
| `subject` | string | Subject DN of the leaf cert. |
| `issuer` | string | Issuer DN of the leaf cert. |
| `validation_status` | string | Result of Zeek's cert validation (e.g., `ok`, `unable to get local issuer certificate`). |
| `orig_l2_addr` | string | Source MAC — same field as in `dns.log` / `conn.log`. Use for device joins. |
| `resp_l2_addr` | string | Destination MAC. |

### Example ssl.log event (raw JSON)

```json
{
  "ts": 1741737620.123,
  "uid": "Cv9XXX...",
  "id.orig_h": "192.168.1.42",
  "id.orig_p": 51234,
  "id.resp_h": "142.250.80.46",
  "id.resp_p": 443,
  "version": "TLSv13",
  "cipher": "TLS_AES_128_GCM_SHA256",
  "curve": "x25519",
  "server_name": "www.google.com",
  "resumed": false,
  "next_protocol": "h2",
  "established": true,
  "ssl_history": "CssSh",
  "cert_chain_fps": ["d6a7f4...", "a8b8c8..."],
  "subject": "CN=www.google.com",
  "issuer": "CN=GTS CA 1C3,O=Google Trust Services LLC,C=US",
  "validation_status": "ok",
  "orig_l2_addr": "e8:4c:4a:db:9c:e8",
  "resp_l2_addr": "dc:a6:32:01:23:45"
}
```

### APL pattern — what SNIs did each device hit?

```kusto
['firewalla']
| where log_source == "zeek_ssl"
| extend parsed     = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend sni        = tostring(parsed["server_name"])
| where isnotempty(sni)
| summarize hits = count() by source_mac, sni
| order by hits desc
```

---

## http.log fields

Each row in `http.log` represents a single HTTP request/response pair. Most
modern traffic is HTTPS and won't appear here — `ssl.log` covers those
connections via SNI. This log captures unencrypted HTTP (port 80 and custom
ports), HTTP CONNECT tunnels, and any HTTP inside the network before a TLS
session begins.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Timestamp of the request. |
| `uid` | string | Unique connection identifier. Joins to `conn.log` and `files.log` on the same `uid`. |
| `id.orig_h` / `id.orig_p` | string / int | Source IP/port of the HTTP client. |
| `id.resp_h` / `id.resp_p` | string / int | Destination IP/port of the HTTP server. |
| `trans_depth` | int | Request-reply depth within a persistent connection. `1` = first request. |
| `method` | string | HTTP request method: `GET`, `POST`, `PUT`, `DELETE`, `HEAD`, etc. |
| `host` | string | Value of the HTTP `Host:` header — the requested hostname. Primary field for identifying the server on port 80. |
| `uri` | string | Request URI path and query string (e.g., `/api/v2/data?limit=50`). May be very long. |
| `referrer` | string | Value of the `Referer:` header. Empty for direct requests. |
| `version` | string | HTTP version negotiated: `1.0`, `1.1`, or `2`. |
| `user_agent` | string | Value of the `User-Agent:` header. Useful for identifying device types and application software. |
| `request_body_len` | int | Bytes in the request body (e.g., POST payload). `0` for GET requests. |
| `response_body_len` | int | Bytes in the response body. Use this to spot large downloads. |
| `status_code` | int | HTTP response status code (e.g., `200`, `301`, `404`, `500`). |
| `status_msg` | string | Human-readable response status (e.g., `OK`, `Not Found`, `Moved Permanently`). |
| `tags` | array | Tags assigned by Zeek's HTTP analyzer (e.g., `PROXIMITY_BYTES`). Usually empty. |
| `resp_fuids` | array | File unique IDs (from `files.log`) for content transferred in the response. Join to `files.log` on `fuid`. |
| `resp_filenames` | array | Filenames extracted from `Content-Disposition` or similar headers. |
| `resp_mime_types` | array | MIME types of response bodies (e.g., `text/html`, `application/json`, `image/jpeg`). |
| `orig_fuids` | array | File unique IDs for content sent in the request body (e.g., file uploads). |
| `orig_filenames` | array | Filenames in the request (e.g., multipart uploads). |
| `orig_mime_types` | array | MIME types of uploaded content. |
| `orig_l2_addr` | string | Source MAC — use for device joins. |
| `resp_l2_addr` | string | Destination MAC. |

### Example http.log event (raw JSON)

```json
{
  "ts": 1741737700.123,
  "uid": "CabcXY1234",
  "id.orig_h": "192.168.1.55",
  "id.orig_p": 49201,
  "id.resp_h": "93.184.216.34",
  "id.resp_p": 80,
  "trans_depth": 1,
  "method": "GET",
  "host": "example.com",
  "uri": "/index.html",
  "referrer": "",
  "version": "1.1",
  "user_agent": "Mozilla/5.0 (Linux; Android 13) ...",
  "request_body_len": 0,
  "response_body_len": 1256,
  "status_code": 200,
  "status_msg": "OK",
  "tags": [],
  "resp_fuids": ["FaBcD1e2f3"],
  "resp_filenames": [],
  "resp_mime_types": ["text/html"],
  "orig_fuids": [],
  "orig_filenames": [],
  "orig_mime_types": [],
  "orig_l2_addr": "e8:4c:4a:db:9c:e8",
  "resp_l2_addr": "dc:a6:32:01:23:45"
}
```

---

## files.log fields

Each row in `files.log` represents a file observed in transit across any
protocol that Zeek's file analysis framework supports (HTTP, SMTP, FTP, SSL
certificate DER data, etc.). Rows are keyed by `fuid` (file unique ID) rather
than a connection `uid` — a single connection may produce multiple file rows
if multiple transfers occur.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Timestamp when Zeek began observing this file. |
| `fuid` | string | File unique ID. Matches `resp_fuids` / `orig_fuids` in `http.log`. |
| `tx_hosts` | array | IP(s) that transmitted the file. |
| `rx_hosts` | array | IP(s) that received the file. |
| `conn_uids` | array | Connection UIDs associated with this file transfer. Joins to `conn.log` and `http.log`. |
| `source` | string | Protocol that produced the file: `HTTP`, `SMTP`, `FTP`, `SSL` (for cert chains), etc. |
| `depth` | int | HTTP transaction depth within the connection (matches `http.log` `trans_depth`). |
| `analyzers` | array | File analyzers that processed this file (e.g., `MD5`, `SHA1`, `SHA256`, `PE`, `Unified2`). |
| `mime_type` | string | Detected MIME type of the file (e.g., `application/pdf`, `image/png`, `application/x-dosexec`). |
| `filename` | string | Filename if extractable from the protocol (e.g., from `Content-Disposition`). Absent if unknown. |
| `duration` | float | How long the transfer took in seconds. |
| `is_orig` | bool | `true` if the file was sent by the connection originator (upload), `false` for download. |
| `seen_bytes` | int | Bytes of file content actually observed by Zeek. |
| `total_bytes` | int | Expected total file size (from `Content-Length` or equivalent). Absent if unknown. |
| `missing_bytes` | int | Bytes Zeek could not observe due to packet loss. |
| `overflow_bytes` | int | Bytes not passed to analyzers because the file exceeded Zeek's analysis size limit. |
| `timedout` | bool | `true` if the file transfer was still in progress when Zeek's timer expired. |
| `md5` | string | MD5 hash of the file content. Only present if the MD5 analyzer ran (not always enabled). |
| `sha1` | string | SHA-1 hash. Present if SHA1 analyzer ran. |
| `sha256` | string | SHA-256 hash. Present if SHA256 analyzer ran. |

### Example files.log event (raw JSON)

```json
{
  "ts": 1741737705.456,
  "fuid": "FaBcD1e2f3",
  "tx_hosts": ["93.184.216.34"],
  "rx_hosts": ["192.168.1.55"],
  "conn_uids": ["CabcXY1234"],
  "source": "HTTP",
  "depth": 1,
  "analyzers": ["MD5", "SHA1"],
  "mime_type": "application/pdf",
  "filename": "document.pdf",
  "duration": 0.312,
  "is_orig": false,
  "seen_bytes": 45312,
  "total_bytes": 45312,
  "missing_bytes": 0,
  "overflow_bytes": 0,
  "timedout": false,
  "md5": "d8e8fca2dc0f896fd7cb4cb0031ba249",
  "sha1": "4e1243bd22c66e76c2ba9eddc1f91394e57f9f83"
}
```

---

## notice.log fields

Each row in `notice.log` is a security notice generated by Zeek's detection
scripts. These are high-signal, low-volume events — Zeek only writes here when
something is genuinely notable. Common notice types include port scans, SSH
brute-force, and protocol policy violations. On a home network you may see
very few of these or none at all.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Timestamp of the notice. |
| `uid` | string | Connection UID if the notice is tied to a specific connection. Absent for scan-level notices. |
| `id.orig_h` / `id.orig_p` | string / int | Source IP/port of the connection that triggered the notice (if applicable). |
| `id.resp_h` / `id.resp_p` | string / int | Destination IP/port. |
| `proto` | string | Transport protocol (`tcp`, `udp`, `icmp`). |
| `note` | string | **The notice type identifier** — a namespaced string like `Scan::Port_Scan`, `SSH::Password_Guessing`, `SSL::Invalid_Server_Cert`. This is the primary field for filtering and categorising alerts. |
| `msg` | string | Human-readable description of the notice. |
| `sub` | string | Sub-message with additional context or evidence (e.g., list of scanned ports). |
| `src` | string | Source address associated with the notice. May differ from `id.orig_h` for scan-type notices that aggregate connections. |
| `dst` | string | Destination address associated with the notice. |
| `p` | int | Associated port number (if relevant to the notice type). |
| `n` | int | A count relevant to the notice (e.g., number of failed SSH attempts). |
| `actions` | array | Actions Zeek applied: `Notice::ACTION_LOG` (always), optionally `Notice::ACTION_EMAIL` or `Notice::ACTION_ALARM`. |
| `suppress_for` | float | Seconds before Zeek will re-emit this notice for the same source/dest pair. Suppressed repeats are not logged. |

### Example notice.log event (raw JSON)

```json
{
  "ts": 1741737800.000,
  "uid": "",
  "id.orig_h": "192.168.1.99",
  "id.orig_p": 0,
  "id.resp_h": "192.168.1.1",
  "id.resp_p": 0,
  "proto": "tcp",
  "note": "Scan::Port_Scan",
  "msg": "192.168.1.99 scanned at least 15 unique ports of host 192.168.1.1 in 0m1s",
  "sub": "Scanned ports: 22, 23, 80, 443, ...",
  "src": "192.168.1.99",
  "dst": "192.168.1.1",
  "p": 0,
  "n": 15,
  "actions": ["Notice::ACTION_LOG"],
  "suppress_for": 3600.0
}
```

---

## weird.log fields

Each row in `weird.log` records a protocol anomaly or unexpected packet
pattern that Zeek's state machine could not classify normally. These are
distinct from notices — Zeek generates a weird entry automatically whenever
the observed traffic violates protocol expectations, without requiring a
detection script. High weird rates from a specific device often indicate
malware C2 traffic, misconfigured applications, or active network scanning.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Timestamp of the anomaly. |
| `uid` | string | Connection UID if the weird is tied to a specific connection. |
| `id.orig_h` / `id.orig_p` | string / int | Source IP/port. |
| `id.resp_h` / `id.resp_p` | string / int | Destination IP/port. |
| `name` | string | **The weird type** — a string identifying the specific anomaly (e.g., `bad_checksum`, `illegal_protocol_state`, `TCP_Christmas_tree_scan`, `above_hole_data_without_any_acks`). This is the primary grouping field. |
| `addl` | string | Additional context about the anomaly (e.g., the unexpected value that triggered it). Absent if no extra context. |
| `notice` | bool | `true` if this weird was also promoted to a `notice.log` entry. |
| `peer` | string | Cluster node that generated this record (relevant in multi-node Zeek clusters; typically a single value on a standalone device). |

### Example weird.log event (raw JSON)

```json
{
  "ts": 1741737900.789,
  "uid": "Cwx1234YYY",
  "id.orig_h": "192.168.1.77",
  "id.orig_p": 54321,
  "id.resp_h": "203.0.113.5",
  "id.resp_p": 443,
  "name": "above_hole_data_without_any_acks",
  "addl": "",
  "notice": false,
  "peer": "zeek"
}
```

---

## acl-audit.log format (different from Zeek logs)

`/alog/acl-audit.log` is **not** Zeek JSON — it's the Firewalla kernel's
iptables `FW_ADT` lines in standard syslog format. Fluent Bit ships the
whole line as `log` with no parser, so APL/LogQL queries either treat
the line as a raw search string or extract fields with a regex.

### Example line

```
May 27 06:46:27 localhost kernel: [652156.583417] [FW_ADT]A=C D=O IN=br0 OUT=eth0 PHYSIN=eth3 MAC=20:6d:31:41:bc:7a:04:7b:cb:c1:4c:ca:08:00 SRC=192.168.139.152 DST=136.226.71.20 LEN=40 TOS=0x00 PREC=0x00 TTL=127 ID=59321 DF PROTO=TCP SPT=50853 DPT=443 WINDOW=255 RES=0x00 ACK FIN URGP=0 MARK=0x85010000
```

### Field-by-field

| Field | Meaning |
|-------|---------|
| `[FW_ADT]` | Firewalla "audit" line marker — distinguishes block events from other kernel log noise. |
| `A=C` / `A=B` | Action: `C` = closed (connection closed after match), `B` = blocked. |
| `D=O` / `D=I` | Direction: `O` = outbound, `I` = inbound. |
| `IN=` / `OUT=` | Interface names. `br0` = LAN bridge; `eth0` = WAN. |
| `MAC=` | Concatenated source MAC + destination MAC + EtherType (15 bytes total). Source MAC = first 6 bytes. |
| `SRC=` / `DST=` | Source / destination IPv4 address. |
| `PROTO=` | Transport protocol (`TCP`, `UDP`, `ICMP`). |
| `SPT=` / `DPT=` | Source / destination ports (TCP/UDP only). |
| `MARK=` | iptables fwmark — encodes which Firewalla rule fired (decoder varies by firmware). |

See [dashboards/axiom-queries.md](../dashboards/axiom-queries.md#blocked-connections) for an APL example that extracts `SRC`/`DST`/`DPT` from these lines.

---

## Related

- [dashboards/axiom-queries.md](../dashboards/axiom-queries.md) — full set of APL queries using these fields
- [Zeek DNS log documentation](https://docs.zeek.org/en/master/scripts/base/protocols/dns/main.zeek.html)
- [Zeek conn log documentation](https://docs.zeek.org/en/master/scripts/base/protocols/conn/main.zeek.html)
- [Zeek SSL log documentation](https://docs.zeek.org/en/master/scripts/base/protocols/ssl/main.zeek.html)
- [Zeek HTTP log documentation](https://docs.zeek.org/en/master/scripts/base/protocols/http/main.zeek.html)
- [Zeek files log documentation](https://docs.zeek.org/en/master/scripts/base/frameworks/files/main.zeek.html)
- [Zeek notice log documentation](https://docs.zeek.org/en/master/scripts/base/frameworks/notice/main.zeek.html)
- [Zeek weird log documentation](https://docs.zeek.org/en/master/scripts/base/frameworks/notice/weird.zeek.html)
