use std::{
    fs::File,
    io::{BufWriter, Read, Write},
    path::PathBuf,
};

use eyre::{Context, Result};

#[derive(Debug, Clone)]
pub struct ActionFiles {
    pub output: PathBuf,
    pub status: PathBuf,
}

impl ActionFiles {
    pub fn new(output: PathBuf, status: PathBuf) -> ActionFiles {
        Self { output, status }
    }

    pub fn open_output(&self) -> Result<File> {
        File::open(&self.output)
            .wrap_err_with(|| format!("opening stdout file `{}`", self.output.display()))
    }

    pub fn write_output<R: Read>(&self, mut reader: R) -> Result<()> {
        let file = File::create(&self.output)
            .wrap_err_with(|| format!("opening stdout file `{}`", self.output.display()))?;
        let mut writer = BufWriter::new(file);

        std::io::copy(&mut reader, &mut writer)
            .wrap_err("writing reader contents to stdout-file")?;

        writer.flush().wrap_err("flushing stdout-file")
    }

    pub fn read_status_code(&self) -> Result<i32> {
        std::fs::read_to_string(&self.status)
            .wrap_err_with(|| format!("reading status file `{}`", self.status.display()))?
            .trim()
            .parse()
            .wrap_err("parsing status file as integer")
    }

    pub fn write_status_code(&self, code: i32) -> Result<()> {
        std::fs::write(&self.status, code.to_string())
            .wrap_err_with(|| format!("writing status to `{}`", self.status.display()))
    }
}
