//go:build windows

package runner

import (
	"errors"
	"os/exec"
	"strconv"
	"syscall"
)

const createNewProcessGroup = 0x00000200

func configureProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup}
}

func terminateProcess(cmd *exec.Cmd, done <-chan error) error {
	if cmd.Process == nil {
		return <-done
	}

	// taskkill is part of Windows and terminates the complete descendant tree.
	// Process.Kill remains the fallback when taskkill cannot inspect the process.
	_ = exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
	_ = cmd.Process.Kill()
	return <-done
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}
