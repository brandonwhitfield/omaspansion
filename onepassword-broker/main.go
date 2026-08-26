package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	onepassword "github.com/1password/onepassword-sdk-go"
)

const (
	integrationName    = "Omaspansion"
	integrationVersion = "v0.1.0-beta.4"
	defaultIdleMinutes = 9
	minimumIdleMinutes = 1
	maximumIdleMinutes = 120
	requestTimeout     = 75 * time.Second
)

type request struct {
	Operation string `json:"operation"`
	Reference string `json:"reference,omitempty"`
}

type response struct {
	OK    bool   `json:"ok"`
	Value string `json:"value,omitempty"`
	Error string `json:"error,omitempty"`
}

type resolveFunc func(context.Context, string) (string, error)

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	var err error
	switch os.Args[1] {
	case "authorize":
		err = authorize(os.Args[2:])
	case "serve":
		err = serve(os.Args[2:])
	case "ping":
		err = callBroker(request{Operation: "ping"}, io.Discard)
	case "resolve":
		if len(os.Args) != 3 {
			usage()
		}
		err = resolve(os.Args[2])
	default:
		usage()
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: onepassword-broker authorize --account ACCOUNT | serve --account ACCOUNT [--idle-minutes 1..120] | ping | resolve OP_REFERENCE")
	os.Exit(2)
}

func accountFlag(command string, args []string) (string, error) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	account := flags.String("account", "", "1Password account name or UUID")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *account == "" {
		return "", fmt.Errorf("usage: onepassword-broker %s --account ACCOUNT", command)
	}
	return *account, nil
}

func serveFlags(args []string) (string, time.Duration, error) {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	account := flags.String("account", "", "1Password account name or UUID")
	idleMinutes := flags.Int("idle-minutes", defaultIdleMinutes, "broker idle timeout in minutes")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *account == "" ||
		*idleMinutes < minimumIdleMinutes || *idleMinutes > maximumIdleMinutes {
		return "", 0, errors.New("usage: onepassword-broker serve --account ACCOUNT [--idle-minutes 1..120]")
	}
	return *account, time.Duration(*idleMinutes) * time.Minute, nil
}

func newClient(ctx context.Context, account string) (*onepassword.Client, error) {
	client, err := onepassword.NewClient(
		ctx,
		onepassword.WithDesktopAppIntegration(account),
		onepassword.WithIntegrationInfo(integrationName, integrationVersion),
	)
	if err != nil {
		return nil, fmt.Errorf("1Password authorization failed: %w", err)
	}
	return client, nil
}

func authorize(args []string) error {
	account, err := accountFlag("authorize", args)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	if _, err := newClient(ctx, account); err != nil {
		return err
	}
	fmt.Println("1Password SDK authorization succeeded. No vaults, items, or secrets were accessed.")
	return nil
}

func serve(args []string) error {
	account, idleTimeout, err := serveFlags(args)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	client, err := newClient(ctx, account)
	cancel()
	if err != nil {
		return err
	}

	return serveSocket(socketPath(), func(ctx context.Context, reference string) (string, error) {
		return client.Secrets().Resolve(ctx, reference)
	}, idleTimeout)
}

func socketPath() string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = fmt.Sprintf("/run/user/%d", os.Getuid())
	}
	return filepath.Join(runtimeDir, "omaspansion", "onepassword.sock")
}

func serveSocket(path string, resolver resolveFunc, idle time.Duration) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create broker directory: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return fmt.Errorf("secure broker directory: %w", err)
	}

	if existing, err := net.DialTimeout("unix", path, 250*time.Millisecond); err == nil {
		existing.Close()
		return errors.New("a 1Password broker is already running")
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale broker socket: %w", err)
	}

	listener, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("listen on broker socket: %w", err)
	}
	defer listener.Close()
	defer os.Remove(path)
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("secure broker socket: %w", err)
	}

	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-signalContext.Done()
		listener.Close()
	}()

	unixListener := listener.(*net.UnixListener)
	for {
		if err := unixListener.SetDeadline(time.Now().Add(idle)); err != nil {
			return fmt.Errorf("set broker deadline: %w", err)
		}
		connection, err := listener.Accept()
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				return nil
			}
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("accept broker request: %w", err)
		}

		fatal := handleConnection(connection, resolver)
		connection.Close()
		if fatal {
			return errors.New("secret resolution failed; broker stopped so the next attempt can reauthorize")
		}
	}
}

func handleConnection(connection net.Conn, resolver resolveFunc) bool {
	_ = connection.SetDeadline(time.Now().Add(requestTimeout))
	decoder := json.NewDecoder(io.LimitReader(connection, 8192))
	encoder := json.NewEncoder(connection)

	var incoming request
	if err := decoder.Decode(&incoming); err != nil {
		_ = encoder.Encode(response{Error: "invalid broker request"})
		return false
	}

	switch incoming.Operation {
	case "ping":
		_ = encoder.Encode(response{OK: true})
		return false
	case "resolve":
		ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
		defer cancel()
		if err := onepassword.Secrets.ValidateSecretReference(ctx, incoming.Reference); err != nil {
			_ = encoder.Encode(response{Error: "invalid 1Password secret reference"})
			return false
		}
		value, err := resolver(ctx, incoming.Reference)
		if err != nil {
			_ = encoder.Encode(response{Error: "1Password could not resolve that reference"})
			return true
		}
		_ = encoder.Encode(response{OK: true, Value: value})
		return false
	default:
		_ = encoder.Encode(response{Error: "unsupported broker operation"})
		return false
	}
}

func resolve(reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := onepassword.Secrets.ValidateSecretReference(ctx, reference); err != nil {
		return errors.New("invalid 1Password secret reference")
	}
	return callBroker(request{Operation: "resolve", Reference: reference}, os.Stdout)
}

func callBroker(outgoing request, destination io.Writer) error {
	connection, err := net.DialTimeout("unix", socketPath(), time.Second)
	if err != nil {
		return errors.New("1Password broker is not running")
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(requestTimeout))

	if err := json.NewEncoder(connection).Encode(outgoing); err != nil {
		return fmt.Errorf("send broker request: %w", err)
	}
	var incoming response
	if err := json.NewDecoder(connection).Decode(&incoming); err != nil {
		return fmt.Errorf("read broker response: %w", err)
	}
	if !incoming.OK {
		if incoming.Error == "" {
			incoming.Error = "1Password broker rejected the request"
		}
		return errors.New(incoming.Error)
	}
	if outgoing.Operation == "resolve" {
		_, err = io.WriteString(destination, incoming.Value)
		return err
	}
	return nil
}
