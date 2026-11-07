///|
/// AFTER triggers do not provide a replayable ordering when an ON UPDATE action
/// can return to the row currently being updated. Conservatively reject cycles
/// involving a captured table, including paths through uncaptured main tables.
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
      let action = text(foreign_key.values[5]).to_upper()
      if action != "CASCADE" && action != "SET NULL" && action != "SET DEFAULT" {
        continue
      }
      let parent = text(foreign_key.values[2]).to_lower()
      match edges.get(parent) {
        Some(children) => if !children.contains(child) { children.push(child) }
        None => edges[parent] = [child]
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
}
