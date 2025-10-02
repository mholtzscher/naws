# NAWS SQS submodule implementation
# Exports: list, create, delete, purge, send, receive, delete-message, get-attributes, set-attributes
# Features:
# - Interactive queue selection via fzf
# - Region resolution from AWS config/env
# - Message batching for efficiency
# - Safe confirmation prompts for destructive operations
# - Human-readable message formatting
# - Queue attribute management
#
# Dependencies: aws cli, fzf
# Registry dispatch: Uses run closures to call naws_sqs_* wrapper functions

use ./shared.nu *

# Private helper to resolve AWS region
def _resolve_region [] {
  let env_region = ($env.AWS_REGION? | default "")
  if not ($env_region | is-empty) {
    return $env_region
  }
  
  let config_region = (aws configure get region | complete)
  if $config_region.exit_code == 0 and not ($config_region.stdout | str trim | is-empty) {
    return ($config_region.stdout | str trim)
  }
  
  "us-east-1"
}

# Private helper to normalize queue URL/name to full URL
def _normalize_queue_url [queue_input: string] {
  if ($queue_input | str starts-with "https://") {
    return $queue_input
  }
  
  let region = (_resolve_region)
  let account_id = (aws sts get-caller-identity --query Account --output text | complete)
  if $account_id.exit_code != 0 {
    log error "Failed to get AWS account ID"
    return ""
  }
  
  let account = ($account_id.stdout | str trim)
  return $"https://sqs.($region).amazonaws.com/($account)/($queue_input)"
}

# Private helper to select a queue
def _select_queue [] {
  log info "Fetching SQS queues..."
  let queues_result = (aws sqs list-queues --output json | complete)
  if $queues_result.exit_code != 0 {
    log error "Failed to list SQS queues"
    log error $queues_result.stderr
    return ""
  }
  
  let parsed = ($queues_result.stdout | from json)
  let queue_urls = ($parsed.QueueUrls? | default [])
  
  if ($queue_urls | is-empty) {
    log warning "No SQS queues found"
    return ""
  }
  
  let queue_names = ($queue_urls | each { |url| $url | str replace --regex '.*/(.+)$' '$1' })
  let selected_name = ($queue_names | to text | fzf --prompt="Select SQS queue: " --height=40% --border)
  if ($selected_name | is-empty) {
    log warning "No queue selected"
    return ""
  }
  
  let selected_url = ($queue_urls | where { |url| $url | str contains $selected_name } | first)
  log info $"Selected queue: ($selected_name)"
  $selected_url
}

# List queues
def list [...args] {
  _require_tool aws
  
  log info "Listing SQS queues..."
  let queues_result = (aws sqs list-queues --output json | complete)
  if $queues_result.exit_code != 0 {
    log error "Failed to list queues"
    log error $queues_result.stderr
    return
  }
  
  let parsed = ($queues_result.stdout | from json)
  let queue_urls = ($parsed.QueueUrls? | default [])
  
  if ($queue_urls | is-empty) {
    log warning "No queues found"
    return
  }
  
  $queue_urls 
  | each { |url| 
      let name = ($url | str replace --regex '.*/(.+)$' '$1')
      let region = ($url | str replace --regex 'https://sqs\.([^.]+)\..*' '$1')
      { name: $name, url: $url, region: $region }
    }
  | explore --index
}

# Create queue
def create [...args] {
  _require_tool aws
  
  let queue_name = (input "Enter queue name: " | str trim)
  if ($queue_name | is-empty) {
    log warning "Queue name cannot be empty"
    return
  }
  
  let is_fifo = (_confirm "Create as FIFO queue (.fifo suffix)?")
  let final_name = if $is_fifo { 
    if ($queue_name | str ends-with ".fifo") { $queue_name } else { $"($queue_name).fifo" }
  } else { 
    $queue_name 
  }
  
  mut create_args = ["--queue-name" $final_name]
  if $is_fifo {
    $create_args = ($create_args | append ["--attributes" "FifoQueue=true"])
  }
  
  log info $"Creating queue: ($final_name)"
  let create_result = (aws sqs create-queue ...$create_args --output json | complete)
  if $create_result.exit_code != 0 {
    log error "Failed to create queue"
    log error $create_result.stderr
    return
  }
  
  let queue_url = ($create_result.stdout | from json | get QueueUrl)
  log info $"Created queue: ($final_name)"
  log info $"Queue URL: ($queue_url)"
}

# Delete queue
def delete [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  
  if not (_confirm $"PERMANENTLY DELETE queue '($queue_name)' and ALL its messages?") {
    log warning "Delete cancelled"
    return
  }
  
  log info $"Deleting queue: ($queue_name)"
  let delete_result = (aws sqs delete-queue --queue-url $queue_url | complete)
  if $delete_result.exit_code != 0 {
    log error "Failed to delete queue"
    log error $delete_result.stderr
    return
  }
  
  log info $"Queue deleted: ($queue_name)"
}

# Purge queue messages
def purge [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  
  if not (_confirm $"PURGE all messages from queue '($queue_name)'?") {
    log warning "Purge cancelled"
    return
  }
  
  log info $"Purging messages from: ($queue_name)"
  let purge_result = (aws sqs purge-queue --queue-url $queue_url | complete)
  if $purge_result.exit_code != 0 {
    log error "Failed to purge queue"
    log error $purge_result.stderr
    return
  }
  
  log info $"Messages purged from: ($queue_name)"
}

# Send message
def send [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  let is_fifo = ($queue_name | str ends-with ".fifo")
  
  let message_body = (input "Enter message body: " | str trim)
  if ($message_body | is-empty) {
    log warning "Message body cannot be empty"
    return
  }
  
  mut send_args = ["--queue-url" $queue_url "--message-body" $message_body]
  
  if $is_fifo {
    let message_group_id = (input "Enter message group ID (required for FIFO): " | str trim)
    if ($message_group_id | is-empty) {
      log warning "Message group ID is required for FIFO queues"
      return
    }
    $send_args = ($send_args | append ["--message-group-id" $message_group_id])
    
    let dedup_id = (input "Enter deduplication ID (optional): " | str trim)
    if not ($dedup_id | is-empty) {
      $send_args = ($send_args | append ["--message-deduplication-id" $dedup_id])
    }
  }
  
  log info $"Sending message to: ($queue_name)"
  let send_result = (aws sqs send-message ...$send_args --output json | complete)
  if $send_result.exit_code != 0 {
    log error "Failed to send message"
    log error $send_result.stderr
    return
  }
  
  let result = ($send_result.stdout | from json)
  log info $"Message sent to: ($queue_name)"
  log info $"Message ID: ($result.MessageId)"
  if ($result.MD5OfBody? | is-not-empty) {
    log info $"MD5: ($result.MD5OfBody)"
  }
}

# Receive messages
def receive [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  let max_messages = (input "Max messages to receive (1-10, default=1): " | str trim)
  let max_count = if ($max_messages | is-empty) { "1" } else { $max_messages }
  
  log info $"Receiving messages from: ($queue_name)"
  let receive_result = (aws sqs receive-message --queue-url $queue_url --max-number-of-messages $max_count --output json | complete)
  if $receive_result.exit_code != 0 {
    log error "Failed to receive messages"
    log error $receive_result.stderr
    return
  }
  
  let result = ($receive_result.stdout | from json)
  let messages = ($result.Messages? | default [])
  
  if ($messages | is-empty) {
    log info "No messages available"
    return
  }
  
  log info $"Received ($messages | length) message(s):"
  $messages 
  | each { |msg| 
      {
        MessageId: $msg.MessageId,
        Body: $msg.Body,
        ReceiptHandle: $msg.ReceiptHandle,
        MD5OfBody: ($msg.MD5OfBody? | default ""),
        Attributes: ($msg.Attributes? | default {})
      }
    }
  | explore --index
}

# Delete message (acknowledge)
def delete_message [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  let receipt_handle = (input "Enter receipt handle from received message: " | str trim)
  if ($receipt_handle | is-empty) {
    log warning "Receipt handle cannot be empty"
    return
  }
  
  log info $"Deleting message from: ($queue_name)"
  let delete_result = (aws sqs delete-message --queue-url $queue_url --receipt-handle $receipt_handle | complete)
  if $delete_result.exit_code != 0 {
    log error "Failed to delete message"
    log error $delete_result.stderr
    return
  }
  
  log info "Message deleted successfully"
}

# Get queue attributes
def get_attributes [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  
  log info $"Getting attributes for: ($queue_name)"
  let attrs_result = (aws sqs get-queue-attributes --queue-url $queue_url --attribute-names All --output json | complete)
  if $attrs_result.exit_code != 0 {
    log error "Failed to get queue attributes"
    log error $attrs_result.stderr
    return
  }
  
  let result = ($attrs_result.stdout | from json)
  let attributes = ($result.Attributes? | default {})
  
  if ($attributes | is-empty) {
    log warning "No attributes found"
    return
  }
  
  $attributes 
  | transpose key value
  | explore --index
}

# Set queue attributes
def set_attributes [...args] {
  _require_tool aws
  _require_tool fzf
  
  let queue_url = (_select_queue)
  if ($queue_url | is-empty) { return }
  
  let queue_name = ($queue_url | str replace --regex '.*/(.+)$' '$1')
  let attr_name = (input "Enter attribute name: " | str trim)
  if ($attr_name | is-empty) {
    log warning "Attribute name cannot be empty"
    return
  }
  
  let attr_value = (input "Enter attribute value: " | str trim)
  if ($attr_value | is-empty) {
    log warning "Attribute value cannot be empty"
    return
  }
  
  log info $"Setting attribute ($attr_name) = ($attr_value) for: ($queue_name)"
  let set_result = (aws sqs set-queue-attributes --queue-url $queue_url --attributes $"($attr_name)=($attr_value)" | complete)
  if $set_result.exit_code != 0 {
    log error "Failed to set queue attributes"
    log error $set_result.stderr
    return
  }
  
  log info $"Attribute set successfully: ($attr_name) = ($attr_value)"
}

# Domain configuration
export def naws_sqs_domain_info [] {
  { 
    name: "sqs", 
    desc: "SQS operations", 
    subcmds: [
      { name: "list",             desc: "Browse SQS queues", run: { |rest| naws_sqs_list ...$rest } }
      { name: "create",           desc: "Create standard or FIFO queue with attributes", run: { |rest| naws_sqs_create ...$rest } }
      { name: "delete",           desc: "Permanently delete queue and all messages with confirmation", run: { |rest| naws_sqs_delete ...$rest } }
      { name: "purge",            desc: "Remove all messages from queue with confirmation prompt", run: { |rest| naws_sqs_purge ...$rest } }
      { name: "send",             desc: "Send message with FIFO support and group/dedup IDs", run: { |rest| naws_sqs_send ...$rest } }
      { name: "receive",          desc: "Receive and display messages with configurable batch size", run: { |rest| naws_sqs_receive ...$rest } }
      { name: "delete-message",   desc: "Acknowledge message by receipt handle to remove from queue", run: { |rest| naws_sqs_delete_message ...$rest } }
      { name: "get-attributes",   desc: "View all queue configuration and status attributes", run: { |rest| naws_sqs_get_attributes ...$rest } }
      { name: "set-attributes",   desc: "Update queue configuration attributes interactively", run: { |rest| naws_sqs_set_attributes ...$rest } }
    ]
  }
}

# Export only namespaced wrapper functions to keep raw funcs private
export def naws_sqs_list [...args] { list ...$args }
export def naws_sqs_create [...args] { create ...$args }
export def naws_sqs_delete [...args] { delete ...$args }
export def naws_sqs_purge [...args] { purge ...$args }
export def naws_sqs_send [...args] { send ...$args }
export def naws_sqs_receive [...args] { receive ...$args }
export def naws_sqs_delete_message [...args] { delete_message ...$args }
export def naws_sqs_get_attributes [...args] { get_attributes ...$args }
export def naws_sqs_set_attributes [...args] { set_attributes ...$args }
