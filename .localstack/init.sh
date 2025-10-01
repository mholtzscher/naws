#!/bin/bash

# LocalStack initialization script for NAWS testing
# This script creates sample resources for all NAWS domains
# Runs automatically when LocalStack container starts

set -e

echo "================================================"
echo "Initializing LocalStack for NAWS Testing"
echo "================================================"

# Wait for LocalStack to be fully ready
echo "Waiting for LocalStack services to be ready..."
sleep 5

# S3 Setup
echo ""
echo "=== Setting up S3 ==="
echo "Creating test S3 buckets..."
awslocal s3 mb s3://naws-test-bucket-1
awslocal s3 mb s3://naws-test-bucket-2
awslocal s3 mb s3://naws-demo-files

echo "Uploading sample objects to S3..."
echo "Sample file 1" > /tmp/sample1.txt
echo "Sample file 2" > /tmp/sample2.txt
echo "README content" > /tmp/readme.md
awslocal s3 cp /tmp/sample1.txt s3://naws-demo-files/documents/sample1.txt
awslocal s3 cp /tmp/sample2.txt s3://naws-demo-files/documents/sample2.txt
awslocal s3 cp /tmp/readme.md s3://naws-demo-files/readme.md

echo "Creating nested folder structure..."
echo "Config data" > /tmp/config.json
echo "Log entry 1" > /tmp/log1.txt
echo "Log entry 2" > /tmp/log2.txt
awslocal s3 cp /tmp/config.json s3://naws-demo-files/configs/production/config.json
awslocal s3 cp /tmp/log1.txt s3://naws-demo-files/logs/2024/01/log1.txt
awslocal s3 cp /tmp/log2.txt s3://naws-demo-files/logs/2024/01/log2.txt

echo "✓ S3 setup complete"

# SQS Setup
echo ""
echo "=== Setting up SQS ==="
echo "Creating standard queues..."
awslocal sqs create-queue --queue-name naws-test-queue
awslocal sqs create-queue --queue-name naws-demo-queue
awslocal sqs create-queue --queue-name naws-notifications

echo "Creating FIFO queue..."
awslocal sqs create-queue --queue-name naws-fifo-queue.fifo --attributes FifoQueue=true

echo "Sending sample messages to test queue..."
QUEUE_URL=$(awslocal sqs get-queue-url --queue-name naws-test-queue --query QueueUrl --output text)
awslocal sqs send-message --queue-url "$QUEUE_URL" --message-body "Test message 1"
awslocal sqs send-message --queue-url "$QUEUE_URL" --message-body "Test message 2"
awslocal sqs send-message --queue-url "$QUEUE_URL" --message-body "Test message 3"

echo "Sending messages to demo queue..."
DEMO_QUEUE_URL=$(awslocal sqs get-queue-url --queue-name naws-demo-queue --query QueueUrl --output text)
awslocal sqs send-message --queue-url "$DEMO_QUEUE_URL" --message-body "Demo message 1" --message-attributes '{"Priority":{"DataType":"Number","StringValue":"1"}}'
awslocal sqs send-message --queue-url "$DEMO_QUEUE_URL" --message-body "Demo message 2" --message-attributes '{"Priority":{"DataType":"Number","StringValue":"2"}}'

echo "✓ SQS setup complete"

# CloudWatch Logs Setup
echo ""
echo "=== Setting up CloudWatch Logs ==="
echo "Creating log groups..."
awslocal logs create-log-group --log-group-name /aws/lambda/naws-test-function
awslocal logs create-log-group --log-group-name /aws/ecs/naws-demo-service
awslocal logs create-log-group --log-group-name /application/naws-app

echo "Setting retention policies..."
awslocal logs put-retention-policy --log-group-name /aws/lambda/naws-test-function --retention-in-days 7
awslocal logs put-retention-policy --log-group-name /aws/ecs/naws-demo-service --retention-in-days 14

echo "Creating log streams and adding log events..."
awslocal logs create-log-stream --log-group-name /aws/lambda/naws-test-function --log-stream-name 2024/09/30/stream-1
awslocal logs create-log-stream --log-group-name /aws/lambda/naws-test-function --log-stream-name 2024/09/30/stream-2

# Add log events
TIMESTAMP=$(date +%s)000
awslocal logs put-log-events \
  --log-group-name /aws/lambda/naws-test-function \
  --log-stream-name 2024/09/30/stream-1 \
  --log-events \
    timestamp=$TIMESTAMP,message="[INFO] Application started" \
    timestamp=$((TIMESTAMP+1000)),message="[INFO] Processing request" \
    timestamp=$((TIMESTAMP+2000)),message="[WARN] High memory usage detected" \
    timestamp=$((TIMESTAMP+3000)),message="[INFO] Request completed successfully"

awslocal logs create-log-stream --log-group-name /application/naws-app --log-stream-name app-stream-1
awslocal logs put-log-events \
  --log-group-name /application/naws-app \
  --log-stream-name app-stream-1 \
  --log-events \
    timestamp=$TIMESTAMP,message="Application log entry 1" \
    timestamp=$((TIMESTAMP+1000)),message="Application log entry 2"

echo "✓ CloudWatch Logs setup complete"

# EventBridge Setup
echo ""
echo "=== Setting up EventBridge ==="
echo "Creating custom event bus..."
awslocal events create-event-bus --name naws-custom-bus

echo "Creating event rules..."
awslocal events put-rule \
  --name naws-test-rule \
  --event-pattern '{"source": ["naws.test"]}' \
  --description "Rule for NAWS test events"

echo "Creating EventBridge Scheduler schedules..."
# Note: LocalStack may have limited support for Scheduler API
# These commands may need adjustment based on LocalStack version
echo "Attempting to create schedules (may not be fully supported in LocalStack)..."
awslocal scheduler create-schedule \
  --name naws-hourly-schedule \
  --schedule-expression "rate(1 hour)" \
  --flexible-time-window Mode=OFF \
  --target '{
    "Arn": "arn:aws:lambda:us-east-1:000000000000:function:naws-test",
    "RoleArn": "arn:aws:iam::000000000000:role/scheduler-role"
  }' 2>/dev/null || echo "  (Scheduler API may not be available in LocalStack)"

echo "✓ EventBridge setup complete"

# AWS Batch Setup
echo ""
echo "=== Setting up AWS Batch ==="
echo "Note: AWS Batch setup requires additional LocalStack Pro features"
echo "Creating basic Batch resources (may have limited functionality)..."

# Create IAM roles needed for Batch
echo "Creating IAM roles for Batch..."
awslocal iam create-role \
  --role-name naws-batch-service-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "batch.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "  (Role may already exist)"

awslocal iam create-role \
  --role-name naws-ecs-instance-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "  (Role may already exist)"

# Note: Full Batch setup requires compute environment and job queue
# LocalStack free tier has limited Batch support
echo "  (Full Batch testing may require LocalStack Pro)"

echo "✓ AWS Batch setup complete (limited)"

# Summary
echo ""
echo "================================================"
echo "LocalStack Initialization Complete!"
echo "================================================"
echo ""
echo "Available resources for NAWS testing:"
echo ""
echo "S3 Buckets:"
echo "  - naws-test-bucket-1 (empty)"
echo "  - naws-test-bucket-2 (empty)"
echo "  - naws-demo-files (contains sample files)"
echo ""
echo "SQS Queues:"
echo "  - naws-test-queue (standard, with 3 messages)"
echo "  - naws-demo-queue (standard, with 2 messages)"
echo "  - naws-notifications (standard, empty)"
echo "  - naws-fifo-queue.fifo (FIFO, empty)"
echo ""
echo "CloudWatch Log Groups:"
echo "  - /aws/lambda/naws-test-function (with streams and events)"
echo "  - /aws/ecs/naws-demo-service (empty)"
echo "  - /application/naws-app (with events)"
echo ""
echo "EventBridge:"
echo "  - Default event bus"
echo "  - naws-custom-bus"
echo "  - naws-test-rule"
echo ""
echo "================================================"
echo "To use with NAWS, set these environment variables:"
echo "  export AWS_ENDPOINT_URL=http://localhost:4566"
echo "  export AWS_ACCESS_KEY_ID=test"
echo "  export AWS_SECRET_ACCESS_KEY=test"
echo "  export AWS_DEFAULT_REGION=us-east-1"
echo "================================================"
