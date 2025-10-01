# NAWS S3 submodule implementation
# Exports: upload, download, delete, list (accessible via registry dispatcher)
# Features:
# - Interactive bucket and object selection via fzf
# - Full S3 pagination support (no object limit)
# - Batch operations with individual success/failure tracking
# - Prefix filtering for large buckets
# - Safe confirmation prompts for destructive operations
# - Tabular listing with human-readable file sizes
#
# Dependencies: aws cli, fzf, fd (for upload), bat (for upload preview)
# Registry dispatch: Uses run closures to call naws_s3_* wrapper functions

use ./shared.nu *

# Private helper to select a bucket
def _select_bucket [] {
  log info "Fetching S3 buckets..."
  let buckets_result = (aws s3api list-buckets --output json | complete)
  if $buckets_result.exit_code != 0 {
    log error "Failed to list S3 buckets"
    log error $buckets_result.stderr
    return ""
  }
  let buckets = ($buckets_result.stdout | from json | get Buckets | get Name)
  if ($buckets | is-empty) {
    log warning "No S3 buckets found"
    return ""
  }
  let selected_bucket = ($buckets | to text | fzf --prompt="Select S3 bucket: " --height=40% --border)
  if ($selected_bucket | is-empty) {
    log warning "No bucket selected"
    return ""
  }
  log info $"Selected bucket: ($selected_bucket)"
  $selected_bucket
}

# Private helper to get all objects from S3 bucket with full pagination
def _all_objects [bucket: string, prefix?: string] {
  log info "Listing objects with pagination support..."
  
  mut all_objects = []
  mut continuation_token = ""
  mut page_count = 0
  
  loop {
    $page_count = $page_count + 1
    log info $"Fetching page ($page_count)..."
    
    mut list_args = [--bucket $bucket]
    if not ($prefix | is-empty) { $list_args = ($list_args | append [--prefix $prefix]) }
    if not ($continuation_token | is-empty) { $list_args = ($list_args | append [--continuation-token $continuation_token]) }
    
    let objects_result = (aws s3api list-objects-v2 ...$list_args | complete)
    if $objects_result.exit_code != 0 {
      log error "Failed to list objects"
      log error $objects_result.stderr
      return []
    }
    
    let parsed = ($objects_result.stdout | from json)
    let page_objects = if ($parsed | is-empty) { [] } else { ($parsed.Contents? | default [] | where { |item| not ($item.Key | str ends-with "/") }) }
    $all_objects = ($all_objects | append $page_objects)
    
    let is_truncated = ($parsed.IsTruncated? | default false)
    if not $is_truncated { break }
    
    $continuation_token = ($parsed.NextContinuationToken? | default "")
    if ($continuation_token | is-empty) { break }
    
    log info $"Found (($page_objects | length)) objects on page ($page_count), continuing..."
  }
  
  log info $"Total objects found: (($all_objects | length)) across ($page_count) page\(s\)`"
  $all_objects
}

# Private helper to select objects from S3 bucket with pagination support
def _select_objects [bucket: string, prompt: string] {
  let prefix = (input "Optional key prefix filter (blank = all): " | str trim)
  let all_objects = (_all_objects $bucket $prefix)
  
  if ($all_objects | is-empty) {
    log warning "No objects found"
    return []
  }
  
  # Extract just the keys for fzf selection
  let object_keys = ($all_objects | get Key)
  let selected_keys = ($object_keys | str join "\n" | fzf -m --prompt=$prompt --height=70% --border) | lines | where $it != ""
  if ($selected_keys | is-empty) {
    log warning "No objects selected"
    return []
  }
  
  $selected_keys
}

# Upload
def upload [...args] {
  _require_tool aws
  _require_tool fzf

  let bucket = (_select_bucket)
  if ($bucket | is-empty) { return }

  let selected_file = (fd --type f . | fzf --prompt="File to upload: " --height=60% --border --preview "bat --color=always --plain --line-range :50 {}" --preview-window "right:50%:wrap")
  if ($selected_file | is-empty) { log warning "No file selected"; return }
  if not ($selected_file | path exists) { log error $"File does not exist: ($selected_file)"; return }

  let file_name = ($selected_file | path basename)
  let folder_prefix = (input "Folder path prefix (blank = root): " | str trim)
  let s3_key = if ($folder_prefix | is-empty) { $file_name } else { let clean = ($folder_prefix | str replace --regex "/+$" ""); $"($clean)/($file_name)" }

  if (_confirm $"Upload ($file_name) to s3://($bucket)/($s3_key)?") {
    log info $"Uploading ($selected_file) to s3://($bucket)/($s3_key)..."
    let up = (aws s3 cp $selected_file $"s3://($bucket)/($s3_key)" | complete)
    if $up.exit_code == 0 {
      log info $"Uploaded ($file_name) to s3://($bucket)/($s3_key)"
      log info $"URL: https://($bucket).s3.amazonaws.com/($s3_key)"
    } else {
      log error "Upload failed"; log error $up.stderr
    }
  } else { log warning "Upload cancelled" }
}

# Download
def download [...args] {
  _require_tool aws
  _require_tool fzf

  let bucket = (_select_bucket)
  if ($bucket | is-empty) { return }

  let selected_keys = (_select_objects $bucket "Select objects: ")
  if ($selected_keys | is-empty) { return }

  log info $"Selected (($selected_keys | length)) objects:"
  $selected_keys | each { |k| log info $"\t($k)" }

  if not (_confirm $"Download ($selected_keys | length) object\(s\) here? \(filenames only\)") { log warning "Download cancelled"; return }

  let results = $selected_keys | each { |k|
    let local_path = ($k | path basename)
    log info $"Downloading: s3://($bucket)/($k) -> ($local_path)"
    let dr = (aws s3 cp $"s3://($bucket)/($k)" $local_path | complete)
    if $dr.exit_code != 0 { log error $"Failed: ($k)"; log error $dr.stderr; {key: $k, success: false} } else { {key: $k, success: true} }
  }
  let failures = ($results | where success == false | get key)
  if ($failures | is-empty) { log info "All downloads completed successfully." } else { log error $"Failed to download ($failures | length) object\(s\):"; $failures | each { |f| log error $"\t($f)" } }
}

# Delete
def delete [...args] {
  _require_tool aws
  _require_tool fzf

  let bucket = (_select_bucket)
  if ($bucket | is-empty) { return }

  let selected_keys = (_select_objects $bucket "Select objects to DELETE: ")
  if ($selected_keys | is-empty) { return }

  log info $"Selected (($selected_keys | length)) objects for deletion:"
  $selected_keys | each { |k| log info $"\t($k)" }

  if not (_confirm $"PERMANENTLY DELETE ($selected_keys | length) object\(s\) from s3://($bucket)?") { 
    log warning "Delete cancelled"
    return 
  }

  let results = $selected_keys | each { |k|
    log info $"Deleting: s3://($bucket)/($k)"
    let dr = (aws s3 rm $"s3://($bucket)/($k)" | complete)
    if $dr.exit_code != 0 { log error $"Failed: ($k)"; log error $dr.stderr; {key: $k, success: false} } else { {key: $k, success: true} }
  }
  let failures = ($results | where success == false | get key)
  if ($failures | is-empty) {
    log info "All deletes completed successfully."
  } else {
    log error $"Failed to delete ($failures | length) object\(s\):"
    $failures | each { |f| log error $"\t($f)" }
  }
}

# List
def list [...args] {
  _require_tool aws

  let bucket = (_select_bucket)
  if ($bucket | is-empty) { return }

  let prefix = (input "Optional key prefix filter (blank = all): " | str trim)
  let all_objects = (_all_objects $bucket $prefix)
  
  if ($all_objects | is-empty) {
    log warning "No objects found"
    return
  }

  $all_objects 
  | select Key Size LastModified StorageClass
  | update Size { |row| $row.Size | into filesize }
  | explore --index
}

# Domain configuration
export def naws_s3_domain_info [] {
  { 
    name: "s3", 
    desc: "S3 operations", 
    subcmds: [
      { name: "upload",   desc: "Upload a local file to S3", run: { |rest| naws_s3_upload ...$rest } }
      { name: "download", desc: "Download S3 object\(s\) to current directory", run: { |rest| naws_s3_download ...$rest } }
      { name: "delete",   desc: "Permanently delete S3 object\(s\)", run: { |rest| naws_s3_delete ...$rest } }
      { name: "list",     desc: "Browse and explore S3 objects", run: { |rest| naws_s3_list ...$rest } }
    ]
  }
}

# Export only namespaced wrapper functions (dom_subcmd) to keep raw funcs private
export def naws_s3_upload [...args] { upload ...$args }
export def naws_s3_download [...args] { download ...$args }
export def naws_s3_delete [...args] { delete ...$args }
export def naws_s3_list [...args] { list ...$args }
