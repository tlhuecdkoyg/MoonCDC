///|
pub suberror UsageError {
  UsageError(String)
}

///|
pub struct Options {
  command : String
  arguments : Array[String]
  input : String?
  output : String?
  plan : String?
  format : String
  limit : Int32
  max_batches : Int32
  max_rows : Int32
  max_input : Int32
}

///|
fn positive(text : String, name : String, maximum : Int32) -> Int32 raise {
  let value = @cdc.parse_integer(text)
  if value <= 0L || value > maximum.to_int64() {
    raise UsageError(name + " must be 1.." + maximum.to_string())
  }
  value.to_int()
}

///|
fn allowed_options(command : String) -> Array[String] {
  match command {
    "snapshot" => ["--output", "--format", "--max-rows"]
    "bootstrap" => ["--max-rows"]
    "init" | "apply" | "ack" =>
      ["--input", "--format", "--max-input", "--max-rows"]
    "export" => ["--output", "--format", "--limit"]
    "sync" => ["--limit", "--max-batches"]
    "audit" => ["--max-rows"]
    "verify" => ["--limit"]
    "project-snapshot" | "project-batch" =>
      ["--input", "--output", "--format", "--plan", "--max-input", "--max-rows"]
    _ => []
  }
}

///|
pub fn parse_args(args : Array[String]) -> Options raise {
  let command = if args.is_empty() {
    "help"
  } else {
    match args[0] {
      "--help" | "-h" => "help"
      "--version" => "version"
      other => other
    }
  }
  let expected = match command {
    "help" | "version" | "project-snapshot" | "project-batch" => 0
    "status" | "init" | "apply" | "verify" | "prune" => 1
    "snapshot"
    | "export"
    | "ack"
    | "pause"
    | "resume"
    | "drop-consumer"
    | "audit" => 2
    "sync" | "bootstrap" => 3
    "plan" | "install" => -1
    _ => raise UsageError("Unknown command: " + command)
  }
  let arguments : Array[String] = []
  let options : Map[String, String] = Map([])
  let allowed = allowed_options(command)
  let mut index = 1
  let mut positional_only = false
  while index < args.length() {
    let argument = args[index]
    if argument == "--" && !positional_only {
      positional_only = true
    } else if argument.has_prefix("--") && !positional_only {
      if !allowed.contains(argument) {
        raise UsageError("Unsupported option for " + command + ": " + argument)
      }
      if options.contains(argument) {
        raise UsageError("Duplicate option: " + argument)
      }
      index += 1
      if index >= args.length() {
        raise UsageError("Missing value for " + argument)
      }
      options[argument] = args[index]
    } else {
      if argument.is_empty() {
        raise UsageError("Empty positional argument")
      }
      arguments.push(argument)
    }
    index += 1
  }
  if (expected >= 0 && arguments.length() != expected) ||
    (expected < 0 && arguments.length() < 2) {
    raise UsageError("Wrong number of arguments for " + command + "; use help")
  }
  let format = options.get("--format").unwrap_or("json")
  if format != "json" && format != "jsonl" {
    raise UsageError("--format must be json or jsonl")
  }
  let input = options.get("--input")
  if ["init", "apply", "ack", "project-snapshot", "project-batch"].contains(
      command,
    ) &&
    input is None {
    raise UsageError("This command requires --input FILE (or - for stdin)")
  }
  let plan = options.get("--plan")
  if command.has_prefix("project-") && plan is None {
    raise UsageError("Projection requires --plan FILE")
  }
  if plan == Some("-") {
    raise UsageError("Plan must be a file, not stdin")
  }
  {
    command,
    arguments,
    input,
    output: options.get("--output"),
    plan,
    format,
    limit: positive(options.get("--limit").unwrap_or("1000"), "--limit", 100000),
    max_batches: positive(
      options.get("--max-batches").unwrap_or("100"),
      "--max-batches",
      100000,
    ),
    max_rows: positive(
      options.get("--max-rows").unwrap_or("100000"),
      "--max-rows",
      1000000,
    ),
    max_input: positive(
      options.get("--max-input").unwrap_or("67108864"),
      "--max-input",
      268435456,
    ),
  }
}

///|
pub fn Options::decode_batch(self : Options, text : String) -> @cdc.Batch raise {
  if self.format == "jsonl" {
    @cdc.Batch::from_jsonl(text)
  } else {
    @cdc.Batch::from_wire(@cdc.parse_json(text))
  }
}

///|
pub fn Options::decode_snapshot(
  self : Options,
  text : String,
) -> @cdc.Snapshot raise {
  let snapshot = if self.format == "jsonl" {
    @cdc.Snapshot::from_jsonl(text, max_rows=self.max_rows)
  } else {
    @cdc.Snapshot::from_wire(@cdc.parse_json(text))
  }
  if snapshot.row_count() > self.max_rows {
    raise UsageError("Snapshot exceeds --max-rows")
  }
  snapshot
}

///|
pub fn Options::encode_batch(
  self : Options,
  batch : @cdc.Batch,
) -> String raise {
  if self.format == "jsonl" {
    batch.to_jsonl()
  } else {
    batch.to_wire().stringify()
  }
}

///|
pub fn Options::encode_snapshot(
  self : Options,
  snapshot : @cdc.Snapshot,
) -> String raise {
  if self.format == "jsonl" {
    snapshot.to_jsonl()
  } else {
    snapshot.to_wire().stringify()
  }
}

///|
pub fn help() -> String {
  let text =
    #|MoonCDC 0.1.0 - durable SQLite change capture
    #|
    #|mooncdc plan SOURCE TABLE...             Preview capture eligibility and SQL
    #|mooncdc install SOURCE TABLE...          Install persistent capture triggers
    #|mooncdc status SOURCE                    Show watermarks and consumer lag
    #|mooncdc snapshot SOURCE CONSUMER          Register consumer and export snapshot
    #|mooncdc init TARGET --input FILE          Initialize a new target from snapshot
    #|mooncdc bootstrap SOURCE TARGET CONSUMER  Snapshot and initialize new target
    #|mooncdc export SOURCE CONSUMER            Export next batch without acknowledging
    #|mooncdc apply TARGET --input FILE         Atomically apply a batch and its cursor
    #|mooncdc ack SOURCE CONSUMER --input FILE  Acknowledge a durably processed batch
    #|mooncdc sync SOURCE TARGET CONSUMER       Catch up target; repair lagging ack
    #|mooncdc pause SOURCE CONSUMER             Pause consumption (still pins retention)
    #|mooncdc resume SOURCE CONSUMER            Resume consumption
    #|mooncdc drop-consumer SOURCE CONSUMER     Remove consumer and its retention pin
    #|mooncdc prune SOURCE                     Delete events acknowledged by everyone
    #|mooncdc verify SOURCE                    Validate retained event continuity
    #|mooncdc audit SOURCE TARGET              Compare rows at matching watermarks
    #|mooncdc project-snapshot --input FILE --plan FILE
    #|mooncdc project-batch --input FILE --plan FILE
    #|
    #|Transport options: --format json|jsonl, --input FILE|-, --output FILE|-
    #|Output defaults to stdout. Output files must not already exist.
    #|Budgets: --limit 1000, --max-batches 100, --max-rows 100000,
    #|         --max-input 67108864 (bytes). Options are command-specific.
    #|Use -- before positional paths beginning with --.
    #|Writers must enable PRAGMA recursive_triggers=ON when using REPLACE.
    #|Capture changes source schema. Projection targets must be dedicated replicas.
    #|Source transaction boundaries are not preserved across exported batches.
  text
}
