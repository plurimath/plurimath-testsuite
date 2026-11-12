//! Builds against the published crate and looks up one unit.
use unitsdb_rs::{find, records, Collection, Lookup};

fn main() {
    assert!(!records(Collection::Units).is_empty(), "no unit records");
    let metre = find(Lookup::UnitSymbol, "m").expect("unit symbol m not found");
    println!("{metre}");
}
