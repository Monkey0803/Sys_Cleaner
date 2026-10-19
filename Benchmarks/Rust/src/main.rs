use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

#[derive(Clone, Copy, Default)]
struct Totals {
    logical: i64,
    allocated: i64,
}

#[derive(Default)]
struct Stats {
    files: usize,
    directories: usize,
    logical: i64,
    allocated: i64,
    omitted: usize,
    direct: HashMap<PathBuf, Totals>,
    dirs: HashSet<PathBuf>,
}

impl Stats {
    fn merge(&mut self, other: Stats) {
        self.files += other.files;
        self.directories += other.directories;
        self.logical += other.logical;
        self.allocated += other.allocated;
        self.omitted += other.omitted;
        self.dirs.extend(other.dirs);
        for (path, value) in other.direct {
            let total = self.direct.entry(path).or_default();
            total.logical += value.logical;
            total.allocated += value.allocated;
        }
    }

    fn folder_totals(mut self) -> (Self, Vec<(PathBuf, Totals)>) {
        let mut dirs: Vec<PathBuf> = self.dirs.iter().cloned().collect();
        dirs.sort_by(|left, right| {
            right.components().count().cmp(&left.components().count()).then(left.cmp(right))
        });
        let root = dirs.iter().min_by_key(|p| p.components().count()).cloned();
        for dir in &dirs {
            if Some(dir) == root.as_ref() {
                continue;
            }
            let value = *self.direct.get(dir).unwrap_or(&Totals::default());
            if let Some(parent) = dir.parent() {
                let total = self.direct.entry(parent.to_path_buf()).or_default();
                total.logical += value.logical;
                total.allocated += value.allocated;
            }
        }
        dirs.sort();
        let folders = dirs.into_iter().map(|dir| {
            let total = *self.direct.get(&dir).unwrap_or(&Totals::default());
            (dir, total)
        }).collect();
        (self, folders)
    }
}

struct QueueState {
    pending: Vec<PathBuf>,
    outstanding: usize,
    stopped: bool,
}

struct WorkQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

impl WorkQueue {
    fn new(root: PathBuf) -> Self {
        Self {
            state: Mutex::new(QueueState { pending: vec![root], outstanding: 1, stopped: false }),
            ready: Condvar::new(),
        }
    }
    fn next(&self) -> Option<PathBuf> {
        let mut state = self.state.lock().unwrap();
        while state.pending.is_empty() && state.outstanding > 0 && !state.stopped {
            state = self.ready.wait(state).unwrap();
        }
        if state.stopped { None } else { state.pending.pop() }
    }
    fn add(&self, path: PathBuf) {
        let mut state = self.state.lock().unwrap();
        if !state.stopped {
            state.pending.push(path);
            state.outstanding += 1;
            self.ready.notify_one();
        }
    }
    fn finished(&self) {
        let mut state = self.state.lock().unwrap();
        state.outstanding -= 1;
        if state.outstanding == 0 { self.ready.notify_all(); }
    }
    fn cancel(&self) {
        let mut state = self.state.lock().unwrap();
        state.stopped = true;
        self.ready.notify_all();
    }
    fn cancelled(&self) -> bool { self.state.lock().unwrap().stopped }
}

fn same_volume(device: u64, root_device: u64) -> bool { device == root_device }

fn visit(
    path: &Path,
    directory: &Path,
    metadata: std::io::Result<fs::Metadata>,
    root_device: u64,
    excluded: Option<&Path>,
    queue: &WorkQueue,
    stats: &mut Stats,
    visited: &AtomicUsize,
    cancel_after: Option<usize>,
) {
    // FileManager.contentsOfDirectory suppresses AppleDouble sidecar files.
    if path.file_name().is_some_and(|name| name == ".Trash" || name.as_bytes().starts_with(b"._")) {
        return;
    }
    if excluded.is_some_and(|excluded| path.starts_with(excluded)) { return; }
    let metadata = match metadata {
        Ok(metadata) => metadata,
        Err(_) => { stats.omitted += 1; return; }
    };
    if metadata.file_type().is_symlink() || !same_volume(metadata.dev(), root_device) { return; }
    if metadata.is_dir() {
        stats.directories += 1;
        stats.dirs.insert(path.to_path_buf());
        queue.add(path.to_path_buf());
    } else {
        let logical = metadata.size() as i64;
        let allocated = (metadata.blocks() * 512) as i64;
        stats.files += 1;
        stats.logical += logical;
        stats.allocated += allocated;
        let total = stats.direct.entry(directory.to_path_buf()).or_default();
        total.logical += logical;
        total.allocated += allocated;
        if cancel_after.is_some_and(|limit| visited.fetch_add(1, Ordering::Relaxed) + 1 >= limit) {
            queue.cancel();
        }
    }
}

fn walk(root: PathBuf, workers: usize, local: bool, cancel_after: Option<usize>,
        excluded: Option<&Path>) -> (Stats, bool) {
    let metadata = match fs::symlink_metadata(&root) {
        Ok(info) if info.is_dir() => info,
        _ => return (Stats { omitted: 1, ..Stats::default() }, false),
    };
    let queue = Arc::new(WorkQueue::new(root.clone()));
    let shared = Arc::new(Mutex::new(Stats::default()));
    let visited = AtomicUsize::new(0);
    let root_device = metadata.dev();
    let mut combined = Stats::default();
    combined.directories = 1;
    combined.dirs.insert(root);
    thread::scope(|scope| {
        let handles: Vec<_> = (0..workers).map(|_| {
            let queue = Arc::clone(&queue);
            let shared = Arc::clone(&shared);
            let visited = &visited;
            scope.spawn(move || {
                let mut mine = Stats::default();
                while let Some(directory) = queue.next() {
                    if let Ok(entries) = fs::read_dir(&directory) {
                        for entry in entries {
                            if queue.cancelled() { break; }
                            match entry {
                                Ok(entry) => {
                                    let path = entry.path();
                                    let metadata = fs::symlink_metadata(&path);
                                    if local {
                                        visit(&path, &directory, metadata, root_device, excluded, &queue,
                                              &mut mine, visited, cancel_after);
                                    } else {
                                        let mut global = shared.lock().unwrap();
                                        visit(&path, &directory, metadata, root_device, excluded, &queue,
                                              &mut global, visited, cancel_after);
                                    }
                                }
                                Err(_) => {
                                    if local { mine.omitted += 1; }
                                    else { shared.lock().unwrap().omitted += 1; }
                                }
                            }
                        }
                    } else if local { mine.omitted += 1; }
                    else { shared.lock().unwrap().omitted += 1; }
                    queue.finished();
                }
                mine
            })
        }).collect();
        for handle in handles { combined.merge(handle.join().unwrap()); }
    });
    let shared_stats = Arc::try_unwrap(shared).unwrap_or_else(|_| panic!("worker retained stats"))
        .into_inner().unwrap();
    combined.merge(shared_stats);
    (combined, queue.cancelled())
}

fn escape_json(value: &str) -> String {
    let mut output = String::new();
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            c if c < ' ' => output.push_str(&format!("\\u{:04x}", c as u32)),
            c => output.push(c),
        }
    }
    output
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 || !["shared", "local"].contains(&args[1].as_str()) {
        eprintln!("usage: sys-cleaner-traversal-bench shared|local ROOT 1|4|8 [--manifest] [--no-totals] [--cancel-after N]");
        std::process::exit(2);
    }
    let workers: usize = args[3].parse().unwrap_or(0);
    if ![1, 4, 8].contains(&workers) { std::process::exit(2); }
    let root = fs::canonicalize(&args[2]).expect("root does not exist");
    let cancel_after = args.iter().position(|arg| arg == "--cancel-after")
        .and_then(|index| args.get(index + 1)).and_then(|value| value.parse().ok());
    let excluded = args.iter().position(|arg| arg == "--exclude")
        .and_then(|index| args.get(index + 1))
        .map(|path| fs::canonicalize(path).expect("excluded path does not exist"));
    let manifest = args.iter().any(|arg| arg == "--manifest");
    let calculate_totals = !args.iter().any(|arg| arg == "--no-totals");
    if manifest && !calculate_totals {
        eprintln!("--manifest requires directory totals");
        std::process::exit(2);
    }
    let (stats, cancelled) = walk(root, workers, args[1] == "local", cancel_after,
                                  excluded.as_deref());
    let (stats, folders) = if calculate_totals { stats.folder_totals() } else { (stats, Vec::new()) };
    print!("{{\"files\":{},\"directories\":{},\"logical\":{},\"allocated\":{},\"omitted\":{},\"cancelled\":{}",
           stats.files, stats.directories, stats.logical, stats.allocated, stats.omitted, cancelled);
    if manifest {
        print!(",\"folders\":{{");
        for (index, (path, total)) in folders.iter().enumerate() {
            if index > 0 { print!(","); }
            print!("\"{}\":{{\"logical\":{},\"allocated\":{}}}",
                   escape_json(&path.to_string_lossy()), total.logical, total.allocated);
        }
        print!("}}");
    }
    println!("}}");
}

#[cfg(test)]
mod tests {
    use super::same_volume;
    #[test]
    fn different_device_is_excluded() {
        assert!(same_volume(7, 7));
        assert!(!same_volume(8, 7));
    }
}
