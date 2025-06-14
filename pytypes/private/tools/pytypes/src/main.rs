use clap::{Parser, Subcommand};
use eyre::Result;

mod canonicalize;
mod mypy;

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
    /// Runs Mypy.
    Mypy(mypy::MypyArgs),

    /// Canonicalizes a typing config file, e.g. extracts and normalizes `[tool.mypy]`
    /// options from `pyproject.toml` to maximize caching.
    Canonicalize(canonicalize::CanonicalizeArgs),
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
    }
}
