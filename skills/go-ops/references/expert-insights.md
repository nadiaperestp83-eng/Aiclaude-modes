# Go HTTP and Service Patterns Reference

## Table of Contents

1. [HTTP Server (Go 1.22+ Routing)](#1-http-server-go-122-routing)
2. [Graceful Shutdown](#2-graceful-shutdown)
3. [HTTP Client Configuration](#3-http-client-configuration)
4. [JSON Request/Response Helpers](#4-json-requestresponse-helpers)

---

## 1. HTTP Server (Go 1.22+ Routing)

Go 1.22 added method matching and path wildcards to `net/http.ServeMux` — no router dependency needed for most services.

```go
func main() {
    mux := http.NewServeMux()

    mux.HandleFunc("GET /users/{id}", getUser)
    mux.HandleFunc("POST /users", createUser)

    server := &http.Server{
        Addr:         ":8080",
        Handler:      mux,
        ReadTimeout:  5 * time.Second,
        WriteTimeout: 10 * time.Second,
        IdleTimeout:  120 * time.Second,
    }

    log.Fatal(server.ListenAndServe())
}

func getUser(w http.ResponseWriter, r *http.Request) {
    id := r.PathValue("id") // Wildcard value from the pattern

    user, err := userStore.GetUser(id)
    if err != nil {
        http.Error(w, "User not found", http.StatusNotFound)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(user)
}
```

Always set `ReadTimeout`, `WriteTimeout`, and `IdleTimeout` on `http.Server` — the zero values mean no timeout, which leaves the server open to slow-client resource exhaustion.

## 2. Graceful Shutdown

Drain in-flight requests on SIGINT/SIGTERM instead of dropping them.

```go
func main() {
    cfg, err := config.Load()
    if err != nil {
        log.Fatalf("loading config: %v", err)
    }

    server := &http.Server{
        Addr:    cfg.Addr,
        Handler: handler.New(cfg),
    }

    go func() {
        sigCh := make(chan os.Signal, 1)
        signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
        <-sigCh

        ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
        defer cancel()

        if err := server.Shutdown(ctx); err != nil {
            log.Printf("shutdown error: %v", err)
        }
    }()

    log.Printf("starting server on %s", cfg.Addr)
    if err := server.ListenAndServe(); err != http.ErrServerClosed {
        log.Fatalf("server error: %v", err)
    }
}
```

`server.Shutdown` stops accepting new connections, then waits for active requests up to the context deadline. Compare against `http.ErrServerClosed` — a clean shutdown returns it, and treating it as fatal masks the difference between intentional and crashed exits.

## 3. HTTP Client Configuration

Never use `http.DefaultClient` for production calls — it has no timeout. Build a client once and reuse it (the transport pools connections).

```go
func NewHTTPClient() *http.Client {
    return &http.Client{
        Timeout: 30 * time.Second,
        Transport: &http.Transport{
            MaxIdleConns:        100,
            MaxIdleConnsPerHost: 10,
            IdleConnTimeout:     90 * time.Second,
        },
    }
}

func fetchJSON(ctx context.Context, url string, result any) error {
    req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
    if err != nil {
        return err
    }

    resp, err := httpClient.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return fmt.Errorf("unexpected status: %d", resp.StatusCode)
    }

    return json.NewDecoder(resp.Body).Decode(result)
}
```

`MaxIdleConnsPerHost` defaults to 2 — far too low when hammering a single upstream; raise it for service-to-service traffic.

## 4. JSON Request/Response Helpers

Centralize encoding/decoding so every handler behaves the same.

```go
type Response struct {
    Data    any    `json:"data,omitempty"`
    Error   string `json:"error,omitempty"`
    Message string `json:"message,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, data any) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)
    json.NewEncoder(w).Encode(data)
}

func readJSON(r *http.Request, dst any) error {
    dec := json.NewDecoder(r.Body)
    dec.DisallowUnknownFields() // Reject payloads with unexpected keys

    if err := dec.Decode(dst); err != nil {
        return fmt.Errorf("decoding JSON: %w", err)
    }
    return nil
}
```

`DisallowUnknownFields` turns silent typos in client payloads (`"emial"`) into explicit 400s instead of zero-valued fields.
