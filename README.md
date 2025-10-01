# NAWS (Nushell AWS)

**Interactive AWS CLI wrapper built for Nushell**

NAWS makes working with AWS services more enjoyable by providing interactive, fuzzy-searchable interfaces for common AWS operations. Instead of remembering complex AWS CLI commands and resource identifiers, NAWS lets you browse, select, and operate on AWS resources through intuitive prompts.

## Why NAWS?

The AWS CLI is powerful but verbose. Common tasks like "upload a file to S3" or "read messages from an SQS queue" require remembering exact bucket names, queue URLs, and command syntax. NAWS solves this by:

- **Interactive selection** - Browse and select resources with fuzzy search (fzf)
- **Safety guardrails** - Confirmation prompts for destructive operations
- **Human-readable output** - Formatted tables with file sizes, timestamps, and status colors
- **Batch operations** - Multi-select support with individual success/failure tracking
- **Full pagination** - Handles large datasets without truncation
- **Tab completions** - Auto-complete for all domains and commands

## Features

### Current Domains

#### S3 Operations (`naws s3`)
- `upload` - Select files locally and upload to any bucket
- `download` - Multi-select S3 objects to download
- `delete` - Delete objects with confirmation
- `list` - Browse and explore bucket contents with pagination

#### SQS Operations (`naws sqs`)
- `list` - Browse all queues
- `create` - Create standard or FIFO queues
- `delete` - Delete queues with confirmation
- `purge` - Clear all messages from a queue
- `send` - Send messages (with FIFO support)
- `receive` - Receive and view messages
- `delete-message` - Acknowledge/delete messages
- `get-attributes` / `set-attributes` - Manage queue configuration

#### CloudWatch Logs (`naws logs`)
- `groups` - Browse log groups with retention info
- `streams` - View log streams by recent activity
- `tail` - Real-time log streaming
- `search` - Search events with pattern filtering

#### AWS Batch (`naws batch`)
- `jobs` - List and filter batch jobs
- `logs` - View job CloudWatch logs
- `details` - Detailed job configuration

#### EventBridge (`naws events`)
- `list-schedules` - Browse EventBridge schedules
- `put-event` - Send custom events interactively

## Installation

### Prerequisites

Required:
- [Nushell](https://nushell.sh) (v0.80+)
- [AWS CLI](https://aws.amazon.com/cli/) (configured with credentials)
- [fzf](https://github.com/junegunn/fzf) (fuzzy finder)
- [fd](https://github.com/sharkdp/fd) (file finder, for S3 upload)
- [bat](https://github.com/sharkdp/bat) (syntax highlighting, for previews)

Install dependencies (macOS):
```bash
brew install nushell awscli fzf fd bat
```

### Setup

1. Clone the repository:
```bash
git clone https://github.com/yourusername/naws.git
cd naws
```

2. Add to your Nushell config (`~/.config/nushell/config.nu`):
```nu
use /path/to/naws/mod.nu *
```

3. Restart Nushell or reload config:
```nu
source ~/.config/nushell/config.nu
```

4. Verify installation:
```bash
naws health
```

## Usage

### Getting Started

Run `naws` to see all available domains:
```bash
naws
```

Get help for a specific domain:
```bash
naws s3
naws sqs
```

### Examples

**Upload a file to S3:**
```bash
naws s3 upload
# Interactive prompts will guide you through:
# 1. Select bucket (fuzzy search)
# 2. Select local file (fuzzy search with preview)
# 3. Enter optional folder prefix
# 4. Confirm upload
```

**Download S3 objects:**
```bash
naws s3 download
# 1. Select bucket
# 2. Optional prefix filter
# 3. Multi-select objects to download
# 4. Confirm download
```

**Send an SQS message:**
```bash
naws sqs send
# 1. Select queue
# 2. Enter message body (opens in $EDITOR)
# 3. For FIFO: provide group ID and dedup ID
```

**Tail CloudWatch Logs:**
```bash
naws logs tail
# 1. Select log group
# 2. Select log streams (multi-select)
# 3. Real-time streaming begins
```

**Check Batch jobs:**
```bash
naws batch jobs
# 1. Select job queue
# 2. Select status filter
# 3. Browse jobs in interactive table
```

### AWS Profile Management

NAWS supports AWS profiles and SSO:

```bash
# Change profile interactively
naws profile

# Or specify directly
naws profile my-profile

# NAWS will auto-detect SSO vs credentials and handle auth
```

## Testing with LocalStack

NAWS includes a LocalStack setup for local testing without using real AWS resources.

### Start LocalStack

```bash
# Start LocalStack with pre-configured resources
docker-compose up -d

# Wait for initialization to complete (check logs)
docker-compose logs -f localstack
```

### Test with LocalStack

```bash
# Option 1: Use the test script (sets environment variables)
nu test-localstack.nu

# Option 2: Export environment variables manually
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

# Then use NAWS normally
naws s3 list
naws sqs receive
naws logs groups
```

### Pre-configured Test Resources

The LocalStack initialization creates:

**S3 Buckets:**
- `naws-test-bucket-1` (empty)
- `naws-test-bucket-2` (empty)
- `naws-demo-files` (contains sample files in nested folders)

**SQS Queues:**
- `naws-test-queue` (standard, with 3 test messages)
- `naws-demo-queue` (standard, with 2 messages)
- `naws-notifications` (standard, empty)
- `naws-fifo-queue.fifo` (FIFO queue, empty)

**CloudWatch Logs:**
- `/aws/lambda/naws-test-function` (with log streams and events)
- `/aws/ecs/naws-demo-service` (empty)
- `/application/naws-app` (with log events)

**EventBridge:**
- Custom event bus: `naws-custom-bus`
- Event rule: `naws-test-rule`

### Stop LocalStack

```bash
docker-compose down

# To also remove volumes (reset all data)
docker-compose down -v
```

## Configuration

NAWS respects standard AWS configuration:
- `AWS_PROFILE` environment variable
- `AWS_REGION` environment variable  
- `AWS_ENDPOINT_URL` environment variable (for LocalStack)
- `~/.aws/config` and `~/.aws/credentials`
- SSO sessions

## Architecture

NAWS uses a registry-driven architecture:
- **`mod.nu`** - Main dispatcher with domain registry
- **Domain modules** - `s3.nu`, `sqs.nu`, `logs.nu`, `batch.nu`, `events.nu`
- **`shared.nu`** - Common utilities (auth, confirmations, editor)

Each domain exports a `naws_{domain}_domain_info` function that registers its commands with the dispatcher. This enables automatic tab completions and consistent help output.

## Contributing

See [AGENTS.md](AGENTS.md) for development guidelines including:
- How to run and test commands
- Code style conventions
- How to add new domains
- Error handling patterns

## License

MIT

## Acknowledgments

Built with [Nushell](https://nushell.sh) - A new type of shell that treats data as data.
