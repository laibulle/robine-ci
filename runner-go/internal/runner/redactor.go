package runner

import (
	"bytes"
	"sort"
)

type redactor struct {
	secrets [][]byte
	pending []byte
}

func newRedactor(values map[string]string) *redactor {
	secrets := make([][]byte, 0, len(values))
	seen := make(map[string]struct{})
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		secrets = append(secrets, []byte(value))
	}
	sort.Slice(secrets, func(i, j int) bool { return len(secrets[i]) > len(secrets[j]) })
	return &redactor{secrets: secrets}
}

func (r *redactor) Push(chunk []byte) []byte {
	r.pending = append(r.pending, chunk...)
	return r.consume(false)
}

func (r *redactor) Finish() []byte {
	return r.consume(true)
}

func (r *redactor) consume(final bool) []byte {
	var output bytes.Buffer
	for len(r.pending) > 0 {
		matched := false
		for _, secret := range r.secrets {
			if len(r.pending) >= len(secret) && bytes.Equal(r.pending[:len(secret)], secret) {
				output.WriteString("[REDACTED]")
				r.pending = r.pending[len(secret):]
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		if !final && r.incompleteSecretPrefix(r.pending) {
			break
		}
		output.WriteByte(r.pending[0])
		r.pending = r.pending[1:]
	}
	return output.Bytes()
}

func (r *redactor) incompleteSecretPrefix(value []byte) bool {
	for _, secret := range r.secrets {
		if len(value) < len(secret) && bytes.Equal(value, secret[:len(value)]) {
			return true
		}
	}
	return false
}
