use sha2::{Digest, Sha256};
use std::{
    env,
    fmt::Write as _,
    fs, io,
    path::{Path, PathBuf},
    process::{Command, ExitCode},
};

fn main() -> ExitCode {
    match package(&arguments()) {
        Ok(output) => {
            println!("Created {}", output.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Packaging failed: {error}");
            ExitCode::from(3)
        }
    }
}

fn arguments() -> PathBuf {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    arguments
        .windows(2)
        .find(|pair| pair[0] == "--output" || pair[0] == "-o")
        .map_or_else(|| PathBuf::from("dist"), |pair| PathBuf::from(&pair[1]))
}

fn package(output: &Path) -> io::Result<PathBuf> {
    let status = Command::new("cargo")
        .args([
            "build",
            "--release",
            "-p",
            "robine-server",
            "-p",
            "robine-cli",
            "-p",
            "robine-runner",
        ])
        .status()?;
    if !status.success() {
        return Err(io::Error::other("cargo release build failed"));
    }
    fs::create_dir_all(output)?;
    let version = env!("CARGO_PKG_VERSION");
    let artifacts = [
        (
            Path::new("target/release/robine"),
            output.join(format!("robine-{version}")),
        ),
        (
            Path::new("target/release/robine-server"),
            output.join(format!("robine-server-{version}")),
        ),
        (
            Path::new("target/release/robine-runner"),
            output.join(format!("robine-runner-{version}")),
        ),
    ];
    let mut manifest = String::new();
    for (source, target) in &artifacts {
        fs::copy(source, target)?;
        make_executable(target)?;
        let bytes = fs::read(target)?;
        let digest = Sha256::digest(bytes);
        let name = target
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| io::Error::other("invalid artifact name"))?;
        let _ = writeln!(manifest, "{digest:x}  {name}");
    }
    let manifest_path = output.join("SHA256SUMS");
    fs::write(&manifest_path, manifest)?;
    Ok(manifest_path)
}

#[cfg(unix)]
fn make_executable(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
}

#[cfg(not(unix))]
fn make_executable(_path: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_output_is_dist() {
        assert_eq!(arguments_for(&[]), PathBuf::from("dist"));
    }
    fn arguments_for(arguments: &[&str]) -> PathBuf {
        arguments
            .windows(2)
            .find(|pair| pair[0] == "--output" || pair[0] == "-o")
            .map_or_else(|| PathBuf::from("dist"), |pair| PathBuf::from(pair[1]))
    }
}
