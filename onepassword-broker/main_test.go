package main

import (
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBrokerPingAndResolve(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime", "onepassword.sock")
	secret := "not-a-real-secret\nwith punctuation: !@#$%^&*()"
	done := make(chan error, 1)
	go func() {
		done <- serveSocket(path, func(_ context.Context, reference string) (string, error) {
			if reference != "op://example-vault/example-item/password" {
				t.Errorf("unexpected reference: %q", reference)
			}
			return secret, nil
		}, 250*time.Millisecond)
	}()

	waitForSocket(t, path)
	ping := brokerCall(t, path, request{Operation: "ping"})
	if !ping.OK || ping.Value != "" {
		t.Fatalf("unexpected ping response: %#v", ping)
	}
	resolved := brokerCall(t, path, request{Operation: "resolve", Reference: "op://example-vault/example-item/password"})
	if !resolved.OK || resolved.Value != secret {
		t.Fatal("secret did not round trip exactly")
	}

	if err := <-done; err != nil {
		t.Fatalf("broker stopped with an error: %v", err)
	}
}

func TestBrokerRejectsInvalidReferenceWithoutCallingResolver(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime", "onepassword.sock")
	called := false
	done := make(chan error, 1)
	go func() {
		done <- serveSocket(path, func(_ context.Context, _ string) (string, error) {
			called = true
			return "", nil
		}, 250*time.Millisecond)
	}()

	waitForSocket(t, path)
	response := brokerCall(t, path, request{Operation: "resolve", Reference: "definitely-not-an-op-reference"})
	if response.OK || !strings.Contains(response.Error, "invalid") {
		t.Fatalf("unexpected response: %#v", response)
	}
	if called {
		t.Fatal("resolver was called for an invalid reference")
	}
	if err := <-done; err != nil {
		t.Fatalf("broker stopped with an error: %v", err)
	}
}

func TestServeFlagsIdleTimeout(t *testing.T) {
	account, idle, err := serveFlags([]string{"--account", "example-account"})
	if err != nil || account != "example-account" || idle != 9*time.Minute {
		t.Fatalf("unexpected defaults: account=%q idle=%s err=%v", account, idle, err)
	}

	account, idle, err = serveFlags([]string{"--account", "example-account", "--idle-minutes", "60"})
	if err != nil || account != "example-account" || idle != 60*time.Minute {
		t.Fatalf("unexpected custom timeout: account=%q idle=%s err=%v", account, idle, err)
	}

	for _, value := range []string{"0", "121", "1.5", "not-a-number"} {
		if _, _, err := serveFlags([]string{"--account", "example-account", "--idle-minutes", value}); err == nil {
			t.Fatalf("invalid idle timeout was accepted: %q", value)
		}
	}
}

func waitForSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("unix", path, 20*time.Millisecond)
		if err == nil {
			connection.Close()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("broker socket did not appear: %s", path)
}

func brokerCall(t *testing.T, path string, outgoing request) response {
	t.Helper()
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := json.NewEncoder(connection).Encode(outgoing); err != nil {
		t.Fatal(err)
	}
	var incoming response
	if err := json.NewDecoder(connection).Decode(&incoming); err != nil {
		t.Fatal(err)
	}
	return incoming
}
