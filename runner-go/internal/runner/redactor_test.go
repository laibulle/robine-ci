package runner

import "testing"

func TestRedactorMasksSecretsAcrossChunkBoundaries(t *testing.T) {
	redactor := newRedactor(map[string]string{"TOKEN": "very-secret", "SHORT": "sec", "EMPTY": ""})
	var output []byte
	for _, chunk := range [][]byte{[]byte("before very-"), []byte("secret and s"), []byte("ec after")} {
		output = append(output, redactor.Push(chunk)...)
	}
	output = append(output, redactor.Finish()...)
	if got, want := string(output), "before [REDACTED] and [REDACTED] after"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestRedactorFlushesIncompletePrefix(t *testing.T) {
	redactor := newRedactor(map[string]string{"TOKEN": "secret"})
	if output := redactor.Push([]byte("not-secr")); string(output) != "not-" {
		t.Fatalf("unexpected early output %q", output)
	}
	if output := redactor.Finish(); string(output) != "secr" {
		t.Fatalf("unexpected tail %q", output)
	}
}
