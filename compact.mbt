///|
/// Reduce consecutive changes of the same row while preserving observable final state.
/// Events for other rows and primary-key changes act as barriers: no cross-row reordering.
/// This is for projections, not audit trails, and does not preserve intermediate images.
pub fn Batch::compact_adjacent(
  self : Batch,
  schemas : Array[Table],
) -> Batch raise CdcError {
  self.validate()
  let output : Array[Event] = []
  let mut pending : Event? = None
  for event in self.events {
    let schema = find_table(schemas, event.table)
    if event.before is Some(row) {
      row.validate(schema)
    }
    if event.after is Some(row) {
      row.validate(schema)
    }
    match pending {
      None => pending = Some(event)
      Some(previous) => {
        let same_identity = if previous.table != event.table {
          false
        } else {
          let previous_key = match previous.after {
            Some(row) => row.key(schema)
            None => previous.before.unwrap().key(schema)
          }
          let current_key = match event.before {
            Some(row) => row.key(schema)
            None => event.after.unwrap().key(schema)
          }
          previous_key == current_key
        }
        let moved_previous = if previous.table != event.table {
          false
        } else {
          match (previous.before, previous.after) {
            (Some(before), Some(after)) =>
              before.key(schema) != after.key(schema)
            _ => false
          }
        }
        let moved_current = match (event.before, event.after) {
          (Some(before), Some(after)) => before.key(schema) != after.key(schema)
          _ => false
        }
        if !same_identity || moved_previous || moved_current {
          output.push(previous)
          pending = Some(event)
          continue
        }
        if previous.after != event.before {
          raise Conflict("Consecutive row events have inconsistent images")
        }
        pending = match (previous.before, event.after) {
          (None, None) => None
          (None, Some(after)) =>
            Some({
              ..event,
              operation: Insert,
              before: None,
              after: Some(after),
            })
          (Some(before), None) =>
            Some({
              ..event,
              operation: Delete,
              before: Some(before),
              after: None,
            })
          (Some(before), Some(after)) =>
            if before == after {
              None
            } else {
              Some({
                ..event,
                operation: Update,
                before: Some(before),
                after: Some(after),
              })
            }
        }
      }
    }
  }
  if pending is Some(event) {
    output.push(event)
  }
  let batch = Batch::{ ..self, events: output, }
  batch.validate()
  batch
}
