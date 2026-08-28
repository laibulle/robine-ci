package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"net/url"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/robine-ci/robine-runner/internal/config"
)

const runnerTopic = "runner:v1"

var errConnectionLost = errors.New("runner connection lost")

type channelHandler interface {
	ActiveAttemptIDs() []string
	HandleEvent(context.Context, string, json.RawMessage)
	HandleHeartbeat(map[string]any)
}

type channelClient struct {
	config  config.Config
	version string
	handler channelHandler

	mu      sync.Mutex
	conn    *websocket.Conn
	ready   chan struct{}
	lost    chan struct{}
	pending map[string]chan channelReply
	writeMu sync.Mutex
	nextRef atomic.Uint64
}

func newChannelClient(cfg config.Config, version string, handler channelHandler) *channelClient {
	client := &channelClient{
		config:  cfg,
		version: version,
		handler: handler,
		ready:   make(chan struct{}),
		lost:    make(chan struct{}),
		pending: make(map[string]chan channelReply),
	}
	client.nextRef.Store(1)
	return client
}

func (c *channelClient) Run(ctx context.Context) error {
	attempt := 0
	for ctx.Err() == nil {
		if err := c.runSession(ctx); err != nil && ctx.Err() == nil {
			attempt++
			delay := reconnectDelay(attempt)
			log.Printf("connection unavailable: %v; reconnecting in %s", err, delay)
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
			case <-timer.C:
			}
		} else {
			attempt = 0
		}
	}
	return ctx.Err()
}

func (c *channelClient) runSession(ctx context.Context) error {
	socketURL, err := websocketURL(c.config.ServerURL)
	if err != nil {
		return err
	}
	headers := http.Header{}
	headers.Set("X-Robine-Runner-Id", c.config.RunnerID)
	headers.Set("X-Robine-Runner-Credential", c.config.Credential)
	dialer := websocket.Dialer{HandshakeTimeout: 30 * time.Second, Proxy: http.ProxyFromEnvironment}
	conn, response, err := dialer.DialContext(ctx, socketURL, headers)
	if err != nil {
		if response != nil {
			return fmt.Errorf("websocket handshake HTTP %d: %w", response.StatusCode, err)
		}
		return fmt.Errorf("websocket handshake: %w", err)
	}
	conn.SetReadLimit(maxControlMessage)
	if err := c.join(ctx, conn); err != nil {
		conn.Close()
		return err
	}
	c.connect(conn)
	defer c.disconnect(conn)
	log.Printf("runner connected with protocol v1 as %s", c.config.RunnerID)
	closed := make(chan struct{})
	defer close(closed)
	go func() {
		select {
		case <-ctx.Done():
			c.writeMu.Lock()
			_ = conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "runner stopping"), time.Now().Add(time.Second))
			c.writeMu.Unlock()
			_ = conn.Close()
		case <-closed:
		}
	}()

	heartbeatCtx, stopHeartbeat := context.WithCancel(ctx)
	defer stopHeartbeat()
	go c.heartbeatLoop(heartbeatCtx)

	for {
		messageType, payload, err := conn.ReadMessage()
		if err != nil {
			return errConnectionLost
		}
		if messageType != websocket.TextMessage || len(payload) > maxControlMessage {
			return errors.New("invalid control frame")
		}
		if err := c.handleFrame(ctx, payload); err != nil {
			return err
		}
	}
}

func (c *channelClient) join(ctx context.Context, conn *websocket.Conn) error {
	hello := map[string]any{
		"supported_protocol_versions": []int{1},
		"software_version":            c.version,
		"capabilities":                capabilities(),
		"active_attempt_ids":          c.handler.ActiveAttemptIDs(),
		"active_deployment_ids":       []string{},
	}
	if err := conn.WriteJSON([]any{"1", "1", runnerTopic, "phx_join", hello}); err != nil {
		return fmt.Errorf("send channel join: %w", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	_, payload, err := conn.ReadMessage()
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		return fmt.Errorf("read channel join: %w", err)
	}
	frame, err := decodeFrame(payload)
	if err != nil || frame.Event != "phx_reply" || frame.Reference != "1" || frame.Topic != runnerTopic {
		return errors.New("invalid channel join response")
	}
	var reply channelReply
	if err := json.Unmarshal(frame.Payload, &reply); err != nil {
		return errors.New("invalid runner protocol negotiation response")
	}
	if reply.Status != "ok" {
		if code, ok := reply.Response["code"].(string); ok && code != "" {
			return fmt.Errorf("runner protocol negotiation rejected: %s", code)
		}
		return errors.New("runner protocol negotiation rejected")
	}
	if reply.Response["protocol_version"] != float64(1) {
		return errors.New("runner protocol negotiation rejected")
	}
	return nil
}

func (c *channelClient) Request(ctx context.Context, event string, payload any) (map[string]any, error) {
	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode %s: %w", event, err)
	}
	for ctx.Err() == nil {
		conn, lost, err := c.waitConnection(ctx)
		if err != nil {
			return nil, err
		}
		reference := strconv.FormatUint(c.nextRef.Add(1), 10)
		replyCh := make(chan channelReply, 1)
		c.mu.Lock()
		if c.conn != conn {
			c.mu.Unlock()
			continue
		}
		c.pending[reference] = replyCh
		c.mu.Unlock()

		frame := []any{"1", reference, runnerTopic, event, json.RawMessage(encodedPayload)}
		c.writeMu.Lock()
		err = conn.WriteJSON(frame)
		c.writeMu.Unlock()
		if err != nil {
			c.removePending(reference)
			continue
		}

		select {
		case reply := <-replyCh:
			if reply.Status != "ok" {
				return nil, fmt.Errorf("%s rejected: %v", event, reply.Response)
			}
			return reply.Response, nil
		case <-lost:
			c.removePending(reference)
			continue
		case <-ctx.Done():
			c.removePending(reference)
			return nil, ctx.Err()
		}
	}
	return nil, ctx.Err()
}

func (c *channelClient) handleFrame(ctx context.Context, payload []byte) error {
	frame, err := decodeFrame(payload)
	if err != nil {
		return err
	}
	if frame.Topic != runnerTopic {
		return errors.New("unexpected channel topic")
	}
	if frame.Event == "phx_reply" {
		var reply channelReply
		if err := json.Unmarshal(frame.Payload, &reply); err != nil {
			return errors.New("invalid channel reply")
		}
		c.mu.Lock()
		waiting := c.pending[frame.Reference]
		delete(c.pending, frame.Reference)
		c.mu.Unlock()
		if waiting != nil {
			waiting <- reply
		}
		return nil
	}
	go c.handler.HandleEvent(ctx, frame.Event, frame.Payload)
	return nil
}

func (c *channelClient) heartbeatLoop(ctx context.Context) {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			heartbeatCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
			response, err := c.Request(heartbeatCtx, "heartbeat", map[string]any{})
			cancel()
			if err == nil {
				c.handler.HandleHeartbeat(response)
			}
		}
	}
}

func (c *channelClient) waitConnection(ctx context.Context) (*websocket.Conn, <-chan struct{}, error) {
	for {
		c.mu.Lock()
		conn, ready, lost := c.conn, c.ready, c.lost
		c.mu.Unlock()
		if conn != nil {
			return conn, lost, nil
		}
		select {
		case <-ready:
		case <-ctx.Done():
			return nil, nil, ctx.Err()
		}
	}
}

func (c *channelClient) connect(conn *websocket.Conn) {
	c.mu.Lock()
	c.conn = conn
	close(c.ready)
	c.mu.Unlock()
}

func (c *channelClient) disconnect(conn *websocket.Conn) {
	c.mu.Lock()
	if c.conn == conn {
		c.conn = nil
		close(c.lost)
		c.ready = make(chan struct{})
		c.lost = make(chan struct{})
	}
	c.mu.Unlock()
	_ = conn.Close()
}

func (c *channelClient) removePending(reference string) {
	c.mu.Lock()
	delete(c.pending, reference)
	c.mu.Unlock()
}

type decodedFrame struct {
	Reference string
	Topic     string
	Event     string
	Payload   json.RawMessage
}

func decodeFrame(payload []byte) (decodedFrame, error) {
	var parts []json.RawMessage
	if err := json.Unmarshal(payload, &parts); err != nil || len(parts) != 5 {
		return decodedFrame{}, errors.New("invalid Phoenix channel frame")
	}
	var reference, topic, event string
	if err := json.Unmarshal(parts[1], &reference); err != nil {
		return decodedFrame{}, errors.New("invalid Phoenix reference")
	}
	if err := json.Unmarshal(parts[2], &topic); err != nil {
		return decodedFrame{}, errors.New("invalid Phoenix topic")
	}
	if err := json.Unmarshal(parts[3], &event); err != nil {
		return decodedFrame{}, errors.New("invalid Phoenix event")
	}
	return decodedFrame{Reference: reference, Topic: topic, Event: event, Payload: parts[4]}, nil
}

func websocketURL(serverURL string) (string, error) {
	u, err := url.Parse(serverURL)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", errors.New("unsupported server scheme")
	}
	u.Path = "/runner/socket/websocket"
	u.RawQuery = "vsn=2.0.0"
	u.Fragment = ""
	return u.String(), nil
}

func capabilities() map[string]any {
	architecture := runtime.GOARCH
	operatingSystem := runtime.GOOS
	if operatingSystem == "darwin" {
		operatingSystem = "macos"
	}
	if architecture == "386" {
		architecture = "x86"
	}
	return map[string]any{
		"os":           operatingSystem,
		"architecture": architecture,
		"docker":       false,
		"native":       true,
		"executor":     "native",
		"deployments":  false,
		"concurrency":  1,
	}
}

func reconnectDelay(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	ceiling := 250 * time.Millisecond
	for i := 1; i < attempt && ceiling < 30*time.Second; i++ {
		ceiling *= 2
	}
	if ceiling > 30*time.Second {
		ceiling = 30 * time.Second
	}
	return time.Duration(rand.Int64N(int64(ceiling) + 1))
}

func parseStringSlice(value any) []string {
	raw, ok := value.([]any)
	if !ok {
		return nil
	}
	result := make([]string, 0, len(raw))
	for _, entry := range raw {
		if text, ok := entry.(string); ok && strings.TrimSpace(text) != "" {
			result = append(result, text)
		}
	}
	return result
}
