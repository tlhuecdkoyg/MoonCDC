///|
/// Typed filters deliberately avoid SQL coercion and floating-point integer casts.
pub(all) enum Predicate {
  Always
  Equal(String, Value)
  IsNull(String)
  IntegerBetween(String, Int64, Int64)
  TextPrefix(String, String)
  All(Array[Predicate])
  Any(Array[Predicate])
  Not(Predicate)
} derive(Debug, Eq)

///|
fn Predicate::check(
  self : Predicate,
  table : Table,
  depth : Int32,
) -> Unit raise CdcError {
  if depth > 32 {
    raise Invalid("Filter nesting exceeds 32")
  }
  match self {
    Always => ()
    Equal(name, value) => {
      require_column(table, name) |> ignore
      value.validate()
    }
    IsNull(name) | TextPrefix(name, _) => require_column(table, name) |> ignore
    IntegerBetween(name, lower, upper) => {
      require_column(table, name) |> ignore
      if lower > upper {
        raise Invalid("Inverted integer filter interval")
      }
    }
    All(children) | Any(children) => {
      if children.length() > 64 {
        raise Invalid("Too many filter clauses")
      }
      for child in children {
        child.check(table, depth + 1)
      }
    }
    Not(child) => child.check(table, depth + 1)
  }
}

///|
fn require_column(table : Table, name : String) -> Int32 raise CdcError {
  match table.column_index(name) {
    Some(index) => index
    None => raise Invalid("Unknown column " + name + " in " + table.name)
  }
}

///|
pub fn Predicate::validate(
  self : Predicate,
  table : Table,
) -> Unit raise CdcError {
  table.validate()
  self.check(table, 0)
}

///|
fn Predicate::evaluate(
  self : Predicate,
  table : Table,
  row : Row,
) -> Bool raise CdcError {
  match self {
    Always => true
    Equal(name, value) => row.values[require_column(table, name)] == value
    IsNull(name) => row.values[require_column(table, name)] == Null
    IntegerBetween(name, lower, upper) =>
      match row.values[require_column(table, name)] {
        Integer(value) => value >= lower && value <= upper
        _ => false
      }
    TextPrefix(name, prefix) =>
      match row.values[require_column(table, name)] {
        Text(value) => value.has_prefix(prefix)
        _ => false
      }
    All(children) => {
      for child in children {
        if !child.evaluate(table, row) {
          return false
        }
      }
      true
    }
    Any(children) => {
      for child in children {
        if child.evaluate(table, row) {
          return true
        }
      }
      false
    }
    Not(child) => !child.evaluate(table, row)
  }
}

///|
pub fn Predicate::matches(
  self : Predicate,
  table : Table,
  row : Row,
) -> Bool raise CdcError {
  self.validate(table)
  row.validate(table)
  self.evaluate(table, row)
}

///|
pub fn Predicate::to_wire(self : Predicate) -> Json raise CdcError {
  match self {
    Always => { "op": "always" }
    Equal(name, value) =>
      { "op": "equal", "column": name, "value": value.to_wire() }
    IsNull(name) => { "op": "null", "column": name }
    IntegerBetween(name, lower, upper) =>
      {
        "op": "integer_between",
        "column": name,
        "lower": lower.to_string(),
        "upper": upper.to_string(),
      }
    TextPrefix(name, prefix) =>
      { "op": "prefix", "column": name, "prefix": prefix }
    All(children) =>
      {
        "op": "all",
        "children": Json::array(children.map(child => child.to_wire())),
      }
    Any(children) =>
      {
        "op": "any",
        "children": Json::array(children.map(child => child.to_wire())),
      }
    Not(child) => { "op": "not", "child": child.to_wire() }
  }
}

///|
fn read_predicate(value : Json, depth : Int32) -> Predicate raise CdcError {
  if depth > 32 {
    raise Invalid("Filter nesting exceeds 32")
  }
  match string_field(value, "op") {
    "always" => Always
    "equal" =>
      Equal(
        string_field(value, "column"),
        Value::from_wire(field(value, "value")),
      )
    "null" => IsNull(string_field(value, "column"))
    "integer_between" =>
      IntegerBetween(
        string_field(value, "column"),
        integer_field(value, "lower"),
        integer_field(value, "upper"),
      )
    "prefix" =>
      TextPrefix(string_field(value, "column"), string_field(value, "prefix"))
    "all" | "any" as operation => {
      let children = array_field(value, "children")
      if children.length() > 64 {
        raise Invalid("Too many filter clauses")
      }
      let children = children.map(child => read_predicate(child, depth + 1))
      if operation == "all" {
        All(children)
      } else {
        Any(children)
      }
    }
    "not" => Not(read_predicate(field(value, "child"), depth + 1))
    _ => raise Invalid("Unknown predicate operator")
  }
}

///|
pub fn Predicate::from_wire(value : Json) -> Predicate raise CdcError {
  read_predicate(value, 0)
}
