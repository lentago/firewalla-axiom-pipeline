# Axiom Queries & Dashboard Setup

All queries use [APL (Axiom Processing Language)](https://axiom.co/docs/apl/introduction).
Replace dataset names with your own (e.g., `cjp-firewalla` → `firewalla`).

**Important**: All device joins use **MAC address** (`orig_l2_addr` from Zeek logs
joined to `mac` in the devices dataset). This resolves both IPv4 and IPv6 traffic
to the correct device — the original IP-based join missed all IPv6 queries.

## Canonical device-lookup subquery (latest record per MAC)

The `firewalla-devices` dataset is append-only: `device_lookup_export.sh` writes a
fresh row per device every hour, so a single MAC accumulates many historical rows
(old device names, old groups, and — before the lowercase-MAC fix — old uppercase
MAC keys). Selecting the dataset with a plain `distinct mac, name` returns **all**
of those rows, producing duplicate join matches and stale names.

**Do not** time-scope the device dataset with `| where _time > ago(24h)` to work
around this. That filter is fragile: if the hourly `device_lookup_export.sh` cron
fails for more than 24h, every join silently returns nothing.

Instead, collapse the dataset to the **freshest row per MAC** with
[`arg_max`](https://axiom.co/docs/apl/aggregation-function/arg-max), which returns
the other fields from the row holding the maximum `_time`:

```kusto
['firewalla-devices']
| where record_type == "device_lookup"
| summarize arg_max(_time, name, group) by mac
| project mac, name, group
```

This always resolves each device to its most recent name/group regardless of export
recency, and emits exactly one row per MAC — no duplicates, no `_time` window to
maintain. Use this subquery (projecting whichever of `name`/`group` a given panel
needs) as the right-hand side of every device join below. When a query filters by
group, apply the `| where group == ...` **after** the `arg_max` so devices that
changed groups are matched on their current group, not a stale one.

## Ad-hoc queries (Query tab)

### Top 20 most-queried domains

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| summarize query_count = count() by domain
| order by query_count desc
| take 20
```

### Per-device activity (with device names)

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize unique_domains = dcount(domain), total_queries = count() by device
| order by total_queries desc
```

### Domains visited by a specific device (by MAC)

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where source_mac == "E8:4C:4A:DB:9C:E8"
| where domain != "" and domain != "*"
| summarize query_count = count() by domain
| order by query_count desc
| take 20
```

### Blocked connections

Raw stream:

```kusto
['firewalla']
| where log_source == "firewalla_acl"
```

ACL events arrive as syslog/kernel `FW_ADT` lines (not Zeek JSON — see
[docs/zeek-field-reference.md § acl-audit.log format](../docs/zeek-field-reference.md#acl-auditlog-format-different-from-zeek-logs)).
Extract fields with `extract()` for richer panels:

```kusto
['firewalla']
| where log_source == "firewalla_acl"
| extend action = extract(@"A=([A-Z])", 1, log)        // C = closed, B = blocked
| extend dir    = extract(@"D=([A-Z])", 1, log)        // O = outbound, I = inbound
| extend src_ip = extract(@"SRC=(\S+)", 1, log)
| extend dst_ip = extract(@"DST=(\S+)", 1, log)
| extend dst_port = toint(extract(@"DPT=(\d+)", 1, log))
| extend proto    = extract(@"PROTO=(\S+)", 1, log)
| summarize blocks = count() by src_ip, dst_ip, dst_port, proto
| order by blocks desc
```

### Inspect raw Zeek JSON structure

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| project parsed
| take 1
```

## Dashboard setup

### Step 1: Create Filter Bar (Device)

Create a new dashboard → Add element → **Filter Bar**

- Filter type: **Select**
- Filter name: `Device`
- Filter ID: `_device`
- Value: **Query**
- Query:

```kusto
['firewalla-devices']
| where record_type == "device_lookup"
| summarize arg_max(_time, name) by mac
| project key=name, value=mac
| sort by key asc
```

This populates the dropdown with device names, but the selected _value_ is the
device's MAC address — so chart queries join on MAC and resolve both IPv4 and IPv6.

### Step 2: Top Domains table

Add element → **Table** → APL mode:

```kusto
declare query_parameters(_device:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where source_mac == _device
| where domain != "" and domain != "*"
| summarize query_count = count() by domain
| order by query_count desc
```

### Step 3: DNS Activity Over Time

Add element → **Time Series** → APL mode:

```kusto
declare query_parameters(_device:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| where source_mac == _device
| summarize queries = count() by bin_auto(_time)
```

### Step 4: Raw DNS Events

Add element → **Log Stream** → APL mode:

```kusto
declare query_parameters(_device:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where source_mac == _device
| where domain != "" and domain != "*"
| project _time, domain, source_mac
```

## Notes on Zeek JSON field names

Zeek uses dotted field names like `id.orig_h`. In APL, use bracket notation:

```kusto
| extend source_ip = tostring(parsed["id.orig_h"])
```

Not:

```kusto
| extend source_ip = tostring(parsed.id.orig_h)  // WRONG — treats as nested path
```

The key field for MAC-based joins is `orig_l2_addr` (source device MAC) and
`resp_l2_addr` (destination/responder MAC).

## Group-based dashboards

These queries require the `group` field in your devices dataset, which is
populated by the updated `device_lookup_export.sh` reading from `device_groups.json`.

### DNS volume by group (pie chart)

Shows which device groups generate the most DNS traffic.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, group) by mac
    | project mac, group
) on $left.source_mac == $right.mac
| extend device_group = coalesce(group, "Unknown")
| summarize query_count = count() by device_group
| order by query_count desc
```

### Group activity over time (stacked time series)

Shows the household rhythm — work spikes weekday mornings, entertainment
ramps up evenings, IoT is constant.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, group) by mac
    | project mac, group
) on $left.source_mac == $right.mac
| extend device_group = coalesce(group, "Unknown")
| summarize queries = count() by bin_auto(_time), device_group
```

### Group dashboard with filter bar

Add a **Filter Bar** with a group selector:

- Filter name: `Group`
- Filter ID: `_group`
- Value: **Query**

```kusto
['firewalla-devices']
| where record_type == "device_lookup"
| summarize arg_max(_time, group) by mac
| distinct group
| project key=group, value=group
| sort by key asc
```

Then use this in chart queries:

```kusto
declare query_parameters(_group:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=inner (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name, group) by mac
    | where group == _group
    | project mac, name
) on $left.source_mac == $right.mac
| summarize query_count = count() by name, domain
| order by query_count desc
```

### IoT Accountability Board

Shows exactly what your smart home devices are phoning home to.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=inner (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name, group) by mac
    | where group == "IoT" or group == "Smart Home"
    | project mac, name
) on $left.source_mac == $right.mac
| summarize query_count = count() by name, domain
| order by query_count desc
```

### New Domain Radar

Finds domains queried for the first time today by any device. A sudden
burst of new domains from an IoT device is a strong compromise signal.

```kusto
let today_domains =
['firewalla']
| where log_source == "zeek_dns"
| where _time > ago(24h)
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| distinct source_mac, domain;
let historical_domains =
['firewalla']
| where log_source == "zeek_dns"
| where _time > ago(30d) and _time < ago(24h)
| extend parsed = parse_json(log)
| extend domain = tostring(parse_json(log)["query"])
| where domain != "" and domain != "*"
| distinct domain;
today_domains
| join kind=leftanti historical_domains on domain
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name, group) by mac
    | project mac, name, group
) on $left.source_mac == $right.mac
| summarize new_domains = dcount(domain), domains = make_set(domain) by name, group
| order by new_domains desc
```

### Kids Activity Summary

Quick view of what the kids' devices are doing — great for screen time conversations.

```kusto
declare query_parameters(_group:string = "Kids");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=inner (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name, group) by mac
    | where group == _group or group == "Kids-TVs"
    | project mac, name
) on $left.source_mac == $right.mac
| summarize query_count = count() by name, domain
| order by query_count desc
```

### Device Activity Heatmap

Shows which devices are active at which hours — reveals patterns like
IoT phoning home at 2am or kids sneaking screen time.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend hour = hourofday(_time)
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name, group) by mac
    | project mac, name, group
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize queries = count() by device, hour
| order by hour asc
```

### Bandwidth Estimation (using conn.log)

Top destinations by estimated bytes transferred. Requires conn.log data.

```kusto
['firewalla']
| where log_source == "zeek_conn"
| extend parsed = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend dest_ip = tostring(parsed["id.resp_h"])
| extend orig_bytes = tolong(parsed["orig_bytes"]), resp_bytes = tolong(parsed["resp_bytes"])
| extend total_bytes = orig_bytes + resp_bytes
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name, group) by mac
    | project mac, name, group
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize total_traffic = sum(total_bytes) by device, group
| extend traffic_mb = round(total_traffic / 1048576.0, 2)
| order by total_traffic desc
```

---

## HTTP log queries (zeek_http)

### Top HTTP hosts by request count

```kusto
['firewalla']
| where log_source == "zeek_http"
| extend parsed = parse_json(log)
| extend host = tostring(parsed["host"])
| where isnotempty(host)
| summarize requests = count() by host
| order by requests desc
| take 25
```

### HTTP 4xx/5xx errors by device

Surfaces misconfigured or misbehaving devices generating failed requests.

```kusto
['firewalla']
| where log_source == "zeek_http"
| extend parsed      = parse_json(log)
| extend source_mac  = tostring(parsed["orig_l2_addr"])
| extend host        = tostring(parsed["host"])
| extend uri         = tostring(parsed["uri"])
| extend status_code = toint(parsed["status_code"])
| where status_code >= 400
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize errors = count() by device, host, status_code
| order by errors desc
```

### User-agent fingerprinting — unique clients

Unexpected user-agents on known devices can indicate compromised software or rogue processes.

```kusto
['firewalla']
| where log_source == "zeek_http"
| extend parsed     = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend user_agent = tostring(parsed["user_agent"])
| where isnotempty(user_agent)
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize request_count = count() by device, user_agent
| order by request_count desc
```

### Large HTTP downloads (response body > 1 MB)

```kusto
['firewalla']
| where log_source == "zeek_http"
| extend parsed            = parse_json(log)
| extend source_mac        = tostring(parsed["orig_l2_addr"])
| extend host              = tostring(parsed["host"])
| extend uri               = tostring(parsed["uri"])
| extend response_body_len = tolong(parsed["response_body_len"])
| where response_body_len > 1048576
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device    = coalesce(name, source_mac)
| extend size_mb   = round(response_body_len / 1048576.0, 2)
| project _time, device, host, uri, size_mb
| order by size_mb desc
```

---

## Files log queries (zeek_files)

### MIME-type breakdown — what types of content are being transferred

```kusto
['firewalla']
| where log_source == "zeek_files"
| extend parsed    = parse_json(log)
| extend mime_type = tostring(parsed["mime_type"])
| extend source    = tostring(parsed["source"])
| where isnotempty(mime_type)
| summarize transfers = count(), total_bytes = sum(tolong(parsed["seen_bytes"])) by mime_type, source
| extend total_mb = round(total_bytes / 1048576.0, 2)
| order by transfers desc
```

### Executable files downloaded (PE/ELF binaries)

High-risk downloads worth reviewing regardless of the source.

```kusto
['firewalla']
| where log_source == "zeek_files"
| extend parsed    = parse_json(log)
| extend mime_type = tostring(parsed["mime_type"])
| extend rx_hosts  = tostring(parsed["rx_hosts"])
| extend tx_hosts  = tostring(parsed["tx_hosts"])
| extend filename  = tostring(parsed["filename"])
| extend seen_bytes = tolong(parsed["seen_bytes"])
| where mime_type in ("application/x-dosexec", "application/x-elf",
                      "application/x-executable", "application/x-msdownload",
                      "application/vnd.microsoft.portable-executable")
| project _time, rx_hosts, tx_hosts, filename, mime_type, seen_bytes
| order by _time desc
```

### Large file transfers by receiving device

```kusto
['firewalla']
| where log_source == "zeek_files"
| extend parsed     = parse_json(log)
| extend rx_hosts   = tostring(parsed["rx_hosts"])
| extend mime_type  = tostring(parsed["mime_type"])
| extend seen_bytes = tolong(parsed["seen_bytes"])
| where seen_bytes > 1048576
| summarize transfers = count(), total_bytes = sum(seen_bytes) by rx_hosts, mime_type
| extend total_mb = round(total_bytes / 1048576.0, 2)
| order by total_bytes desc
```

---

## Notice log queries (zeek_notice)

### Notice alerts overview — all notice types in window

```kusto
['firewalla']
| where log_source == "zeek_notice"
| extend parsed = parse_json(log)
| extend note   = tostring(parsed["note"])
| extend msg    = tostring(parsed["msg"])
| extend src    = tostring(parsed["src"])
| extend dst    = tostring(parsed["dst"])
| summarize count = count() by note
| order by count desc
```

### Notice alert stream with device names

```kusto
['firewalla']
| where log_source == "zeek_notice"
| extend parsed     = parse_json(log)
| extend note       = tostring(parsed["note"])
| extend msg        = tostring(parsed["msg"])
| extend src        = tostring(parsed["src"])
| extend dst        = tostring(parsed["dst"])
| extend source_mac = tostring(parsed["orig_l2_addr"])
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| project _time, device, note, msg, src, dst
| order by _time desc
```

### Port scan detections over time

```kusto
['firewalla']
| where log_source == "zeek_notice"
| extend parsed = parse_json(log)
| extend note   = tostring(parsed["note"])
| extend src    = tostring(parsed["src"])
| where note startswith "Scan::"
| summarize scans = count() by src, note, bin_auto(_time)
| order by _time desc
```

---

## Weird log queries (zeek_weird)

### Protocol anomalies by type — top weird names

```kusto
['firewalla']
| where log_source == "zeek_weird"
| extend parsed = parse_json(log)
| extend name   = tostring(parsed["name"])
| where isnotempty(name)
| summarize count = count() by name
| order by count desc
| take 20
```

### Anomalies by device — which hosts are generating weirdness

A device suddenly generating many weirdness entries is worth investigating.

```kusto
['firewalla']
| where log_source == "zeek_weird"
| extend parsed     = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend name       = tostring(parsed["name"])
| where isnotempty(source_mac)
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize anomalies = count() by device, name
| order by anomalies desc
```

### Weird anomaly rate over time (spike detection)

A spike in weird entries from a device can indicate active malware or scanning activity.

```kusto
['firewalla']
| where log_source == "zeek_weird"
| extend parsed     = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | summarize arg_max(_time, name) by mac
    | project mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
| summarize anomalies = count() by device, bin_auto(_time)
| order by _time desc
```
