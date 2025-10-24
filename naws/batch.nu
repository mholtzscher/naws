# NAWS Batch submodule implementation
# Exports: jobs, logs, details (accessible via registry dispatcher)
# Features:
# - Interactive job queue selection via fzf
# - Job status filtering (RUNNING, SUCCEEDED, FAILED, etc.)
# - CloudWatch logs integration for job log viewing
# - Detailed job configuration and status display
# - Batch job pagination support
#
# Dependencies: aws cli, fzf
# Registry dispatch: Uses run closures to call naws_batch_* wrapper functions

use ./shared.nu *

# Private helper to get status color
def _get_status_color [status: string] {
  match $status {
    "SUCCEEDED" => "green"
    "FAILED" => "red" 
    "RUNNING" => "blue"
    "PENDING" => "yellow"
    "SUBMITTED" => "cyan"
    "RUNNABLE" => "magenta"
    "STARTING" => "light_blue"
    _ => "white"
  }
}

# Private helper to calculate duration between two timestamps
def _calculate_duration [started: any, stopped: any] {
  if ($started == null or $started == 0 or $stopped == null or $stopped == 0) {
    return null
  }
  [($stopped - $started), 0] | math max | $in * 1ms | into duration
}

# Private helper to select a job queue
def _select_job_queue [] {
  log info "Fetching Batch job queues..."
  let queues_result = (aws batch describe-job-queues --output json | complete)
  if $queues_result.exit_code != 0 {
    log error "Failed to list Batch job queues"
    log error $queues_result.stderr
    return ""
  }
  let parsed = ($queues_result.stdout | from json)
  let queues = ($parsed.jobQueues | get jobQueueName)
  if ($queues | is-empty) {
    log warning "No Batch job queues found"
    return ""
  }
  let selected_queue = ($queues | to text | fzf --prompt="Select job queue: " --height=40% --border)
  if ($selected_queue | is-empty) {
    log warning "No job queue selected"
    return ""
  }
  log info $"Selected job queue: ($selected_queue)"
  $selected_queue
}

# Private helper to get jobs from a queue for a specific status
def _get_jobs_for_status [queue: string, status: string] {
  let jobs_result = (aws batch list-jobs --job-queue $queue --job-status $status --output json | complete)
  if $jobs_result.exit_code != 0 {
    log error $"Failed to list ($status) jobs"
    return {status: $status, jobs: [], error: $jobs_result.stderr}
  }
  
  let parsed = ($jobs_result.stdout | from json)
  let jobs_list = ($parsed.jobSummaryList? | default [])
  {status: $status, jobs: $jobs_list, error: null}
}

# Private helper to get all jobs from a queue across all statuses
def _get_all_jobs [queue: string] {
  log info $"Fetching jobs from queue: ($queue) across all statuses..."
  
  let statuses = ["SUBMITTED", "PENDING", "RUNNABLE", "STARTING", "RUNNING", "SUCCEEDED", "FAILED"]
  
  # Fetch jobs for each status in parallel
  let results = ($statuses | par-each { |status|
    _get_jobs_for_status $queue $status
  })
  
  # Combine all jobs and report statistics
  mut all_jobs = []
  mut status_counts = {}
  
  for result in $results {
    let status = $result.status
    let jobs = $result.jobs
    let job_count = ($jobs | length)
    
    if ($result.error | is-not-empty) {
      log warning $"Error fetching ($status) jobs: ($result.error)"
    } else if $job_count > 0 {
      log info $"Found ($job_count) ($status) jobs"
      $all_jobs = ($all_jobs | append $jobs)
      $status_counts = ($status_counts | insert $status $job_count)
    }
  }
  
  let total_jobs = ($all_jobs | length)
  log info $"Total jobs found: ($total_jobs)"
  
  # Log status breakdown
  if ($status_counts | is-not-empty) {
    log info "Job status breakdown:"
    $status_counts | transpose status count | each { |row|
      log info $"  ($row.status): ($row.count)"
    }
  }
  
  $all_jobs
}

# Private helper to select jobs from a list
def _select_job [jobs: list, prompt: string] {
  if ($jobs | is-empty) {
    log warning "No jobs available for selection"
    return []
  }
  
  # Format jobs for selection: "jobName (jobId) - status"
  let formatted_jobs = $jobs 
  | sort-by -r createdAt 
  | each { |job|
    let created_time = (_format_timestamp ($job.createdAt? | default 0) "%Y-%m-%d %H:%M")
    [
      ($"($job.jobName) \(($job.jobId)\)" | fill --alignment left --width 62),
      ($job.status | fill --alignment left --width 12),
      (_format_timestamp $job.startedAt | fill --alignment left --width 20),
    ] | str join " | " 
  }
  
  let header = [
    ("Name (JobId)" | fill --alignment left --width 30),
    ("Status" | fill --alignment left --width 12),
    ("StartedAt" | fill --alignment left --width 20),
  ] | str join "|"
  let selected_formatted = ($formatted_jobs | to text | fzf --prompt=$prompt --height=70% --border --header=($header) | lines | where $it != "")
  
  if ($selected_formatted | is-empty) {
    log warning "No jobs selected"
    return []
  }

  # Extract job IDs from formatted strings
  log debug $"Selected job: ($selected_formatted)"
  let slected_job = $selected_formatted | parse "{_} ({jobId}) {_}" | get 0.jobId
  $jobs | where $it.jobId == $slected_job  | first
}

# Jobs - List and browse Batch jobs
def jobs [...args] {
  _require_tool aws

  let queue = (_select_job_queue)
  if ($queue | is-empty) { return }

  let jobs_list = (_get_all_jobs $queue)
  if ($jobs_list | is-empty) {
    log warning $"No jobs found in queue '($queue)'"
    return
  }

  # Display jobs in a table format
  $jobs_list
  | insert Duration { |row| 
      _calculate_duration ($row.startedAt? | default 0) ($row.stoppedAt? | default 0)
    }
  | update createdAt { |row| _format_timestamp $row.createdAt }
  | update startedAt { |row| _format_timestamp ($row.startedAt? | default 0) }
  | select jobName jobId status Duration createdAt startedAt
  | sort-by -r createdAt
  | explore --index
}

# Logs - View CloudWatch logs for selected jobs
def logs [...args] {
  _require_tool aws
  _require_tool fzf

  let queue = (_select_job_queue)
  if ($queue | is-empty) { return }

  let jobs_list = (_get_all_jobs $queue)
  if ($jobs_list | is-empty) {
    log warning "No jobs found"
    return
  }

  let job = (_select_job $jobs_list "Select job to view logs: ")
  if ($job | is-empty) { return }

  log info $"Getting log information for job: ($job.jobName)"
  
  let job_details_result = (aws batch describe-jobs --jobs $job.jobId --output json | complete)
  if $job_details_result.exit_code != 0 {
    log error $"Failed to get details for job ($job.jobId)"
    log error $job_details_result.stderr
    return
  }
  
  let job_details = ($job_details_result.stdout | from json | get jobs.0)
  
  # Try to find log stream name from job attempts
  let log_stream = ($job_details.attempts? | default [] | where { |attempt|
    $attempt.container.logStreamName? | is-not-empty
  } | get container.logStreamName? | first)
  
  if ($log_stream | is-empty) {
    log warning $"No log stream found for job ($job.jobName) - job may not have started yet"
    return 
  }
  
  log info $"Fetching logs from stream: ($log_stream)"
  
  # Fetch logs from CloudWatch
  let logs_result = (aws logs get-log-events --log-group-name "/aws/batch/job" --log-stream-name $log_stream --start-from-head --output json | complete)
  if $logs_result.exit_code != 0 {
    log error $"Failed to get logs for job ($job.jobName)"
    log error $logs_result.stderr
    return 
  }
  
  let log_data = ($logs_result.stdout | from json)
  let log_events = ($log_data.events? | default [])
  
  if ($log_events | is-empty) {
    log warning $"No log events found for job ($job.jobName)"
    return
  }
  
  print $"(ansi cyan)=== Logs for job: (ansi green)($job.jobName)(ansi cyan) \((ansi blue)($job.jobId)(ansi cyan)\) ===(ansi reset)"
  print $"Log stream: (ansi blue)($log_stream)(ansi reset)"
  print ""
  
  # Format log events for explore view
  let formatted_logs = ($log_events | each { |event|
    {
      timestamp: (_format_timestamp $event.timestamp),
      message: $event.message
    }
  })
  
  $formatted_logs | explore --index
}

# Details - Show detailed job configuration and status  
def details [...args] {
  _require_tool aws
  _require_tool fzf

  let queue = (_select_job_queue)
  if ($queue | is-empty) { return }

  let jobs_list = (_get_all_jobs $queue)
  if ($jobs_list | is-empty) {
    log warning $"No jobs found in queue '($queue)'"
    return
  }

  let job = (_select_job $jobs_list "Select job to view details: ")
  if ($job | is-empty) { return }

  log info $"Getting detailed information for job: ($job.jobName)"
  
  let job_details_result = (aws batch describe-jobs --jobs $job.jobId --output json | complete)
  if $job_details_result.exit_code != 0 {
    log error $"Failed to get details for job ($job.jobId)"
    log error $job_details_result.stderr
    continue
  }
  
  let job_details = ($job_details_result.stdout | from json | get jobs.0)
  
  print $"(ansi cyan)=== Job Details: ($job_details.jobName) ===(ansi reset)"
  print $"Job ID: (ansi blue)($job_details.jobId)(ansi reset)"
  print $"Job Queue: (ansi blue)($job_details.jobQueue)(ansi reset)"
  print $"Job Definition: (ansi blue)($job_details.jobDefinition)(ansi reset)"
  let status_color = (_get_status_color $job_details.status)
  print $"Status: (ansi $status_color)($job_details.status)(ansi reset)"
  if ($job_details.statusReason? | is-not-empty) {
    print $"Status Reason: (ansi red)($job_details.statusReason)(ansi reset)"
  }
  
  # Timestamps
  if ($job_details.createdAt? | is-not-empty) {
    print $"Created: (ansi yellow)(_format_timestamp $job_details.createdAt)(ansi reset)"
  }
  if ($job_details.startedAt? | is-not-empty) {
    print $"Started: (ansi yellow)(_format_timestamp $job_details.startedAt)(ansi reset)"
  }
  if ($job_details.stoppedAt? | is-not-empty) {
    print $"Stopped: (ansi yellow)(_format_timestamp $job_details.stoppedAt)(ansi reset)"
  }
  
  # Container details
  if ($job_details.container? | is-not-empty) {
    print ""
    print $"(ansi cyan)=== Container Configuration ===(ansi reset)"
    let container = $job_details.container
    if ($container.image? | is-not-empty) {
      print $"Image: (ansi green)($container.image)(ansi reset)"
    }
    if ($container.vcpus? | is-not-empty) {
      print $"vCPUs: (ansi green)($container.vcpus)(ansi reset)"
    }
    if ($container.memory? | is-not-empty) {
      print $"Memory: (ansi green)($container.memory) MB(ansi reset)"
    }
    if ($container.command? | is-not-empty) {
      print $"Command: (ansi green)($container.command | str join ' ')(ansi reset)"
    }
    if ($container.jobRoleArn? | is-not-empty) {
      print $"Job Role ARN: (ansi green)($container.jobRoleArn)(ansi reset)"
    }
  }
  
  # Job attempts
  if ($job_details.attempts? | is-not-empty) {
    print ""
    print $"(ansi cyan)=== Job Attempts ===(ansi reset)"
    for attempt in $job_details.attempts {
      let exit_code = ($attempt.container.exitCode? | default 'N/A')
      let exit_color = if $exit_code == 0 { "green" } else if $exit_code == "N/A" { "yellow" } else { "red" }
      print $"Attempt with exit code: (ansi $exit_color)($exit_code)(ansi reset)"
      if ($attempt.container.reason? | is-not-empty) {
        print $"  Reason: (ansi red)($attempt.container.reason)(ansi reset)"
      }
      if ($attempt.container.logStreamName? | is-not-empty) {
        print $"  Log Stream: (ansi blue)($attempt.container.logStreamName)(ansi reset)"
      }
      if ($attempt.startedAt? | is-not-empty) {
        print $"  Started: (ansi yellow)(_format_timestamp $attempt.startedAt)(ansi reset)"
      }
      if ($attempt.stoppedAt? | is-not-empty) {
        print $"  Stopped: (ansi yellow)(_format_timestamp $attempt.stoppedAt)(ansi reset)"
      }
    }
  }
  
  # Parameters
  if ($job_details.parameters? | is-not-empty) {
    print ""
    print $"(ansi cyan)=== Job Parameters ===(ansi reset)"
    $job_details.parameters | transpose key value | each { |param|
      print $"  (ansi magenta)($param.key)(ansi reset): (ansi blue)($param.value)(ansi reset)"
    }
  }
  
  print ""
}

# Domain configuration
export def naws_batch_domain_info [] {
  { 
    name: "batch", 
    desc: "AWS Batch operations", 
    subcmds: [
      { name: "jobs",    desc: "List and browse Batch jobs", run: { |rest| naws_batch_jobs ...$rest } }
      { name: "logs",    desc: "View CloudWatch logs for Batch jobs", run: { |rest| naws_batch_logs ...$rest } }
      { name: "details", desc: "Show detailed job configuration and status", run: { |rest| naws_batch_details ...$rest } }
    ]
  }
}

# Export only namespaced wrapper functions to keep raw funcs private
export def naws_batch_jobs [...args] { jobs ...$args }
export def naws_batch_logs [...args] { logs ...$args }
export def naws_batch_details [...args] { details ...$args }
