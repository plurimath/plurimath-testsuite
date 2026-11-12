//! Builds against the published crate and parses one unit.
fn main() -> Result<(), asciiunits::Error> {
    let parser = asciiunits::Parser::new()?;
    let parsed = parser.parse("m")?;
    assert_eq!(parsed.to_string(), r#"{"unitName":"m"}"#);
    println!("{parsed}");
    Ok(())
}
