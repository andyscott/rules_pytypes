use std::{fs, path::PathBuf};

use clap::Parser;
use eyre::{Context, Result, eyre};
use toml_edit::{DocumentMut, Item, Table};

use crate::CommonOptions;

#[derive(Debug, Parser)]
pub(crate) struct CanonicalizeArgs {
    /// The path to the input config file.
    #[arg(short, long, value_name = "PATH")]
    in_file: PathBuf,

    /// The path to the squashed output config file.
    #[arg(short, long, value_name = "PATH")]
    out_file: PathBuf,
}

pub(crate) fn run(_common: CommonOptions, args: CanonicalizeArgs) -> Result<()> {
    match args.in_file.extension().and_then(|s| s.to_str()) {
        Some("toml") => canonicalize_pyproject_toml(&args.in_file, &args.out_file),
        Some("ini") => Err(eyre!("mypy.ini not support yet")),
        _ => Err(eyre!(
            "'{}' config not supported (yet?)",
            args.in_file.file_name().unwrap().to_string_lossy()
        )),
    }
}

fn canonicalize_pyproject_toml(input: &PathBuf, output: &PathBuf) -> Result<()> {
    let toml_str = fs::read_to_string(input)
        .wrap_err_with(|| format!("failed to read '{}'.", input.display()))?;

    let doc = toml_str
        .parse::<DocumentMut>()
        .context("failed to parse TOML document.")?;

    let mypy_tbl = doc
        .get("tool")
        .and_then(Item::as_table)
        .and_then(|t| t.get("mypy"))
        .and_then(Item::as_table)
        .ok_or_else(|| eyre::eyre!("no [tool.mypy] section found in '{}'.", input.display()))?;

    let mut keys: Vec<_> = mypy_tbl.iter().map(|(k, _)| k.to_string()).collect();
    keys.sort();
    let mut sorted = Table::new();
    sorted.set_implicit(true);
    for key in keys.iter().filter(|&k| k != "overrides") {
        sorted[&key] = mypy_tbl[&key].clone();
    }

    if let Some(overrides) = mypy_tbl.get("overrides") {
        sorted["overrides"] = overrides.clone();
    }

    let mut out = DocumentMut::new();
    out.decor_mut()
        .set_prefix("# pytypes canonicalized config\n\n");
    out["tool"] = Item::Table(Table::new());
    out["tool"]["mypy"] = Item::Table(sorted);

    fs::write(output, out.to_string())
        .wrap_err_with(|| format!("failed to write '{}'.", output.display()))?;
    Ok(())
}
