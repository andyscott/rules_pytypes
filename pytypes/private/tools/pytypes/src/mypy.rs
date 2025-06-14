use std::{
    fmt::Display,
    fs::OpenOptions,
    io::{BufRead, BufReader, Write},
    os::{
        fd::{FromRawFd, RawFd},
        unix::process::CommandExt,
    },
    path::{Path, PathBuf},
};

use clap::Parser;
use eyre::{Context, OptionExt, Result, eyre};
use indoc::indoc;
use libc::c_int;

use crate::CommonOptions;

#[derive(Debug, Parser)]
pub(crate) struct MypyArgs {
    /// The path to the Python binary configured by the toolchain.
    #[arg(short, long, value_name = "PATH")]
    python_bin: PathBuf,

    /// Python flags configured by the toolchain.
    #[arg(
        short, long, value_name = "FLAGS",
        num_args = 1..,
        allow_hyphen_values = true,
        value_terminator = "--",
    )]
    python_flags: Vec<String>,

    /// Imports from the PyInfo providers for all dependencies.
    ///
    /// This should include mypy, third party dependency targets (e.g. pip/pypi),
    /// and first party dependency targets imported by the target being actively
    /// typed with Mypy.
    #[arg(
        short, long, value_name = "IMPORT",
        num_args = 1..,
    )]
    imports: Vec<String>,

    /// Arguments passed directly to Mypy.
    #[arg(
        short, long, value_name = "ARGS",
        num_args = 1..,
        allow_hyphen_values = true,
        value_terminator = "--",
    )]
    mypy_args: Vec<String>,

    /// Output file to capture Mypy stdout.
    #[arg(short, long, value_name = "PATH")]
    output_file: PathBuf,

    /// Status file to capture the Mypy exit code.
    #[arg(short, long, value_name = "PATH")]
    status_file: PathBuf,
}

fn eprint_list<T: Display>(label: &str, items: &[T], width: usize) {
    if items.is_empty() {
        eprintln!("{:width$}: (none)", label, width = width);
    } else {
        eprintln!("{:width$}: {}", label, &items[0], width = width);
        for item in &items[1..] {
            eprintln!("{:width$}: {}", "", item, width = width);
        }
    }
}

pub(crate) fn run(common_options: CommonOptions, args: MypyArgs) -> Result<()> {
    if common_options.debug {
        eprintln!("··━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━··");
        eprint_list("python_bin", &[args.python_bin.display()], 13);
        eprint_list("python_flags", &args.python_flags, 13);
        eprint_list("imports", &args.imports, 13);
        eprint_list("mypy_args", &args.mypy_args, 13);
        eprint_list("output_file", &[args.output_file.display()], 13);
        eprint_list("status_file", &[args.status_file.display()], 13);
        eprintln!("··━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━··");
    }

    let venv_root = Path::new(".").join("venv");
    std::fs::create_dir_all(&venv_root)?;
    let venv_root = venv_root.canonicalize()?;

    let cache = uv_cache::Cache::temp()?;
    let interpreter = uv_python::Interpreter::query(&args.python_bin, &cache)?;
    let venv = uv_virtualenv::create_venv(
        &venv_root,
        interpreter,
        uv_virtualenv::Prompt::Static("mypy-venv".to_string()),
        false,
        false,
        false,
        false,
    )?;

    let site_package_path = venv
        .site_packages()
        .nth(0)
        .ok_or(eyre!("missing site packages path"))?;

    let pth_file = std::fs::File::create(site_package_path.join("_runner.pth"))?;
    let mut pth_writer = std::io::BufWriter::new(pth_file);
    pth_writer.write_all(
        indoc! {"
        # all the paths
    "}
        .as_bytes(),
    )?;
    for import in &args.imports {
        if import == "_main" {
            // TODO?
        } else {
            let entry_path = Path::new(&format!("./external/{}", import))
                .canonicalize()
                .map_err(|e| eyre!("missing import {}: {}", import, e))?;
            let relative =
                pathdiff::diff_paths(entry_path, &site_package_path).ok_or_eyre("blerg")?;
            writeln!(pth_writer, "{}", relative.display())?;
        }
    }
    drop(pth_writer);

    unsafe {
        let mut master: c_int = 0;
        let mut slave: c_int = 0;
        if libc::openpty(
            &mut master as *mut c_int,
            &mut slave as *mut c_int,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        ) != 0
        {
            return Err(eyre!("unable to open pty"));
        }

        let pid = libc::fork();
        if pid < 0 {
            return Err(eyre!("unable to fork process"));
        }

        if pid == 0 {
            libc::dup2(slave, libc::STDIN_FILENO);
            libc::dup2(slave, libc::STDOUT_FILENO);
            libc::dup2(slave, libc::STDERR_FILENO);
            libc::close(master);
            libc::close(slave);

            let mut cmd = std::process::Command::new(&venv_root.join("bin/python"));
            cmd.env("VIRTUAL_ENV", &venv_root)
                .env("TERM", "xterm-256color")
                .args(args.python_flags)
                .arg("-m")
                .arg("mypy")
                .args(args.mypy_args);
            if common_options.debug {
                eprintln!("$ {:?}", cmd);
                eprintln!("··━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━··");
            }
            let err = cmd.exec();
            Err(eyre!(err))
        } else {
            libc::close(slave);
            let pty = std::fs::File::from_raw_fd(master as RawFd);
            let reader = BufReader::new(pty);
            let mut stdout = std::io::stdout().lock();
            let mut output = std::io::BufWriter::new(
                OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(true)
                    .open(&args.output_file)
                    .wrap_err("problem opening output file")?,
            );

            for line in reader.lines() {
                let line = line?;
                let formatted = format!("\x1b[2mmypy:\x1b[22m {}", line);
                writeln!(stdout, "{}", formatted)?;
                writeln!(output, "{}", formatted)?;
            }
            let mut status: c_int = 0;
            libc::waitpid(pid, &mut status, 0);
            std::fs::write(&args.status_file, status.to_string())
                .wrap_err("problem writing status file")?;
            std::process::exit(status);
        }
    }
}
