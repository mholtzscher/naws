#!/usr/bin/env nu
# Test script for NAWS with LocalStack
# This script configures the environment for LocalStack and provides helper commands

# Set LocalStack environment variables
$env.AWS_ENDPOINT_URL = "http://localhost:4566"
$env.AWS_ACCESS_KEY_ID = "test"
$env.AWS_SECRET_ACCESS_KEY = "test"
$env.AWS_DEFAULT_REGION = "us-east-1"
$env.AWS_PROFILE = "localstack"

print "================================================"
print "NAWS LocalStack Test Environment"
print "================================================"
print ""
print "LocalStack endpoint configured: http://localhost:4566"
print ""
print "Available test commands:"
print "  • naws s3 list         - Browse demo files bucket"
print "  • naws sqs list        - See test queues"
print "  • naws sqs receive     - Read messages from test queue"
print "  • naws logs groups     - Browse CloudWatch log groups"
print "  • naws logs tail       - Tail log streams"
print "  • naws events put-event - Send test event"
print ""
print "To use NAWS with LocalStack, run these commands in this shell"
print "or export the environment variables to your shell:"
print ""
print "  export AWS_ENDPOINT_URL=http://localhost:4566"
print "  export AWS_ACCESS_KEY_ID=test"
print "  export AWS_SECRET_ACCESS_KEY=test"
print "  export AWS_DEFAULT_REGION=us-east-1"
print ""
print "================================================"

# Load NAWS module
use mod.nu *

# Configure AWS CLI wrapper for LocalStack
alias awslocal = aws --endpoint-url http://localhost:4566

# Helper function to check LocalStack status
def "check-localstack" [] {
  print "Checking LocalStack health..."
  let health = (http get http://localhost:4566/_localstack/health | from json)
  print $health
}

# Helper function to show LocalStack resources
def "show-resources" [] {
  print "=== S3 Buckets ==="
  awslocal s3 ls
  print ""
  
  print "=== SQS Queues ==="
  awslocal sqs list-queues | from json | get QueueUrls? | default []
  print ""
  
  print "=== CloudWatch Log Groups ==="
  awslocal logs describe-log-groups --query 'logGroups[*].logGroupName' --output table
  print ""
  
  print "=== EventBridge Buses ==="
  awslocal events list-event-buses --query 'EventBuses[*].Name' --output table
}

print "Helper commands available:"
print "  • check-localstack  - Check LocalStack health"
print "  • show-resources    - List all created resources"
print "  • awslocal         - AWS CLI configured for LocalStack"
print ""
