# Code Style — istio midstream

- Follow upstream Istio Go style (effectively Google Go style).
- Do **not** modify protobuf-generated files (`*.pb.go`, `*.gen.go`). Re-run codegen instead.
- KRT (Kubernetes Resource Tracker) patterns: use `krt.Collection`, `krt.Join`, `krt.FetchOne` — avoid direct informer access.
- xDS push context: changes to `PushContext` must benchmark allocation impact.
- Keep OSSM-specific code minimal and always annotated with `// OSSM-only: <JIRA-KEY> <reason>`.
- Do not introduce new dependencies without opening an upstream issue first.
