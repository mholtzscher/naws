use std/log;

# Helper: Require that a CLI tool is installed.
# Usage: _require_tool <tool-name> [custom error message]
# Returns exit code 1 if tool not found.
# This helper intentionally only log infos an error and returns 1 so it can be
# composed inside other functions without exiting the entire shell session.
# Callers should `return $in` (propagate) its non‑zero exit code if desired.
export def _require_tool [tool: string, message?: string] {
  if (which $tool | is-empty) {
     error make --unspanned { msg: $"Required tool '($tool)' is not installed or not in PATH." } 
  }
}

# Helper: Prompt user for confirmation before performing an action
# Usage: _confirm <message> [default_yes]
# Returns true if user confirms, false otherwise
# Example:
#   if (_confirm "Delete all files?") { rm * }
#   if (_confirm "Continue with upload?" true) { upload_file }
export def _confirm [message: string, default_yes?: bool] {
  let default = if ($default_yes | default false) { "Y/n" } else { "y/N" }
  let prompt = $"($message) \(($default)\) "
  let response = (input $prompt | str trim | str downcase)
  
  if ($default_yes | default false) {
    # Default yes: accept empty, "y", "yes" 
    ($response == "" or $response == "y" or $response == "yes")
  } else {
    # Default no: only accept explicit "y", "yes"
    ($response == "y" or $response == "yes")
  }
}

# AWS profile management with SSO login and AWS credentials support
export def --env authenticate [] {
    _require_tool aws
    _require_tool fzf

    # Check if AWS_PROFILE is already set
    let profile = if ($env.AWS_PROFILE? | is-not-empty) {
        $env.AWS_PROFILE
    } else {
        aws configure list-profiles | fzf --prompt "Select AWS Profile:"
    }

    if ($profile | is-empty) {
        log warning "No profile selected"
        return 1
    }

    $env.AWS_PROFILE = $profile
    log info $"Using AWS profile: ($env.AWS_PROFILE)"

    # Check if we have a valid session first
    let result = aws sts get-caller-identity | complete 
    if ($result | get exit_code) == 0 {
      log info "Found valid AWS session"
      return 0
    }

    # Determine authentication method: SSO vs credentials
    let sso_check = aws configure get sso_start_url --profile $env.AWS_PROFILE | complete
    let has_sso = ($sso_check | get exit_code) == 0
    
    let access_key_check = aws configure get aws_access_key_id --profile $env.AWS_PROFILE | complete
    let has_credentials = ($access_key_check | get exit_code) == 0

    if $has_sso {
        log info "Using SSO authentication"
        let sso_result = aws sso login --profile $env.AWS_PROFILE | complete
        if ($sso_result | get exit_code) != 0 {
            log error "Failed to login to AWS SSO"
            log error ($sso_result | get stderr)
            return 1
        }
    } else if $has_credentials {
        log info "Using AWS credentials authentication"
        # Credentials are already configured, verify they work
        let verify_result = aws sts get-caller-identity | complete
        if ($verify_result | get exit_code) != 0 {
            log error "AWS credentials authentication failed"
            log error ($verify_result | get stderr)
            return 1
        }
    } else {
        log error $"No authentication method configured for profile: ($env.AWS_PROFILE)"
        log error "Profile must have either SSO configuration or AWS credentials"
        return 1
    }
    
    return 0 
}

# Helper: Resolve AWS region from environment or config
# Usage: _resolve_region
# Returns region string, defaults to us-east-1 if not found
export def _resolve_region [] {
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

# Helper: Format timestamp from AWS milliseconds to human-readable format
# Usage: _format_timestamp <timestamp_ms> [format]
# Returns formatted timestamp string or empty string if timestamp is invalid
# Default format is "%Y-%m-%d %H:%M:%S"
export def _format_timestamp [timestamp: any, format?: string] {
  let fmt = ($format | default "%+")
  if ($timestamp | is-empty) or ($timestamp == 0) {
    return ""
  }

  # Convert from milliseconds to seconds and format
  try {
    ($timestamp * 1_000_000 | into datetime -z 'l' | format date $fmt)
  } catch {
    ""
  }
}

# Helper: Open content in user's configured editor
# Usage: _edit_in_editor [initial_content] [file_extension]
# Returns the edited content or empty string if editor fails
# Uses $env.EDITOR, falls back to nvim, then nano
export def _edit_in_editor [initial_content?: string, extension?: string] {
  let ext = ($extension | default "txt")
  let temp_file = (mktemp -t $"naws_edit.XXXXXX.($ext)")

  # Write initial content if provided
  if ($initial_content | is-not-empty) {
    $initial_content | save -f $temp_file
  }

  # Determine editor to use
  let editor = if ($env.EDITOR? | is-not-empty) {
    $env.EDITOR
  } else if (which nvim | is-not-empty) {
    "nvim"
  } else if (which nano | is-not-empty) {
    "nano"
  } else {
    log error "No editor found. Please set $env.EDITOR or install nvim/nano"
    rm -f $temp_file
    return ""
  }

  # Open editor (without complete to allow terminal interaction)
  run-external $editor $temp_file

  # Check if file exists and read content
  if not ($temp_file | path exists) {
    log error "Temp file disappeared"
    return ""
  }

  let content = (open --raw $temp_file | str trim)

  # Clean up
  rm -f $temp_file

  $content
}
