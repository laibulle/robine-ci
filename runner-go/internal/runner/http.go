package runner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/robine-ci/robine-runner/internal/config"
)

type transferClient struct {
	client          *http.Client
	runnerID        string
	credential      string
	maxArchiveBytes int64
}

func Enroll(ctx context.Context, options config.EnrollOptions) (config.Config, error) {
	body, err := json.Marshal(map[string]string{"token": options.EnrollmentToken, "name": options.Name})
	if err != nil {
		return config.Config{}, fmt.Errorf("encode enrollment: %w", err)
	}
	endpoint := strings.TrimRight(options.ServerURL, "/") + "/api/v1/runners/enroll"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return config.Config{}, fmt.Errorf("create enrollment request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return config.Config{}, fmt.Errorf("enrollment request: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return config.Config{}, fmt.Errorf("enrollment failed with HTTP %d", response.StatusCode)
	}
	var enrolled enrollmentResponse
	decoder := json.NewDecoder(io.LimitReader(response.Body, 64*1024))
	if err := decoder.Decode(&enrolled); err != nil || enrolled.RunnerID == "" || enrolled.Credential == "" {
		return config.Config{}, errors.New("invalid enrollment response")
	}
	return config.Config{
		ServerURL:         options.ServerURL,
		RunnerID:          enrolled.RunnerID,
		Credential:        enrolled.Credential,
		Name:              options.Name,
		Executor:          options.Executor,
		ResourceNamespace: options.ResourceNamespace,
		CPUMillis:         options.CPUMillis,
		MemoryBytes:       options.MemoryBytes,
		PIDsLimit:         options.PIDsLimit,
	}, nil
}

func newTransferClient(cfg config.Config) *transferClient {
	return &transferClient{
		client:          &http.Client{Timeout: 60 * time.Second},
		runnerID:        cfg.RunnerID,
		credential:      cfg.Credential,
		maxArchiveBytes: config.TransferMaxArchiveBytes(),
	}
}

func (c *transferClient) get(ctx context.Context, endpoint, accept string) ([]byte, http.Header, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("create transfer request: %w", err)
	}
	c.authorize(req)
	req.Header.Set("Accept", accept)
	response, err := c.client.Do(req)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("download transfer: %w", err)
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, c.maxArchiveBytes+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, nil, response.StatusCode, fmt.Errorf("read transfer: %w", err)
	}
	if int64(len(body)) > c.maxArchiveBytes {
		return nil, nil, response.StatusCode, errors.New("download exceeds runner limit")
	}
	if response.StatusCode == http.StatusOK {
		if expected := response.Header.Get("X-Content-Sha256"); expected != "" {
			digest := sha256.Sum256(body)
			if !strings.EqualFold(expected, hex.EncodeToString(digest[:])) {
				return nil, nil, response.StatusCode, errors.New("download digest mismatch")
			}
		}
	}
	return body, response.Header.Clone(), response.StatusCode, nil
}

func (c *transferClient) put(ctx context.Context, endpoint string, query url.Values, body []byte) error {
	if int64(len(body)) > c.maxArchiveBytes {
		return errors.New("upload exceeds runner limit")
	}
	u, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("parse transfer URL: %w", err)
	}
	u.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u.String(), bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create upload request: %w", err)
	}
	c.authorize(req)
	req.Header.Set("Content-Type", "application/gzip")
	req.Header.Set("Accept", "application/json")
	response, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("upload transfer: %w", err)
	}
	defer response.Body.Close()
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if readErr != nil {
		return fmt.Errorf("read upload response: %w", readErr)
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusCreated {
		return fmt.Errorf("upload failed with HTTP %d", response.StatusCode)
	}
	var metadata struct {
		Digest string `json:"digest"`
	}
	if err := json.Unmarshal(responseBody, &metadata); err != nil || metadata.Digest == "" {
		return errors.New("upload response is missing its digest")
	}
	digest := sha256.Sum256(body)
	if !strings.EqualFold(metadata.Digest, hex.EncodeToString(digest[:])) {
		return errors.New("upload response digest mismatch")
	}
	return nil
}

func (c *transferClient) authorize(req *http.Request) {
	req.Header.Set("Authorization", "Bearer "+c.credential)
	req.Header.Set("X-Robine-Runner-Id", c.runnerID)
}
