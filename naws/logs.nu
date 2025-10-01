# NAWS CloudWatch Logs submodule implementation
# Exports: groups, streams, tail, search
# Features:
# - Interactive log group and stream selection via fzf
# - Real-time log tailing with configurable polling
# - Pattern-based log event filtering and search
# - Human-readable timestamp formatting
# - Batch stream operations for multi-stream tailing
#
# Dependencies: aws cli, fzf
# Registry dispatch: Uses run closures to call naws_logs_* wrapper functions

use ./shared.nu *

# Private helper to validate AWS CLI availability
def _validate_aws_cli [] {
  let check = (aws --version | complete)
  if $check.exit_code != 0 {
    log error "AWS CLI not found or not configured"
    return false
  }
  return true
}

# Private helper to select a log group
def _select_log_group [] {
  log info "Fetching CloudWatch Log Groups..."
  let groups_result = (aws logs describe-log-groups --output json | complete)
  if $groups_result.exit_code != 0 {
    log error "Failed to list log groups"
    log error $groups_result.stderr
    return ""
  }
  
  let parsed = ($groups_result.stdout | from json)
  let log_groups = ($parsed.logGroups? | default [])
  
  if ($log_groups | is-empty) {
    log warning "No log groups found"
    return ""
  }
  
  let group_names = ($log_groups | get logGroupName)
  let selected_group = ($group_names | to text | fzf --prompt="Select log group: " --height=40% --border)
  if ($selected_group | is-empty) {
    log warning "No log group selected"
    return ""
  }
  
  log info $"Selected log group: ($selected_group)"
  $selected_group
}

# Private helper to select log streams from a group
def _select_log_streams [group_name: string] {
  log info $"Fetching log streams for: ($group_name)"
  let streams_result = (aws logs describe-log-streams --log-group-name $group_name --order-by LastEventTime --descending --output json | complete)
  if $streams_result.exit_code != 0 {
    log error "Failed to list log streams"
    log error $streams_result.stderr
    return []
  }
  
  let parsed = ($streams_result.stdout | from json)
  let log_streams = ($parsed.logStreams? | default [])
  
  if ($log_streams | is-empty) {
    log warning "No log streams found"
    return []
  }
  
  let stream_names = ($log_streams | get logStreamName)
  let selected_streams = ($stream_names | str join "\n" | fzf -m --prompt="Select log streams: " --height=60% --border) | lines | where $it != ""
  if ($selected_streams | is-empty) {
    log warning "No log streams selected"
    return []
  }
  
  log info $"Selected ($selected_streams | length) stream\(s\)"
  $selected_streams
}

# Private helper to format log event timestamp
def _format_timestamp [timestamp: int] {
  # AWS returns milliseconds since epoch; Nushell expects nanoseconds
  ($timestamp * 1_000_000) | into datetime | format date "%Y-%m-%d %H:%M:%S"
}

# List log groups
def groups [...args] {
  _require_tool aws

  if not (_validate_aws_cli) { return }
  
  log info "Listing CloudWatch Log Groups..."
  let groups_result = (aws logs describe-log-groups --output json | complete)
  if $groups_result.exit_code != 0 {
    log error "Failed to list log groups"
    log error $groups_result.stderr
    return
  }
  
  let parsed = ($groups_result.stdout | from json)
  let log_groups = ($parsed.logGroups? | default [])
  
  if ($log_groups | is-empty) {
    log warning "No log groups found"
    return
  }
  
  $log_groups
  | upsert retentionInDays { |row| $row.retentionInDays? }
  | select logGroupName storedBytes retentionInDays creationTime
  | update storedBytes { |row| $row.storedBytes | into filesize }
  | update creationTime { |row| _format_timestamp $row.creationTime }
  | update retentionInDays { |row| if ($row.retentionInDays | is-empty) { "Never expires" } else { $"($row.retentionInDays) days" } }
  | rename group stored_bytes retention created
  | explore --index
}

# List log streams in a group
def streams [...args] {
  _require_tool aws
  _require_tool fzf

  if not (_validate_aws_cli) { return }
  
  let group_name = (_select_log_group)
  if ($group_name | is-empty) { return }
  
  log info $"Listing streams for: ($group_name)"
  let streams_result = (aws logs describe-log-streams --log-group-name $group_name --order-by LastEventTime --descending --max-items 50 --output json | complete)
  if $streams_result.exit_code != 0 {
    log error "Failed to list log streams"
    log error $streams_result.stderr
    return
  }
  
  let parsed = ($streams_result.stdout | from json)
  let log_streams = ($parsed.logStreams? | default [])
  
  if ($log_streams | is-empty) {
    log warning "No log streams found"
    return
  }
  
  $log_streams
  | upsert firstEventTimestamp { |r| $r.firstEventTimestamp? }
  | upsert lastEventTimestamp { |r| $r.lastEventTimestamp? }
  | upsert lastIngestionTime { |r| $r.lastIngestionTime? }
  | select logStreamName creationTime firstEventTimestamp lastEventTimestamp lastIngestionTime storedBytes
  | update creationTime { |row| _format_timestamp $row.creationTime }
  | update firstEventTimestamp { |row| if ($row.firstEventTimestamp | is-empty) { "-" } else { _format_timestamp $row.firstEventTimestamp } }
  | update lastEventTimestamp { |row| if ($row.lastEventTimestamp | is-empty) { "No events" } else { _format_timestamp $row.lastEventTimestamp } }
  | update lastIngestionTime { |row| if ($row.lastIngestionTime | is-empty) { "-" } else { _format_timestamp $row.lastIngestionTime } }
  | update storedBytes { |row| $row.storedBytes | into filesize }
  | rename stream created first_event last_event last_ingestion stored_bytes
  | explore --index
}

# Tail log events in real-time
def tail [...args] {
  _require_tool aws
  _require_tool fzf

  if not (_validate_aws_cli) { return }
  
  let group_name = (_select_log_group)
  if ($group_name | is-empty) { return }
  
  let selected_streams = (_select_log_streams $group_name)
  if ($selected_streams | is-empty) { return }
  
  let minutes_back = (input "Minutes back to start (default=10): " | str trim)
  let start_minutes = if ($minutes_back | is-empty) { 10 } else { $minutes_back | into int }
  let current_unix = (date now | format date "%s" | into int)
  let start_time = ($current_unix - ($start_minutes * 60)) * 1000
  
  log info $"Tailing logs from ($selected_streams | length) stream\(s\), starting ($start_minutes) minutes ago"
  log info "Press Ctrl+C to stop tailing"
  
  mut last_seen_time = $start_time
  
  loop {
    for stream in $selected_streams {
      let events_result = (aws logs get-log-events --log-group-name $group_name --log-stream-name $stream --start-time $last_seen_time --output json | complete)
      if $events_result.exit_code == 0 {
        let parsed = ($events_result.stdout | from json)
        let events = ($parsed.events? | default [])
        
        for event in $events {
          let timestamp_str = (_format_timestamp $event.timestamp)
          print $"[($timestamp_str)] [($stream)] ($event.message)"
          let event_time = ($event.timestamp + 1)
          $last_seen_time = if $event_time > $last_seen_time { $event_time } else { $last_seen_time }
        }
      }
    }
    sleep 5sec
  }
}

# Search log events by pattern
def search [...args] {
  _require_tool aws
  _require_tool fzf

  if not (_validate_aws_cli) { return }
  
  let group_name = (_select_log_group)
  if ($group_name | is-empty) { return }
  
  let selected_streams = (_select_log_streams $group_name)
  if ($selected_streams | is-empty) { return }
  
  let search_pattern = (input "Search pattern (optional): " | str trim)
  let hours_back = (input "Hours back to search (default=1): " | str trim)
  let search_hours = if ($hours_back | is-empty) { 1 } else { $hours_back | into int }
  let current_unix = (date now | format date "%s" | into int)
  let start_time = ($current_unix - ($search_hours * 3600)) * 1000
  
  log info $"Searching logs in ($selected_streams | length) stream\(s\) for the last ($search_hours) hour\(s\)"
  if not ($search_pattern | is-empty) {
    log info $"Pattern: ($search_pattern)"
  }
  
  mut all_events = []
  
  for stream in $selected_streams {
    log info $"Searching stream: ($stream)"
    
    mut filter_args = [--log-group-name $group_name --log-stream-names $stream --start-time $start_time]
    if not ($search_pattern | is-empty) {
      $filter_args = ($filter_args | append [--filter-pattern $search_pattern])
    }
    
    let events_result = (aws logs filter-log-events ...$filter_args --output json | complete)
    if $events_result.exit_code != 0 {
      log error $"Failed to search stream: ($stream)"
      log error $events_result.stderr
      continue
    }
    
    let parsed = ($events_result.stdout | from json)
    let events = ($parsed.events? | default [])
    
    for event in $events {
      $all_events = ($all_events | append {
        timestamp: (_format_timestamp $event.timestamp),
        stream: $stream,
        message: $event.message
      })
    }
  }
  
  if ($all_events | is-empty) {
    log warning "No matching events found"
    return
  }
  
  log info $"Found ($all_events | length) matching events"
  $all_events | sort-by timestamp | explore --index
}

# Domain configuration
export def naws_logs_domain_info [] {
  { 
    name: "logs", 
    desc: "CloudWatch Logs operations", 
    subcmds: [
      { name: "groups",  desc: "Browse CloudWatch log groups with retention and size info", run: { |rest| naws_logs_groups ...$rest } }
      { name: "streams", desc: "Browse log streams in a selected group by recent activity", run: { |rest| naws_logs_streams ...$rest } }
      { name: "tail",    desc: "Real-time tail of selected streams with configurable history", run: { |rest| naws_logs_tail ...$rest } }
      { name: "search",  desc: "Search events across streams with optional pattern filtering", run: { |rest| naws_logs_search ...$rest } }
    ]
  }
}

# Export only namespaced wrapper functions to keep raw funcs private
export def naws_logs_groups [...args] { groups ...$args }
export def naws_logs_streams [...args] { streams ...$args }
export def naws_logs_tail [...args] { tail ...$args }
export def naws_logs_search [...args] { search ...$args }
