# NAWS (Nushell AWS) - Interactive AWS CLI Wrapper
# 
# A collection of interactive AWS management utilities built for Nushell with:
# - Fuzzy search selection via fzf for buckets, queues, and objects
# - Batch operations with individual success/failure tracking  
# - Safe confirmation prompts for destructive operations
# - Human-readable output formatting and pagination support
# - Dynamic tab completions for all commands and subcommands
# - Consistent help system with formatted command listings
#
# Current domains: 
# - s3 (upload/download/delete/list)
# - sqs (queue management/messaging)
# - logs (CloudWatch Logs operations)
# 
# Architecture: Registry-driven dispatcher with domain modules in separate .nu files
#
# How to add a new domain (example: ec2 with start/stop):
# 1. Create ec2.nu with domain info function:
#    export def naws_ec2_domain_info [] {
#      { name: "ec2", desc: "EC2 operations", subcmds: [
#          { name: "start", desc: "Start instances", run: { |rest| naws_ec2_start ...$rest } }
#          { name: "stop", desc: "Stop instances", run: { |rest| naws_ec2_stop ...$rest } }
#      ]}
#    }
# 2. Add domain functions: export def naws_ec2_start [...] { ... }
# 3. Add `use ./ec2.nu *` to imports section below
# 4. Add `(naws_ec2_domain_info)` to _naws_domains function
# 5. Done: completions, help, and dispatch update automatically
#
# Dependencies: aws cli, fzf, fd (for file selection), bat (for previews)

# Load submodule implementations first so referenced functions exist for runtime dispatch
use std/log;
use ./s3.nu *
use ./sqs.nu *
use ./logs.nu *
use ./batch.nu *
use ./events.nu *
use ./shared.nu authenticate
use ./shared.nu _require_tool

# Version string constant
const NAWS_VERSION = "0.1.0"

# Display formatting constants
const NAWS_NAME_PADDING = 12

# Domain registry provider (returns list of domain configurations)
# Cached to avoid repeated function calls
def _naws_domains [] {
  if ($env.NAWS_DOMAINS_CACHE? | is-empty) {
    $env.NAWS_DOMAINS_CACHE = [
      (naws_s3_domain_info)
      (naws_sqs_domain_info)
      (naws_logs_domain_info)
      (naws_batch_domain_info)
      (naws_events_domain_info)
    ]
  }
  $env.NAWS_DOMAINS_CACHE
}

# naws ==> Nushell + AWS
export def --env main [
  domain?: string@"_naws_completions_domains"
  subcmd?: string@"_naws_completions_subcmds"
  ...rest
] {
  if ($domain | is-empty) { _naws_show_help; return }
  if $domain == "version" { _naws_print_version; return }
  if $domain == "health"  { _naws_show_health; return }
  if $domain == "help"    { _naws_show_help; return }
  if $domain == "profile" { _naws_change_profile $subcmd; return }
  _naws_dispatch $domain $subcmd ...$rest
}

# Route commands to appropriate domain handlers
def --env _naws_dispatch [domain: string, subcmd?: string, ...rest] {
  let entry_list = (_naws_domains  | where name == $domain)
  if ($entry_list | is-empty) { log error $"Unknown domain: ($domain)"; return }
  let entry = $entry_list.0

  if ($subcmd | is-empty) {
    _naws_show_domain_help $domain
    return
  }

  let subcommands = ($entry.subcmds | where name == $subcmd)

  if ($subcommands | is-empty) { log error $"Unknown ($domain) command: ($subcmd)"; return }
  let sc = $subcommands.0
  # Subcommand found - authenticate then run its closure
  authenticate | if $in != 0 { return }
  do $sc.run $rest
}

# Completion helper for domains and meta commands
def _naws_completions_domains [] {
  let domain_completions = _naws_domains | each { |d| 
    { value: $d.name, description: $d.desc } 
  }
  let meta_completions = [
    { value: "help", description: "Show help" }
    { value: "version", description: "Show version" }
    { value: "health", description: "Check system health and dependencies" }
    { value: "profile", description: "Change AWS profile" }
  ]
  $domain_completions | append $meta_completions
}

# Completion helper for subcommands based on selected domain
export def _naws_completions_subcmds [context: string] {
  let dom = ($context | split words | get 1)
  _naws_domains 
  | where name == $dom 
  | get 0 
  | get subcmds 
  | each { |cmd| { value: $cmd.name, description: $cmd.desc } }
}

# Display main help with domains overview and usage
def _naws_show_help [] {
  print $"(ansi green_bold)naws(ansi reset) ==> Nushell + AWS"; print "";
  print "A collection of interactive AWS management utilities built for Nushell.";
  print "Features fuzzy search selection, batch operations, guardrails,";
  print "and human-readable output formatting for common AWS tasks."; print "";
  print "Domains:";
  _naws_domains | each { |d| 
    let padded_name = ($d.name | fill --alignment left --width $NAWS_NAME_PADDING)
    print $"  (ansi purple)($padded_name)(ansi reset) ($d.desc)" 
  }
  print ""; 
  print "Meta:";
  let version_padded = ("version" | fill --alignment left --width $NAWS_NAME_PADDING)
  let help_padded = ("help" | fill --alignment left --width $NAWS_NAME_PADDING)
  let health_padded = ("health" | fill --alignment left --width $NAWS_NAME_PADDING)
  let profile_padded = ("profile" | fill --alignment left --width $NAWS_NAME_PADDING)
  print $"  (ansi blue)($version_padded)(ansi reset) Show version";
  print $"  (ansi blue)($help_padded)(ansi reset) Show help";
  print $"  (ansi blue)($health_padded)(ansi reset) Check system health and dependencies";
  print $"  (ansi blue)($profile_padded)(ansi reset) Change AWS profile";
  print "";
  print "Usage: naws <domain> <command>";
  print "Example: naws s3 upload  # Interactive file upload to S3";
  print "Run: naws <domain> for its commands";
}

# Display help for a specific domain showing available subcommands
def _naws_show_domain_help [domain: string] {
  let entry_list = (_naws_domains | where name == $domain)
  if ($entry_list | is-empty) { log error $"Unknown domain: ($domain)"; return }
  let entry = $entry_list.0

  print $"(ansi green_bold)naws(ansi reset) ($domain) - ($entry.desc)"; print "";
  print "Available commands:";
  $entry.subcmds | each { |s| 
    let padded_name = ($s.name | fill --alignment left --width $NAWS_NAME_PADDING)
    print $"  (ansi purple)($padded_name)(ansi reset) ($s.desc)" 
  }
  print "";
  print $"Usage: naws ($domain) <command>";
  print $"Example: naws ($domain) ($entry.subcmds.0.name)";
}

# Check system health and show dependency status
def _naws_show_health [] {
  print $"(ansi green_bold)naws(ansi reset) v($NAWS_VERSION) - System Health Check"; print "";
  
  # Show current Nushell version
  print $"(ansi default_bold)Nushell:(ansi reset) (version | get version)";
  print "";
  
  # Required tools check
  let required_tools = ["aws", "fzf", "fd", "bat"]
  print $"(ansi default_bold)Required Dependencies:(ansi reset)";
  
  mut all_ok = true
  for tool in $required_tools {
    let check = (^which $tool | complete)
    if $check.exit_code == 0 {
      let tool_padded = ($tool | fill --alignment left --width $NAWS_NAME_PADDING)
      print $"  (ansi green)✓(ansi reset) ($tool_padded) Available"
    } else {
      let tool_padded = ($tool | fill --alignment left --width $NAWS_NAME_PADDING)
      print $"  (ansi red)✗(ansi reset) ($tool_padded) Missing"
      $all_ok = false
    }
  }
  
  print "";
  
  # AWS CLI specific checks if available
  let aws_check = (^which aws | complete)
  if $aws_check.exit_code == 0 {
    # AWS version
    let aws_version = (aws --version | complete)
    if $aws_version.exit_code == 0 {
      print $"(ansi default_bold)AWS CLI:(ansi reset) ($aws_version.stdout | str trim)";
    }
    print "";
    
    # AWS profiles
    print $"(ansi default_bold)AWS Profiles:(ansi reset)";
    let profiles_result = (aws configure list-profiles | complete)
    if $profiles_result.exit_code == 0 {
      let profiles = ($profiles_result.stdout | lines | where $it != "")
      if ($profiles | is-empty) {
        print $"  (ansi yellow)No profiles configured(ansi reset)";
      } else {
        for profile in $profiles {
          let profile_padded = ($profile | fill --alignment left --width $NAWS_NAME_PADDING)
          print $"  (ansi blue)→(ansi reset) ($profile_padded)";
        }
      }
    } else {
      print $"  (ansi red)Failed to list profiles(ansi reset)";
    }
    
    print "";
    
    # Current AWS identity
    let identity_result = (aws sts get-caller-identity --output json | complete)
    if $identity_result.exit_code == 0 {
      let identity = ($identity_result.stdout | from json)
      print $"(ansi default_bold)Current AWS Identity:(ansi reset)";
      print $"  Account: ($identity.Account)";
      print $"  User/Role: ($identity.Arn)";
    } else {
      print "AWS Identity: (ansi yellow)Not authenticated or configured(ansi reset)";
    }
  } else {
    print $"(ansi red)AWS CLI not available - cannot check AWS configuration(ansi reset)";
  }
  
  print "";
  if $all_ok {
    print $"(ansi green_bold)✓ All dependencies available(ansi reset)";
  } else {
    print $"(ansi red_bold)✗ Missing required dependencies(ansi reset)";
  }
}

# Print version information
def _naws_print_version [] {
  print $"v($NAWS_VERSION)"
}

# Change AWS profile interactively
def --env _naws_change_profile [profile?: string] {
  _require_tool aws
  _require_tool fzf

  let profiles_result = (aws configure list-profiles | complete)
  if $profiles_result.exit_code != 0 {
    log error "Failed to list AWS profiles. Make sure AWS CLI is configured."
    return 1
  }

  let profiles = ($profiles_result.stdout | lines | where $it != "")
  if ($profiles | is-empty) {
    log error "No AWS profiles found. Configure profiles using 'aws configure --profile <name>'"
    return 1
  }

  if ($profile | is-not-empty) {
    if ($profile not-in $profiles) {
      log error $"Profile '($profile)' not found. Available profiles: ($profiles | str join ', ')"
      return 1
    }
    $env.AWS_PROFILE = $profile
    log info $"AWS profile set to: ($profile)"
    return 0
  }

  let current_profile = ($env.AWS_PROFILE? | default "default")
  log info $"Current: ($current_profile)";
  print "";

  let selected_profile = ($profiles | str join "\n" | fzf --prompt="Select AWS profile: " --height=10)
  if ($selected_profile | is-empty) {
    log warning "No profile selected"
    return 1
  }

  let profile_name = ($selected_profile | str trim)
  $env.AWS_PROFILE = $profile_name
  log info $"AWS profile changed to: ($profile_name)"
  return 0
}

