///|
priv struct CascadeStep {
  child : String
  column : String
  updating : Bool
}

///|
fn add_cascade_step(
  graph : Map[String, Array[CascadeStep]],
  parent : String,
  child : String,
  column : String,
  updating : Bool,
) -> Unit {
  let step = CascadeStep::{ child, column, updating, }
  match graph.get(parent) {
    Some(steps) => steps.push(step)
    None => graph[parent] = [step]
  }
}

///|
/// A pending DELETE is logged after its FK actions. Reject a path that updates
/// another row's key in that same table before the deleted key reaches replay.
fn Database::require_supported_delete_path(
  self : Database,
  name : String,
  updates : Map[String, Array[CascadeStep]],
  deletes : Map[String, Array[CascadeStep]],
) -> Unit raise {
  let keys : Map[String, String] = Map([])
  for
    row in self.query(
      "PRAGMA main.table_xinfo(" + @cdc.quote_literal(name) + ")",
      [],
    ) {
    if integer(row.values[5]) > 0L {
      let column = text(row.values[1])
      keys[column.to_lower()] = column
    }
  }
  let start = name.to_lower()
  let pending : Array[(String, Bool)] = [(start, false)]
  let seen_deletes : Map[String, Bool] = Map([(start, true)])
  let seen_updates : Map[String, Bool] = Map([])
  while pending.pop() is Some((current, updating)) {
    let graph = if updating { updates } else { deletes }
    for step in graph.get(current).unwrap_or([]) {
      if step.child == start && step.updating {
        if keys.get(step.column) is Some(column) {
          raise StoreError(
            "Unsupported ON DELETE action path returns to captured primary key " +
            name +
            "." +
            column,
          )
        }
      }
      let visited = if step.updating { seen_updates } else { seen_deletes }
      if !visited.contains(step.child) {
        visited[step.child] = true
        pending.push((step.child, step.updating))
      }
    }
  }
}

///|
/// AFTER triggers do not provide a replayable ordering when an ON UPDATE action
/// can return to the row currently being updated. Conservatively reject cycles
/// and DELETE paths that relocate captured keys, including uncaptured tables.
fn Database::require_supported_cascades(
  self : Database,
  names : Array[String],
) -> Unit raise {
  if names.is_empty() {
    return
  }
  let tables = self.query(
    "SELECT name FROM main.sqlite_schema WHERE type='table' ORDER BY name",
    [],
  )
  let edges : Map[String, Array[String]] = Map([])
  let update_steps : Map[String, Array[CascadeStep]] = Map([])
  let delete_steps : Map[String, Array[CascadeStep]] = Map([])
  let spelling : Map[String, String] = Map([])
  for row in tables {
    let child_name = text(row.values[0])
    let child = child_name.to_lower()
    spelling[child] = child_name
    for
      foreign_key in self.query(
        "PRAGMA main.foreign_key_list(" + @cdc.quote_literal(child_name) + ")",
        [],
      ) {
      let parent = text(foreign_key.values[2]).to_lower()
      let column = text(foreign_key.values[3]).to_lower()
      let action = text(foreign_key.values[5]).to_upper()
      if action == "CASCADE" || action == "SET NULL" || action == "SET DEFAULT" {
        match edges.get(parent) {
          Some(children) =>
            if !children.contains(child) {
              children.push(child)
            }
          None => edges[parent] = [child]
        }
        add_cascade_step(update_steps, parent, child, column, true)
      }
      let deletion = text(foreign_key.values[6]).to_upper()
      if deletion == "CASCADE" {
        add_cascade_step(delete_steps, parent, child, column, false)
      } else if deletion == "SET NULL" || deletion == "SET DEFAULT" {
        add_cascade_step(delete_steps, parent, child, column, true)
      }
    }
  }
  for name in names {
    let start = name.to_lower()
    let pending = [start]
    let visited : Map[String, Bool] = Map([(start, true)])
    let preceding : Map[String, String] = Map([])
    while pending.pop() is Some(current) {
      for child in edges.get(current).unwrap_or([]) {
        if child == start {
          let reversed : Array[String] = []
          let mut node = current
          while node != start {
            reversed.push(spelling.get(node).unwrap_or(node))
            node = preceding[node]
          }
          let path = [spelling.get(start).unwrap_or(name)]
          for index in 0..<reversed.length() {
            path.push(reversed[reversed.length() - index - 1])
          }
          path.push(spelling.get(start).unwrap_or(name))
          raise StoreError(
            "Unsupported ON UPDATE action cycle involving captured table " +
            name +
            ": " +
            path.join(" -> "),
          )
        }
        if !visited.contains(child) {
          visited[child] = true
          preceding[child] = current
          pending.push(child)
        }
      }
    }
  }
  for name in names {
    self.require_supported_delete_path(name, update_steps, delete_steps)
  }
}
