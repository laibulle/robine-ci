package runner

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestCreateAndExtractArchive(t *testing.T) {
	workspace := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workspace, "Demo.app", "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(workspace, "Demo.app", "Contents", "MacOS", "Demo")
	if err := os.WriteFile(binary, []byte("mac executable"), 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := createArchive(workspace, []string{"Demo.app"})
	if err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	if err := extractArchive(body, destination, false); err != nil {
		t.Fatal(err)
	}
	extracted, err := os.ReadFile(filepath.Join(destination, "Demo.app", "Contents", "MacOS", "Demo"))
	if err != nil || string(extracted) != "mac executable" {
		t.Fatalf("unexpected extracted file %q: %v", extracted, err)
	}
}

func TestExtractSourceStripsRootAndRejectsUnsafeEntries(t *testing.T) {
	safe := tarGzip(t, map[string]string{"source/project/file.txt": "ok"}, "")
	destination := t.TempDir()
	if err := extractArchive(safe, destination, true); err != nil {
		t.Fatal(err)
	}
	if body, err := os.ReadFile(filepath.Join(destination, "project", "file.txt")); err != nil || string(body) != "ok" {
		t.Fatalf("source not extracted: %q %v", body, err)
	}

	for _, name := range []string{"../escape", "/absolute", "other/file"} {
		body := tarGzip(t, map[string]string{name: "bad"}, "")
		if err := extractArchive(body, t.TempDir(), true); err == nil {
			t.Fatalf("unsafe source entry accepted: %s", name)
		}
	}
	symlink := tarGzip(t, nil, "source/link")
	if err := extractArchive(symlink, t.TempDir(), true); err == nil {
		t.Fatal("symlink entry accepted")
	}
}

func TestCreateArchiveRejectsEscapesAndSymlinks(t *testing.T) {
	workspace := t.TempDir()
	if _, err := createArchive(workspace, []string{"../outside"}); err == nil {
		t.Fatal("path escape accepted")
	}
	if err := os.Symlink("outside", filepath.Join(workspace, "link")); err == nil {
		if _, err := createArchive(workspace, []string{"link"}); err == nil {
			t.Fatal("symlink accepted")
		}
	}
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "value"), []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(workspace, "parent-link")); err == nil {
		if _, err := createArchive(workspace, []string{"parent-link/value"}); err == nil {
			t.Fatal("path through a symlinked parent was accepted")
		}
	}
}

func tarGzip(t *testing.T, files map[string]string, symlink string) []byte {
	t.Helper()
	var output bytes.Buffer
	gz := gzip.NewWriter(&output)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(tw, content); err != nil {
			t.Fatal(err)
		}
	}
	if symlink != "" {
		if err := tw.WriteHeader(&tar.Header{Name: symlink, Mode: 0o777, Typeflag: tar.TypeSymlink, Linkname: "target"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
