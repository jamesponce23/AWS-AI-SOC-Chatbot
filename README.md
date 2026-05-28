# AWS AI SOC Chatbot

A cloud-native, AI-powered Security Operations Center (SOC) agent built entirely on AWS. It automatically ingests AWS CloudTrail logs, filters high-value security events, stores them in DynamoDB, and exposes a web-based chatbot that lets you query your security posture in plain English — getting back AI-generated analysis and remediation steps powered by Meta Llama 3 via Amazon Bedrock.

---

## Architecture

```
AWS Activity (API calls, logins, IAM changes)
    ↓
CloudTrail — records all AWS API activity
    ↓
S3 Bucket — CloudTrail delivers log files every 5–15 minutes
    ↓
Lambda: soc-copilot-analyzer (app.py)
    - Decompresses .json.gz log files
    - Filters using an allowlist of high-value security events
    - Captures all AccessDenied / UnauthorizedOperation events
    - Stores results in DynamoDB with 30-day TTL
    ↓
DynamoDB: SOCAnalysis
    - GSI (Source-Timestamp-Index) enables efficient time-range queries
    ↓
API Gateway — POST /analyze
    ↓
Lambda: soc-copilot-query (query_handler.py)
    - Parses natural language time intent ("today", "last week", etc.)
    - Queries DynamoDB via GSI
    - Sends results to Bedrock for AI analysis
    ↓
Amazon Bedrock — Meta Llama 3 70B Instruct
    - Returns structured security analysis with remediation steps
    ↓
CloudFront + S3 — serves the web chatbot frontend
    ↓
Web Chatbot — analyst asks questions, gets AI-powered security summaries
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform |
| Compute | AWS Lambda (Python 3.12) |
| AI Model | Meta Llama 3 70B via Amazon Bedrock |
| Database | Amazon DynamoDB |
| API | Amazon API Gateway (REST) |
| Log Source | AWS CloudTrail |
| Storage | Amazon S3 |
| CDN / Frontend | Amazon CloudFront + S3 |

---

## Features

- **Natural language queries** — ask "what happened today?" or "show me suspicious events from last week" and get plain-English responses
- **Automated ingestion** — CloudTrail logs flow into DynamoDB automatically via S3 event triggers, no manual steps
- **Smart event filtering** — allowlist-based approach stores only high-value security events (IAM changes, console logins, S3 policy changes, EC2 modifications, CloudTrail tampering, KMS key deletions, Secrets Manager changes)
- **Denied access detection** — any `AccessDenied` or `UnauthorizedOperation` event is always captured regardless of type, flagged as suspicious
- **AI-powered remediation** — every event comes back with WHAT HAPPENED, SEVERITY, ASSESSMENT, and step-by-step REMEDIATION commands
- **Time-range queries** — GSI-backed DynamoDB queries support today, yesterday, last hour, last 24/48 hours, last week, last month
- **Cost-controlled** — LLM is only called at query time, never during ingestion; 30-day TTL auto-purges old events
- **Fully automated deployment** — entire infrastructure provisioned with a single `terraform apply`

---

## Security Events Monitored

| Category | Events |
|---|---|
| IAM | CreateUser, DeleteUser, CreateRole, AttachRolePolicy, CreateAccessKey, UpdateLoginProfile, and more |
| S3 | CreateBucket, DeleteBucket, PutBucketPolicy, PutBucketAcl, PutBucketPublicAccessBlock |
| Auth | ConsoleLogin, SwitchRole |
| EC2 | RunInstances, TerminateInstances, AuthorizeSecurityGroupIngress |
| CloudTrail | StopLogging, DeleteTrail, UpdateTrail (tampering detection) |
| KMS | DisableKey, ScheduleKeyDeletion |
| Secrets Manager | DeleteSecret, PutSecretValue |
| Any service | AccessDenied / UnauthorizedOperation (always captured) |

---

## Deployment

### Prerequisites
- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- Python 3.12

### Deploy

```bash
cd terraform

# Package Lambda functions
zip function.zip lambda/app.py
zip query_function.zip lambda/query_handler.py

# Deploy all infrastructure
terraform init
terraform apply
```

### Get your chatbot URL

```bash
terraform output cloudfront_url
```

### Update and redeploy after code changes

```bash
zip -u function.zip lambda/app.py
zip -u query_function.zip lambda/query_handler.py
terraform apply

# Invalidate CloudFront cache
aws cloudfront create-invalidation --distribution-id <your-id> --paths "/*"
```

---

## Usage

Open the CloudFront URL in your browser and ask questions like:

- `"What happened in the last 30 days?"`
- `"Show me any denied events from this week"`
- `"Were there any IAM changes today?"`
- `"Did anyone log in to the console yesterday?"`

Example response:

```
EVENT: ConsoleLogin - User: arn:aws:iam::123456789:root - IP: 203.0.113.42
WHAT HAPPENED: The AWS root user logged in to the AWS Management Console from an external IP address.
SEVERITY: High
ASSESSMENT: Suspicious. Root user login should be rare and only for emergency situations.
REMEDIATION:
- Verify immediately whether this login was authorized by your team
- If unauthorized: change the root user password and enable MFA
- Investigate all other CloudTrail activity from IP 203.0.113.42
- Review and tighten IAM password policy
```

---

## Challenges & Solutions

### Bedrock returning empty responses
The Lambda was using the Llama 2 prompt format (`<s>[INST]...[/INST]`) against a Llama 3 model. Llama 3 uses a completely different token structure (`<|begin_of_text|>`, `<|start_header_id|>`, `<|eot_id|>`). Switching to the correct Llama 3 chat template resolved the empty generation issue.

### API Gateway 29-second timeout
AWS API Gateway enforces a hard 29-second maximum timeout regardless of Lambda configuration. The Llama 3 70B model was exceeding this limit when generating long responses. Reduced `max_gen_len` to keep Bedrock responses within the timeout window.

### DynamoDB reserved keyword errors
DynamoDB rejected queries using `Source` and `Timestamp` as attribute names because both are reserved keywords. Resolved by adding expression attribute name aliases (`#src`, `#ts`) to all query expressions.

### Runaway Bedrock costs
The original design called Bedrock once per CloudTrail event during ingestion. CloudTrail generates hundreds of events per hour, resulting in hundreds of LLM calls and significant unexpected costs. Moved all LLM calls to query time only, with exponential backoff retry logic for throttling.

### Terraform not detecting frontend file changes
`aws_s3_object` resources without an `etag` attribute do not detect when source files change on disk, causing stale frontend files to remain in S3. Added `etag = filemd5(...)` to both S3 object resources so Terraform re-uploads files whenever content changes.

### Event noise creating feedback loop
Storing all CloudTrail events caused DynamoDB to fill with low-value noise (`InvokeModel`, `AssumeRole`, `Decrypt`, etc.), including the SOC agent's own activity. Switched from a blocklist to an allowlist approach — only explicitly whitelisted high-value security events are stored.

---

## Infrastructure Files

| File | Purpose |
|---|---|
| `main.tf` | Provider config, DynamoDB table with GSI and TTL |
| `lambda.tf` | Both Lambda functions |
| `api.tf` | API Gateway REST API, /analyze POST route, CORS, dev/prod stages |
| `iam.tf` | IAM roles and policies |
| `s3.tf` | S3 buckets, CloudFront distribution, OAC, frontend file uploads |
| `cloudtrail.tf` | CloudTrail trail configuration |
