# NAWS EventBridge/Events submodule implementation
# Exports: list-schedules, put-event (accessible via registry dispatcher)
# Features:
# - Interactive schedule exploration with tabular display
# - Shows schedule name, expression, state, and target ARN
# - Uses AWS EventBridge Scheduler API
# - Put custom events to EventBridge buses with interactive selection
#
# Dependencies: aws cli, fzf
# Registry dispatch: Uses run closures to call naws_events_* wrapper functions

use ./shared.nu *

# List EventBridge schedules with explore table
def list-schedules [...args] {
  _require_tool aws

  log info "Fetching EventBridge schedules..."
  let schedules_result = (aws scheduler list-schedules --output json | complete)
  if $schedules_result.exit_code != 0 {
    log error "Failed to list schedules"
    log error $schedules_result.stderr
    return
  }

  let schedules = ($schedules_result.stdout | from json | get Schedules? | default [])
  if ($schedules | is-empty) {
    log warning "No schedules found"
    return
  }

  # Get detailed information for each schedule
  let detailed_schedules = $schedules | par-each { |schedule|
    log info $"Fetching details for: ($schedule.Name)"
    let detail_result = (aws scheduler get-schedule --name $schedule.Name --output json | complete)
    if $detail_result.exit_code == 0 {
      let detail = ($detail_result.stdout | from json)
      {
        name: $schedule.Name
        schedule_expression: ($detail.ScheduleExpression? | default "N/A")
        state: ($schedule.State? | default "UNKNOWN")
        target_arn: ($detail.Target?.Arn? | default "N/A")
      }
    } else {
      {
        name: $schedule.Name
        schedule_expression: "ERROR"
        state: ($schedule.State? | default "UNKNOWN")
        target_arn: "ERROR"
      }
    }
  }

  $detailed_schedules
  | select name schedule_expression state target_arn
  | explore --index
}

# Private helper to select an EventBridge bus
def _select_bus [] {
  _require_tool fzf

  log info "Fetching EventBridge buses..."
  let buses_result = (aws events list-event-buses --output json | complete)
  if $buses_result.exit_code != 0 {
    log error "Failed to list event buses"
    log error $buses_result.stderr
    return ""
  }

  let parsed = ($buses_result.stdout | from json)
  let buses = ($parsed.EventBuses? | default [])

  if ($buses | is-empty) {
    log warning "No event buses found"
    return ""
  }

  let bus_names = ($buses | get Name)
  let selected = ($bus_names | to text | fzf --prompt="Select EventBridge bus: " --height=40% --border)

  if ($selected | is-empty) {
    log warning "No bus selected"
    return ""
  }

  log info $"Selected bus: ($selected)"
  $selected
}

# Put event to EventBridge
def put-event [...args] {
  _require_tool aws
  _require_tool fzf

  let bus_name = (_select_bus)
  if ($bus_name | is-empty) { return }

  # Open editor with template including Source, DetailType, and Detail
  log info "Opening editor for event configuration..."
  let template = '{
  "Source": "my.application",
  "DetailType": "User Action",
  "Detail": {
    "key": "value"
  }
}'
  let event_json = (_edit_in_editor $template "json")
  if ($event_json | is-empty) {
    log warning "Event configuration cannot be empty"
    return
  }

  # Parse and validate JSON
  let event_config = try {
    $event_json | from json
  } catch {
    log error "Invalid JSON format"
    return
  }

  # Validate required fields
  if ($event_config.Source? | is-empty) {
    log error "Source field is required"
    return
  }

  if ($event_config.DetailType? | is-empty) {
    log error "DetailType field is required"
    return
  }

  if ($event_config.Detail? | is-empty) {
    log error "Detail field is required"
    return
  }

  # Convert Detail back to JSON string for AWS API
  let detail_json = ($event_config.Detail | to json --raw)

  # Build event entry
  let event_entry = {
    Source: $event_config.Source,
    DetailType: $event_config.DetailType,
    Detail: $detail_json,
    EventBusName: $bus_name
  }

  let entries_json = ([$event_entry] | to json)

  # Show summary and confirm
  log info "Event summary:"
  log info $"  Bus: ($bus_name)"
  log info $"  Source: ($event_config.Source)"
  log info $"  Detail Type: ($event_config.DetailType)"
  log info $"  Detail: ($detail_json)"

  if not (_confirm "Send this event to EventBridge?") {
    log warning "Event submission cancelled"
    return
  }

  # Send event
  log info "Sending event to EventBridge..."
  let put_result = (aws events put-events --entries $entries_json --output json | complete)
  if $put_result.exit_code != 0 {
    log error "Failed to put events"
    log error $put_result.stderr
    return
  }

  let result = ($put_result.stdout | from json)
  let failed_entries = ($result.FailedEntryCount? | default 0)

  if $failed_entries > 0 {
    log error $"($failed_entries) event(s) failed to send"
    let failures = ($result.Entries? | default [])
    $failures | each { |entry|
      if ($entry.ErrorCode? | is-not-empty) {
        log error $"Error: ($entry.ErrorCode) - ($entry.ErrorMessage)"
      }
    }
    return
  }

  log info "Event sent successfully to EventBridge!"
  let event_id = ($result.Entries? | default [] | first | get EventId? | default "unknown")
  log info $"Event ID: ($event_id)"
}

# Domain configuration
export def naws_events_domain_info [] {
  {
    name: "events",
    desc: "EventBridge operations",
    subcmds: [
      { name: "list-schedules", desc: "Browse and explore EventBridge schedules", run: { |rest| naws_events_list-schedules ...$rest } }
      { name: "put-event", desc: "Send custom event to EventBridge bus interactively", run: { |rest| naws_events_put-event ...$rest } }
    ]
  }
}

# Export only namespaced wrapper functions (dom_subcmd) to keep raw funcs private
export def "naws_events_list-schedules" [...args] { list-schedules ...$args }
export def "naws_events_put-event" [...args] { put-event ...$args }
