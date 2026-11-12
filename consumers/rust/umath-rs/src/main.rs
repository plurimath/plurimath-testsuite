//! Builds against the published crate and parses one expression.
fn main() -> Result<(), umath::Error> {
    let parser = umath::Parser::new()?;
    let parsed = parser.parse("x+1")?;
    let canonical = parsed.canonical();
    assert!(!canonical.to_string().is_empty(), "empty canonical output");
    println!("{canonical}");
    Ok(())
}
