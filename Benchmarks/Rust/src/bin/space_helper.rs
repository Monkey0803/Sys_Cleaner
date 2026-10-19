use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

#[derive(Default)]
struct Results {
    directories: Vec<PathBuf>,
    files: Vec<(PathBuf, u64, u64)>,
    omitted: Vec<PathBuf>,
}

struct QueueState {
    pending: Vec<PathBuf>,
    outstanding: usize,
}

struct DirectoryQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

impl DirectoryQueue {
    fn new(root: PathBuf) -> Self {
        Self {
            state: Mutex::new(QueueState { pending: vec![root], outstanding: 1 }),
            ready: Condvar::new(),
        }
    }

    fn next(&self) -> Option<PathBuf> {
        let mut state = self.state.lock().unwrap();
        while state.pending.is_empty() && state.outstanding > 0 {
            state = self.ready.wait(state).unwrap();
        }
        state.pending.pop()
    }

    fn add(&self, path: PathBuf) {
        let mut state = self.state.lock().unwrap();
        state.pending.push(path);
        state.outstanding += 1;
        self.ready.notify_one();
    }

    fn finished(&self) {
        let mut state = self.state.lock().unwrap();
        state.outstanding -= 1;
        if state.outstanding == 0 { self.ready.notify_all(); }
    }
}

fn is_excluded(path: &Path, excluded: &[PathBuf]) -> bool {
    excluded.iter().any(|item| path.starts_with(item))
}

fn walk(root: &Path, excluded: &[PathBuf]) -> io::Result<Results> {
    let root_info = fs::symlink_metadata(root)?;
    if !root_info.is_dir() || root_info.file_type().is_symlink() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "root is not a directory"));
    }
    let root_device = root_info.dev();
    let queue = Arc::new(DirectoryQueue::new(root.to_path_buf()));
    let mut result = Results { directories: vec![root.to_path_buf()], ..Results::default() };
    thread::scope(|scope| {
        let handles: Vec<_> = (0..4).map(|_| {
            let queue = Arc::clone(&queue);
            scope.spawn(move || {
                let mut local = Results::default();
                while let Some(directory) = queue.next() {
                    match fs::read_dir(&directory) {
                        Ok(children) => {
                            for child in children {
                                let Ok(child) = child else {
                                    local.omitted.push(directory.clone());
                                    continue;
                                };
                                let path = child.path();
                                if path.file_name().is_some_and(|name| name == ".Trash")
                                    || is_excluded(&path, excluded) { continue; }
                                let Ok(info) = fs::symlink_metadata(&path) else { continue; };
                                if info.dev() != root_device || info.file_type().is_symlink() {
                                    continue;
                                }
                                if info.is_dir() {
                                    local.directories.push(path.clone());
                                    queue.add(path);
                                } else {
                                    local.files.push((path, info.size(), info.blocks() * 512));
                                }
                            }
                        }
                        Err(_) => local.omitted.push(directory),
                    }
                    queue.finished();
                }
                local
            })
        }).collect();
        for handle in handles {
            let mut local = handle.join().unwrap();
            result.directories.append(&mut local.directories);
            result.files.append(&mut local.files);
            result.omitted.append(&mut local.omitted);
        }
    });
    Ok(result)
}

fn write_json_string(out: &mut impl Write, value: &Path) -> io::Result<()> {
    // macOS paths can contain non-UTF-8 bytes. Reject such paths so Swift falls back to its scanner.
    let value = value.to_str().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "non-UTF-8 path"))?;
    out.write_all(b"\"")?;
    for character in value.chars() {
        match character {
            '"' => out.write_all(b"\\\"")?,
            '\\' => out.write_all(b"\\\\")?,
            '\n' => out.write_all(b"\\n")?,
            '\r' => out.write_all(b"\\r")?,
            '\t' => out.write_all(b"\\t")?,
            value if value < ' ' => write!(out, "\\u{:04x}", value as u32)?,
            value => write!(out, "{value}")?,
        }
    }
    out.write_all(b"\"")
}

fn write_results(root: &Path, results: Results) -> io::Result<()> {
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    out.write_all(b"{\"root\":")?;
    write_json_string(&mut out, root)?;
    out.write_all(b",\"directories\":[")?;
    for (index, directory) in results.directories.iter().enumerate() {
        if index > 0 { out.write_all(b",")?; }
        write_json_string(&mut out, directory)?;
    }
    out.write_all(b"],\"files\":[")?;
    for (index, (path, logical, allocated)) in results.files.iter().enumerate() {
        if index > 0 { out.write_all(b",")?; }
        out.write_all(b"{\"path\":")?;
        write_json_string(&mut out, path)?;
        write!(out, ",\"logical\":{logical},\"allocated\":{allocated}}}")?;
    }
    out.write_all(b"],\"omitted\":[")?;
    for (index, path) in results.omitted.iter().enumerate() {
        if index > 0 { out.write_all(b",")?; }
        write_json_string(&mut out, path)?;
    }
    out.write_all(b"]}\n")?;
    out.flush()
}

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "usage: space_helper ROOT [--exclude PATH]"));
    }
    let root = fs::canonicalize(&args[1])?;
    let mut excluded = Vec::new();
    let mut index = 2;
    while index < args.len() {
        if args[index] != "--exclude" || index + 1 >= args.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid exclusion"));
        }
        excluded.push(PathBuf::from(&args[index + 1]));
        index += 2;
    }
    if is_excluded(&root, &excluded) {
        write_results(&root, Results::default())
    } else {
        write_results(&root, walk(&root, &excluded)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excludes_only_the_named_subtree() {
        let excluded = vec![PathBuf::from("/tmp/example")];
        assert!(is_excluded(Path::new("/tmp/example/child"), &excluded));
        assert!(!is_excluded(Path::new("/tmp/example-other"), &excluded));
    }
}
