use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
};

use clap::{ArgAction, Parser, ValueEnum};
use eyre::{Context, Result, eyre};

use crate::{CommonOptions, actionfiles::ActionFiles};

#[derive(Debug, Parser)]
pub(crate) struct PropagateArgs {

    /// What to do on validation failure(s).
    #[arg(short, long, value_enum, default_value_t = FailureMode::Hard)]
    failure_mode: FailureMode,

    /// A marker file to write on success.
    #[arg(short, long, value_name = "PATH")]
    marker_file: PathBuf,

    /// Input files with the results of our typing runs.
    #[arg(
        value_names = &["STDOUT", "STATUS"],
        action = ArgAction::Append,
        required = true,
        value_terminator = "--",
    )]
    pub action_files: Vec<PathBuf>,
}

impl PropagateArgs {
    pub fn chunked_action_files(&self) -> Result<Vec<ActionFiles>> {
        let n = 2;
        let chunked = self.action_files.chunks_exact(n);

        let remainder = chunked.remainder();
        if !remainder.is_empty() {
            return Err(eyre!(
                "args are grouped by {}; mismatched file(s): {}",
                n,
                remainder
                    .iter()
                    .map(|p| p.to_string_lossy())
                    .collect::<Vec<_>>()
                    .join(",")
            ));
        }

        Ok(chunked
            .map(|chunk| ActionFiles {
                output: chunk[0].clone(),
                status: chunk[1].clone(),
            })
            .collect())
    }
}


#[derive(Debug, Clone, PartialEq, ValueEnum)]
enum FailureMode {
    Soft,
    Hard,
}


pub(crate) fn run(_common: CommonOptions, args: PropagateArgs) -> Result<()> {
    let mut stdout = std::io::stdout().lock();

    let mut all_success = true;

    for action_file in args.chunked_action_files()? {
        let reader = BufReader::new(action_file.open_output()?);
        for line in reader.lines() {
            let line = line?;
            let formatted = format!("\x1b[2mmypy:\x1b[22m {}", line);
            writeln!(stdout, "{}", formatted)?;
        }
        let status_code = action_file.read_status_code()?;
        if status_code != 0 {
            writeln!(stdout, "\x1b[2mmypy:\x1b[22m (exit: {})", status_code)?;
            all_success = false;
        }
    }

    if args.failure_mode == FailureMode::Soft || all_success {
        std::fs::write(&args.marker_file, "")
            .wrap_err("problem writing status file")?;
    }
    Ok(())
}
