use clap::{Parser, Subcommand};
use eyre::Result;

mod actionfiles;
mod canonicalize;
mod mypy;
mod check;

#[derive(Debug, Parser)]
#[clap(
    name = "pytypes",
    about = "action toolkit for typing python under bazel",
    author = "@andyscott"
)]
pub struct PytypesCLI {
    #[clap(flatten)]
    common_options: CommonOptions,

    #[clap(subcommand)]
    command: Command,
}

#[derive(Debug, Parser)]
struct CommonOptions {
    /// Enables ancillary output for development.
    ///
    /// Pass "--@rules_pytypes//pytypes/private:debug" to bazel to set this
    /// flag automatically.
    #[arg(short, long)]
    debug: bool,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Runs Mypy typing and writes out status files. Never fails; we use the
    /// check command to escalate errors.
    Mypy(mypy::MypyArgs),

    /// Canonicalizes a typing config file, e.g. extracts and normalizes `[tool.mypy]`
    /// options from `pyproject.toml` to maximize caching.
    Canonicalize(canonicalize::CanonicalizeArgs),

    /// Propagates/escalates errors from typing action runs.
    Check(check::CheckArgs),
}

fn main() -> Result<()> {
    let cli = PytypesCLI::parse_from(argfile::expand_args_from(
        std::env::args_os(),
        argfile::parse_fromfile,
        argfile::PREFIX,
    )?);

    match cli.command {
        Command::Mypy(args) => mypy::run(cli.common_options, args),
        Command::Canonicalize(args) => canonicalize::run(cli.common_options, args),
        Command::Check(args) => check::run(cli.common_options, args),
    }
}
