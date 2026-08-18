use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
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
    let notices = third_party_notices()?;
    let components = [
        ("cli", output.join(format!("robine-{version}")), "robine"),
        (
            "server",
            output.join(format!("robine-server-{version}")),
            "robine-server",
        ),
        (
            "runner",
            output.join(format!("robine-runner-{version}")),
            "robine-runner",
        ),
    ];
    for (component, source, executable) in components {
        let directory = output.join(component);
        fs::create_dir_all(&directory)?;
        fs::copy(&source, directory.join(executable))?;
        make_executable(&directory.join(executable))?;
        fs::copy("LICENSE", directory.join("LICENSE"))?;
        fs::write(directory.join("THIRD_PARTY_NOTICES.md"), &notices)?;
        if component == "server" {
            copy_directory(Path::new("rel/overlays"), &directory)?;
            let docker = env::var_os("ROBINE_DOCKER_CLI")
                .map(PathBuf::from)
                .or_else(|| {
                    ["/usr/local/bin/docker", "/usr/bin/docker"]
                        .iter()
                        .map(PathBuf::from)
                        .find(|path| path.is_file())
                })
                .ok_or_else(|| io::Error::other("Docker CLI is required for the server bundle"))?;
            fs::copy(docker, directory.join("docker"))?;
            make_executable(&directory.join("docker"))?;
            fs::write(
                directory.join("RELEASE_PLATFORM"),
                "ROBINE_RUNTIME_IMAGE=ubuntu:24.04\n",
            )?;
        }
        write_component_manifest(&directory)?;
    }
    Ok(manifest_path)
}

fn third_party_notices() -> io::Result<String> {
    let output = Command::new("cargo")
        .args(["metadata", "--format-version", "1", "--locked"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("cargo metadata failed"));
    }
    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(io::Error::other)?;
    let packages = metadata["packages"]
        .as_array()
        .ok_or_else(|| io::Error::other("cargo metadata has no package list"))?;
    let mut dependencies = BTreeSet::new();
    for package in packages {
        if package["source"].is_null() {
            continue;
        }
        let name = package["name"]
            .as_str()
            .ok_or_else(|| io::Error::other("dependency has no name"))?;
        let version = package["version"]
            .as_str()
            .ok_or_else(|| io::Error::other("dependency has no version"))?;
        let license = package["license"]
            .as_str()
            .ok_or_else(|| io::Error::other(format!("{name} has no SPDX license")))?;
        let repository = package["repository"].as_str().unwrap_or("");
        dependencies.insert((
            name.to_owned(),
            version.to_owned(),
            license.replace('|', "\\|"),
            repository.replace('|', "%7C"),
        ));
    }
    let lock_digest = Sha256::digest(fs::read("Cargo.lock")?);
    let mut notices = format!(
        "# Third-party notices\n\nGenerated from the locked Cargo dependency graph by `robine-package`. Cargo.lock SHA-256: `{lock_digest:x}`. License expressions are package-declared SPDX metadata and are enforced by `cargo deny`. Review the corresponding crate source for complete license text.\n\n| Package | Version | License | Repository |\n|---|---:|---|---|\n"
    );
    for (name, version, license, repository) in dependencies {
        let _ = writeln!(notices, "| {name} | {version} | {license} | {repository} |");
    }
    Ok(notices)
}

fn copy_directory(source: &Path, target: &Path) -> io::Result<()> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let destination = target.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            fs::create_dir_all(&destination)?;
            copy_directory(&entry.path(), &destination)?;
        } else {
            fs::copy(entry.path(), destination)?;
        }
    }
    Ok(())
}

fn write_component_manifest(directory: &Path) -> io::Result<()> {
    let mut entries = fs::read_dir(directory)?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .collect::<Vec<_>>();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    let mut manifest = String::new();
    for entry in entries {
        if entry.file_name() == "SHA256SUMS" {
            continue;
        }
        let bytes = fs::read(entry.path())?;
        let digest = Sha256::digest(bytes);
        let name = entry.file_name();
        let name = name
            .to_str()
            .ok_or_else(|| io::Error::other("invalid artifact name"))?;
        let _ = writeln!(manifest, "{digest:x}  {name}");
    }
    fs::write(directory.join("SHA256SUMS"), manifest)
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
