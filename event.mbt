///|
pub(all) enum Operation {
  Insert
  Update
  Delete
} derive(Debug, Eq)

///|
pub(all) struct Cursor {
  source : String
  sequence : Int64
} derive(Debug, Eq)

///|
pub(all) struct Event {
  sequence : Int64
  table : String
  operation : Operation
  before : Row?
  after : Row?
} derive(Debug, Eq)

///|
pub(all) struct Batch {
  start : Cursor
  end : Cursor
  high_water : Int64
  events : Array[Event]
} derive(Debug, Eq)

///|
pub fn Operation::name(self : Operation) -> String {
  match self {
    Insert => "insert"
    Update => "update"
    Delete => "delete"
  }
}

///|
pub fn Operation::parse(name : String) -> Operation raise CdcError {
  match name {
    "insert" => Insert
    "update" => Update
    "delete" => Delete
    _ => raise Invalid("Unknown operation: " + name)
  }
}

///|
pub fn Cursor::validate(self : Cursor) -> Unit raise CdcError {
  check_name(self.source)
  if self.sequence < 0L {
    raise Invalid("Negative cursor")
  }
}

///|
pub fn Cursor::to_wire(self : Cursor) -> Json {
  { "source": self.source, "sequence": self.sequence.to_string() }
}

///|
pub fn Cursor::from_wire(value : Json) -> Cursor raise CdcError {
  let cursor = Cursor::{
    source: string_field(value, "source"),
    sequence: integer_field(value, "sequence"),
  }
  cursor.validate()
  cursor
}

///|
pub fn Event::validate(self : Event) -> Unit raise CdcError {
  check_name(self.table)
  if self.sequence <= 0L {
    raise Invalid("Event sequence must be positive")
  }
  match (self.operation, self.before, self.after) {
    (Insert, None, Some(_))
    | (Update, Some(_), Some(_))
    | (Delete, Some(_), None) => ()
    _ => raise Invalid("Row images do not match operation")
  }
}

///|
fn optional_row(row : Row?) -> Json raise CdcError {
  match row {
    Some(row) => row.to_wire()
    None => Json::null()
  }
}

///|
fn read_optional_row(value : Json) -> Row? raise CdcError {
  match value {
    Null => None
    _ => Some(Row::from_wire(value))
  }
}

///|
pub fn Event::to_wire(self : Event) -> Json raise CdcError {
  self.validate()
  {
    "sequence": self.sequence.to_string(),
    "table": self.table,
    "operation": self.operation.name(),
    "before": optional_row(self.before),
    "after": optional_row(self.after),
  }
}

///|
pub fn Event::from_wire(value : Json) -> Event raise CdcError {
  let event = Event::{
    sequence: integer_field(value, "sequence"),
    table: string_field(value, "table"),
    operation: Operation::parse(string_field(value, "operation")),
    before: read_optional_row(field(value, "before")),
    after: read_optional_row(field(value, "after")),
  }
  event.validate()
  event
}

///|
pub fn Batch::validate(self : Batch) -> Unit raise CdcError {
  self.start.validate()
  self.end.validate()
  if self.start.source != self.end.source {
    raise Invalid("Batch source identity mismatch")
  }
  if self.end.sequence < self.start.sequence ||
    self.high_water < self.end.sequence {
    raise Invalid("Invalid batch watermarks")
  }
  let mut previous = self.start.sequence
  for event in self.events {
    event.validate()
    if event.sequence <= previous || event.sequence > self.end.sequence {
      raise Invalid("Events must be strictly ordered inside cursor interval")
    }
    previous = event.sequence
  }
  if previous != self.end.sequence {
    raise Invalid("Batch end must equal last event or empty batch start")
  }
}

///|
pub fn Batch::to_wire(self : Batch) -> Json raise CdcError {
  self.validate()
  {
    "format": "mooncdc.batch.v1",
    "start": self.start.to_wire(),
    "end": self.end.to_wire(),
    "high_water": self.high_water.to_string(),
    "events": Json::array(self.events.map(event => event.to_wire())),
  }
}

///|
pub fn Batch::from_wire(value : Json) -> Batch raise CdcError {
  if string_field(value, "format") != "mooncdc.batch.v1" {
    raise Invalid("Unsupported batch format")
  }
  let batch = Batch::{
    start: Cursor::from_wire(field(value, "start")),
    end: Cursor::from_wire(field(value, "end")),
    high_water: integer_field(value, "high_water"),
    events: array_field(value, "events").map(event => Event::from_wire(event)),
  }
  batch.validate()
  batch
}
