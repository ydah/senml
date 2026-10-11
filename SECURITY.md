# Security

Report vulnerabilities privately through [GitHub security advisories](https://github.com/ydah/senml/security/advisories/new).

Parsing does not perform network requests or execute measurement content. Inputs have configurable byte, record, depth, and binary-data limits. Streaming applies per-record limits before retaining further bytes. The built-in Ruby CBOR decoder checks structural limits while reading, rejects duplicate map keys, and never evaluates tags as application code.

Unknown critical labels and unsupported or mixed format versions fail even in lenient mode. Noncritical extension data is retained without interpretation. Applications must decide which sensor names, units, content formats, values, and timestamps they trust. Conversion and resolution do not authenticate measurements.

Use bounds appropriate to the application's workload. Parsing a complete pack and resolving it require memory proportional to the pack; use the JSON stream reader when whole-pack sorting is unnecessary. A stream can yield valid records before a later malformed record raises an error, so callers needing atomic ingestion must provide their own transaction boundary.

Lenient diagnostics stop with `LimitError` at `max_warnings` (default 1,000). Inherited base strings are immutable and shared; resolution stops before expanded output exceeds `max_bytes`. Unknown base context also prevents resolution of later records.
