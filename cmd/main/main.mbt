///|
suberror InputError {
  InputError(String)
}

///|
async fn read_text(reader : &@io.Reader, limit : Int32) -> String {
  let chunks : Array[Bytes] = []
  let mut total = 0
  for ;; {
    match reader.read_some(max_len=(limit - total).min(65536).max(1)) {
      None => break
      Some(bytes) => {
        if bytes.length() > limit - total {
          raise InputError("Input exceeds --max-input bytes")
        }
        total += bytes.length()
        chunks.push(bytes)
      }
    }
  }
  let bytes = FixedArray::make(total, b'\x00')
  let mut offset = 0
  for chunk in chunks {
    for byte in chunk {
      bytes[offset] = byte
      offset += 1
    }
  }
  @utf8.decode(Bytes::from_iter(bytes.iter()))
}

///|
async fn load(path : String, limit : Int32) -> String {
  if path == "-" {
    return read_text(@stdio.stdin, limit)
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.size() > limit.to_int64() {
    raise InputError("Input exceeds --max-input bytes")
  }
  read_text(file, limit)
}

///|
async fn existing_database(path : String) -> @sqlite.Database {
  if path == ":memory:" || path.has_prefix("file:") {
    raise InputError("CLI requires a filesystem database path")
  }
  if !@fs.exists(path) {
    raise InputError("Database does not exist: " + path)
  }
  @sqlite.Database::open(path)
}

///|
async fn different_databases(source : String, target : String) -> Unit {
  if @fs.exists(target) && @fs.realpath(source) == @fs.realpath(target) {
    raise InputError("Source and target must be different databases")
  }
}

///|
async fn new_database(path : String) -> @sqlite.Database {
  if path == ":memory:" || path.has_prefix("file:") {
    raise InputError("CLI requires a filesystem database path")
  }
  // Exclusive creation avoids silently replacing an existing database.
  @fs.write_file(path, b"", create_mode=CreateNew)
  @sqlite.Database::open(path)
}

///|
async fn emit(options : @cli.Options, text : String) -> Unit {
  let text = text + (if text.has_suffix("\n") { "" } else { "\n" })
  match options.output {
    None | Some("-") => @stdio.stdout.write(text)
    Some(path) => @fs.write_file(path, text, create_mode=CreateNew)
  }
}

///|
async fn execute(options : @cli.Options) -> String {
  let args = options.arguments
  match options.command {
    "help" => @cli.help()
    "version" => "MoonCDC 0.1.0"
    "project-snapshot" | "project-batch" => {
      let plan = @cdc.ProjectionPlan::from_wire(
        @cdc.parse_json(load(options.plan.unwrap(), options.max_input)),
      )
      let input = load(options.input.unwrap(), options.max_input)
      if options.command == "project-snapshot" {
        options.encode_snapshot(
          plan.project_snapshot(options.decode_snapshot(input)),
        )
      } else {
        options.encode_batch(plan.project_batch(options.decode_batch(input)))
      }
    }
    "init" => {
      let snapshot = options.decode_snapshot(
        load(options.input.unwrap(), options.max_input),
      )
      let target = new_database(args[0])
      defer target.close()
      target.initialize_projection(snapshot)
      snapshot.cursor.to_wire().stringify()
    }
    "apply" => {
      let batch = options.decode_batch(
        load(options.input.unwrap(), options.max_input),
      )
      let target = existing_database(args[0])
      defer target.close()
      let count = target.apply_batch(batch)
      let report : Json = {
        "applied": count,
        "cursor": target.projection_cursor().to_wire(),
      }
      report.stringify()
    }
    "bootstrap" => {
      let source = existing_database(args[0])
      defer source.close()
      different_databases(args[0], args[1])
      let target = new_database(args[1])
      defer target.close()
      let snapshot = source.snapshot(args[2], max_rows=options.max_rows)
      target.initialize_projection(snapshot)
      let report : Json = {
        "rows": snapshot.row_count(),
        "cursor": snapshot.cursor.to_wire(),
      }
      report.stringify()
    }
    "sync" => {
      let source = existing_database(args[0])
      defer source.close()
      different_databases(args[0], args[1])
      let target = existing_database(args[1])
      defer target.close()
      let count = @sqlite.synchronize(
        source,
        target,
        args[2],
        batch_limit=options.limit,
        max_batches=options.max_batches,
      )
      let report : Json = {
        "applied": count,
        "cursor": target.projection_cursor().to_wire(),
        "source": source.source_cursor().to_wire(),
      }
      report.stringify()
    }
    "audit" => {
      let source = existing_database(args[0])
      defer source.close()
      different_databases(args[0], args[1])
      let target = existing_database(args[1])
      defer target.close()
      @sqlite.audit_projection(source, target, max_rows=options.max_rows)
      .to_wire()
      .stringify()
    }
    _ => {
      let source = existing_database(args[0])
      defer source.close()
      match options.command {
        "plan" => source.plan_capture(args[1:].to_owned()).stringify()
        "install" =>
          source.install_capture(args[1:].to_owned()).to_wire().stringify()
        "status" => source.status().stringify()
        "snapshot" =>
          options.encode_snapshot(
            source.snapshot(args[1], max_rows=options.max_rows),
          )
        "export" =>
          options.encode_batch(
            source.read_batch(
              source.consumer_cursor(args[1]),
              limit=options.limit,
            ),
          )
        "ack" => {
          let batch = options.decode_batch(
            load(options.input.unwrap(), options.max_input),
          )
          source.acknowledge(args[1], batch.start, batch.end)
          source.consumer_cursor(args[1]).to_wire().stringify()
        }
        "pause" | "resume" => {
          source.pause_consumer(args[1], options.command == "pause")
          "{\"ok\":true}"
        }
        "drop-consumer" => {
          source.drop_consumer(args[1])
          "{\"ok\":true}"
        }
        "prune" => {
          let deleted = source.prune()
          let report : Json = {
            "deleted": deleted.to_string(),
            "floor": source.retention_floor().to_string(),
          }
          report.stringify()
        }
        "verify" => source.audit_journal(max_events=options.limit).stringify()
        _ => raise InputError("Unimplemented command")
      }
    }
  }
}

///|
async fn main {
  let code = try {
    let args = @env.args()
    let options = @cli.parse_args(args[1:].to_owned())
    // Check output before snapshot registers a new retention-pinning consumer.
    if options.output is Some(path) && path != "-" && @fs.exists(path) {
      raise InputError("Output already exists: " + path)
    }
    emit(options, execute(options))
    0
  } catch {
    error => {
      @stdio.stderr.write("MoonCDC: \{error}\n")
      2
    }
  }
  @sys.exit(code)
}
