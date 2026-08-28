package runner

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	maxArchiveFiles    = 10_000
	maxExpandedBytes   = int64(1_000_000_000)
	maxArchivePathSize = 4096
)

func extractArchive(body []byte, destination string, stripRoot bool) error {
	gz, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return errors.New("invalid gzip archive")
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	files := 0
	var expanded int64
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read archive: %w", err)
		}
		files++
		if files > maxArchiveFiles {
			return errors.New("archive file-count limit exceeded")
		}
		name, err := safeArchiveName(header.Name, stripRoot)
		if err != nil {
			return err
		}
		if name == "" && header.Typeflag == tar.TypeDir {
			continue
		}
		target, err := workspacePath(destination, name)
		if err != nil {
			return err
		}
		if err := rejectSymlinkComponents(destination, name); err != nil {
			return err
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return fmt.Errorf("create archive directory: %w", err)
			}
		case tar.TypeReg, tar.TypeRegA:
			expanded += header.Size
			if header.Size < 0 || expanded > maxExpandedBytes || (len(body) > 0 && expanded > int64(len(body))*100) {
				return errors.New("archive expansion limit exceeded")
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return fmt.Errorf("create archive parent: %w", err)
			}
			mode := os.FileMode(header.Mode) & 0o777
			mode &^= 0o022
			if mode == 0 {
				mode = 0o600
			}
			file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
			if err != nil {
				return fmt.Errorf("create archive file: %w", err)
			}
			_, copyErr := io.CopyN(file, reader, header.Size)
			closeErr := file.Close()
			if copyErr != nil {
				return fmt.Errorf("extract archive file: %w", copyErr)
			}
			if closeErr != nil {
				return fmt.Errorf("close archive file: %w", closeErr)
			}
		default:
			return fmt.Errorf("unsupported archive entry %q", header.Name)
		}
	}
}

func createArchive(workspace string, paths []string) ([]byte, error) {
	if len(paths) == 0 {
		return nil, errors.New("artifact paths must not be empty")
	}
	var buffer bytes.Buffer
	gz, err := gzip.NewWriterLevel(&buffer, gzip.BestSpeed)
	if err != nil {
		return nil, err
	}
	tw := tar.NewWriter(gz)
	seen := make(map[string]struct{})
	files := 0
	var expanded int64
	for _, relative := range paths {
		clean, err := safeWorkspaceRelative(relative)
		if err != nil {
			tw.Close()
			gz.Close()
			return nil, err
		}
		root, err := workspacePath(workspace, clean)
		if err != nil {
			tw.Close()
			gz.Close()
			return nil, err
		}
		if err := rejectSymlinkComponents(workspace, clean); err != nil {
			tw.Close()
			gz.Close()
			return nil, err
		}
		if _, err := os.Lstat(root); err != nil {
			tw.Close()
			gz.Close()
			return nil, fmt.Errorf("artifact path %q: %w", relative, err)
		}
		var entries []string
		err = filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() && !info.IsDir() {
				return fmt.Errorf("artifact path contains unsupported entry %q", path)
			}
			entries = append(entries, path)
			return nil
		})
		if err != nil {
			tw.Close()
			gz.Close()
			return nil, err
		}
		sort.Strings(entries)
		for _, path := range entries {
			archiveName, err := filepath.Rel(workspace, path)
			if err != nil {
				return nil, err
			}
			archiveName = filepath.ToSlash(archiveName)
			if _, exists := seen[archiveName]; exists {
				continue
			}
			seen[archiveName] = struct{}{}
			files++
			if files > maxArchiveFiles {
				return nil, errors.New("artifact file-count limit exceeded")
			}
			info, err := os.Lstat(path)
			if err != nil {
				return nil, err
			}
			header, err := tar.FileInfoHeader(info, "")
			if err != nil {
				return nil, err
			}
			header.Name = archiveName
			header.ModTime = time.Unix(0, 0)
			header.AccessTime = time.Time{}
			header.ChangeTime = time.Time{}
			header.Uid, header.Gid = 0, 0
			header.Uname, header.Gname = "", ""
			if info.IsDir() {
				header.Name += "/"
			}
			if err := tw.WriteHeader(header); err != nil {
				return nil, err
			}
			if info.Mode().IsRegular() {
				expanded += info.Size()
				if expanded > maxExpandedBytes {
					return nil, errors.New("artifact expansion limit exceeded")
				}
				file, err := os.Open(path)
				if err != nil {
					return nil, err
				}
				_, copyErr := io.Copy(tw, file)
				closeErr := file.Close()
				if copyErr != nil {
					return nil, copyErr
				}
				if closeErr != nil {
					return nil, closeErr
				}
			}
			if buffer.Len() > maxUploadBytes {
				return nil, errors.New("artifact upload limit exceeded")
			}
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	if buffer.Len() > maxUploadBytes {
		return nil, errors.New("artifact upload limit exceeded")
	}
	return buffer.Bytes(), nil
}

func safeArchiveName(name string, stripRoot bool) (string, error) {
	name = strings.TrimSuffix(strings.ReplaceAll(name, "\\", "/"), "/")
	if name == "" || len(name) > maxArchivePathSize || strings.ContainsRune(name, '\x00') || strings.HasPrefix(name, "/") {
		return "", errors.New("unsafe archive path")
	}
	parts := strings.Split(name, "/")
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", errors.New("unsafe archive path")
		}
	}
	if stripRoot {
		if parts[0] != "source" {
			return "", errors.New("invalid source archive root")
		}
		parts = parts[1:]
		if len(parts) == 0 {
			return "", nil
		}
	}
	return filepath.Join(parts...), nil
}

func safeWorkspaceRelative(path string) (string, error) {
	clean := filepath.Clean(path)
	if path == "" || filepath.IsAbs(path) || clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) || len(clean) > maxArchivePathSize || strings.ContainsRune(clean, '\x00') {
		return "", errors.New("unsafe workspace path")
	}
	return clean, nil
}

func workspacePath(workspace, relative string) (string, error) {
	target := filepath.Join(workspace, relative)
	cleanWorkspace, err := filepath.Abs(workspace)
	if err != nil {
		return "", err
	}
	cleanTarget, err := filepath.Abs(target)
	if err != nil {
		return "", err
	}
	if cleanTarget != cleanWorkspace && !strings.HasPrefix(cleanTarget, cleanWorkspace+string(filepath.Separator)) {
		return "", errors.New("workspace path escapes root")
	}
	return cleanTarget, nil
}

func rejectSymlinkComponents(root, relative string) error {
	current := root
	for _, component := range strings.Split(filepath.Clean(relative), string(filepath.Separator)) {
		if component == "." || component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect workspace path: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("workspace path traverses a symbolic link")
		}
	}
	return nil
}
