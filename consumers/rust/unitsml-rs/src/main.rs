//! Builds against the published crate and converts one quantity.
use unitsml_rs::{rational, Quantity, Register, UnitTerm};

fn main() -> Result<(), unitsml_rs::Error> {
    let db = Register::default();
    let celsius = db.resolve(&[UnitTerm::new("degC")])?;
    let kelvin = db.resolve(&[UnitTerm::new("K")])?;
    let room = Quantity::new(rational("20")?, celsius);
    let converted = room.convert(&kelvin)?;
    assert_eq!(converted.magnitude(), &rational("293.15")?);
    println!("20 degC = 293.15 K");
    Ok(())
}
