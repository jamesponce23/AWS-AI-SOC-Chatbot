# AWS AI SOC Chatbot

A cloud-native, AI-powered Security Operations Center (SOC) agent built entirely on AWS. It automatically ingests AWS CloudTrail logs, filters high-value security events, stores them in DynamoDB, and exposes a Cognito-authenticated web chatbot that lets you query your security posture in plain English — getting back AI-generated analysis and remediation steps powered by Meta Llama 3 via Amazon Bedrock.

---

## Project Overview

An AI-powered SOC agent built on AWS, using Llama 3 via Amazon Bedrock to automatically ingest, analyze, and answer questions about AWS CloudTrail security events through a web-based chatbot interface. Authentication is handled by Amazon Cognito (PKCE flow), the API is protected by a Cognito authorizer, and the entire stack is provisioned and hardened via Terraform with least-privilege IAM, a permission boundary, remote state, and a GitHub OIDC deployment pipeline.

---

## Architecture

```
AWS Activity (API calls, logins, IAM changes)
    ↓
CloudTrail — records all AWS API activity (log-file validation enabled)
    ↓
S3 Bucket (soc-copilot-logs-*) — CloudTrail delivers log files every 5–15 minutes
    (public-access block, SSE, versioning, SourceArn conditions)
    ↓
S3 Event Notification
    ↓
Lambda: soc-copilot-analyzer (app.py)
    - Decompresses .json.gz log files
    - Filters using an allowlist of high-value security events
    - Captures all AccessDenied / UnauthorizedOperation events
    - Stores results in DynamoDB with 30-day TTL
    ↓
DynamoDB: SOCAnalysis (SSE + PITR)
    - GSI (Source-Timestamp-Index) enables efficient time-range queries
    ↓
Cognito (user pool + PKCE public client) — login → JWT
    ↓
CloudFront — injects the x-api-key header (key never seen by the browser)
    ↓
API Gateway — POST /analyze
    (COGNITO_USER_POOLS authorizer validates the JWT; API key + usage plan
     enforce rate limiting: 10 req/s, burst 20, 1000/day quota)
    ↓
Lambda: soc-copilot-query (query_handler.py)
    - Parses natural language time intent ("today", "last week", etc.)
    - Sanitizes the query (prompt-injection defense)
    - Queries DynamoDB via GSI
    - Sends results to Bedrock for AI analysis
    ↓
Amazon Bedrock — Meta Llama 3 70B Instruct
    - Returns structured security analysis with remediation steps
    ↓
CloudFront + S3 — serves the web chatbot frontend (forwards Authorization header)
    ↓
Web Chatbot — analyst logs in, asks questions, gets AI-powered security summaries
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform (S3 remote state, S3-native locking) |
| Compute | AWS Lambda (Python 3.12) |
| AI Model | Meta Llama 3 70B via Amazon Bedrock |
| Database | Amazon DynamoDB |
| API | Amazon API Gateway (REST) |
| Auth | Amazon Cognito (user pool + PKCE public client) |
| Log Source | AWS CloudTrail |
| Storage | Amazon S3 |
| CDN / Frontend | Amazon CloudFront + S3 |
| CI/CD | GitHub Actions + AWS OIDC (federated, no long-lived keys) |

---

## Features

- **Natural language queries** — ask "what happened today?" or "show me suspicious events from last week" and get plain-English responses
- **Authenticated access** — the chatbot requires a Cognito login; the API Gateway rejects any request without a valid JWT
- **Automated ingestion** — CloudTrail logs flow into DynamoDB automatically via S3 event triggers, no manual steps
- **Smart event filtering** — allowlist-based approach stores only high-value security events (IAM changes, console logins, S3 policy changes, EC2 modifications, CloudTrail tampering, KMS key deletions, Secrets Manager changes)
- **Denied access detection** — any `AccessDenied` or `UnauthorizedOperation` event is always captured regardless of type, flagged as suspicious
- **AI-powered remediation** — every event comes back with WHAT HAPPENED, SEVERITY, ASSESSMENT, and step-by-step REMEDIATION commands
- **Time-range queries** — GSI-backed DynamoDB queries support today, yesterday, last hour, last 24/48 hours, last week, last month
- **Cost-controlled** — LLM is only called at query time, never during ingestion; 30-day TTL auto-purges old events
- **Prompt-injection resistant** — user queries are sanitized before being embedded into the Bedrock prompt
- **Rate limited & quota'd** — an API Gateway usage plan caps traffic at 10 req/s (burst 20) and 1000 requests/day; the API key is injected by CloudFront so it never reaches the browser
- **Fully automated deployment** — entire infrastructure provisioned with a single `terraform apply`, or via the GitHub Actions pipeline

---

## Key Components

### soc-copilot-analyzer (app.py)
- Triggered by S3 events when CloudTrail delivers new log files
- Decompresses `.json.gz` files from S3
- Filters events using an **allowlist** — only stores high-value security events
- Captures **any AccessDenied/UnauthorizedOperation** event regardless of type
- Stores events in DynamoDB with TTL (auto-deletes after 30 days)
- Adds `Source: "cloudtrail"` field for GSI queries

### soc-copilot-query (query_handler.py)
- Triggered by API Gateway POST /analyze (behind the Cognito authorizer)
- Parses time intent from natural language ("today", "last week", "last month" etc.)
- Sanitizes the incoming query to defend against prompt injection
- Queries DynamoDB using GSI (Source-Timestamp-Index) for efficient time-range lookups
- Falls back to full table scan if GSI fails
- Passes results to Llama 3 via Bedrock for AI analysis
- Returns plain-English security summary to the chatbot

### DynamoDB Table: SOCAnalysis
- **Hash key:** EventId (unique CloudTrail event UUID)
- **GSI:** Source-Timestamp-Index (Source as hash key, Timestamp as sort key — enables time-range queries)
- **TTL:** Auto-deletes events after 30 days
- **Security:** Server-side encryption (SSE) + point-in-time recovery (PITR) enabled
- **Fields:** EventId, Source, EventName, Timestamp, User, SourceIP, Bucket, ObjectKey, ErrorCode, Analysis, TTL

### Cognito Auth
- User pool with a PKCE public client and a hosted UI domain
- Sign-up is admin-only (`aws cognito-idp admin-create-user` + `admin-set-user-password`)
- Frontend runs the PKCE flow, obtains a JWT, and sends it in the `Authorization` header
- API Gateway `COGNITO_USER_POOLS` authorizer validates the JWT on every `/analyze` call

### Frontend (index.html / script.js / config.js)
- Simple chat UI with message history
- Handles the Cognito PKCE login flow before unlocking chat
- Sends authenticated POST requests to the API Gateway /analyze endpoint
- `config.js` (Cognito IDs, API URL) is generated by Terraform and uploaded to S3

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
| Any service | AccessDenied / AccessDeniedException / UnauthorizedOperation (always captured, stored as "EventName (DENIED)") |

---

## Deployment

### Prerequisites
- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- Python 3.12

### Deploy

```bash
cd terraform

# Lambda zips are built automatically by the archive_file data sources —
# no manual zipping required. Just:
terraform init
terraform apply
```

### Create your first user (sign-up is admin-only)

```bash
aws cognito-idp admin-create-user \
  --user-pool-id <pool-id> \
  --username <your-email>

aws cognito-idp admin-set-user-password \
  --user-pool-id <pool-id> \
  --username <your-email> \
  --password <password> --permanent
```

### Get your chatbot URL

```bash
terraform output cloudfront_url
```

### Update and redeploy after code changes

```bash
# Python changes are re-zipped automatically by Terraform's archive_file
terraform apply

# Invalidate CloudFront cache for stale frontend assets
aws cloudfront create-invalidation --distribution-id <your-id> --paths "/*"
```

### CI/CD (GitHub Actions + OIDC)
- `.github/workflows/deploy.yml` runs `terraform plan` on push/PR and applies only on a manual `workflow_dispatch`.
- Authentication is via a GitHub OIDC provider assuming the `soc-copilot-github-deploy` IAM role — no long-lived AWS keys are stored in GitHub.

---

## Usage

Open the CloudFront URL in your browser, log in through Cognito, then ask questions like:

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

## Issues Encountered & How They Were Resolved

### Bug 1 — Missing DynamoDB IAM Permission
**Problem:** Lambda had no DynamoDB permissions in IAM policy — caused immediate 500 errors on every query.
**Fix:** Added `dynamodb:Scan`, `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:Query` to the Lambda IAM role in `iam.tf`.

---

### Bug 2 — API Gateway Pointed to Wrong Lambda
**Problem:** The `/analyze` POST integration pointed to `soc-copilot-analyzer` (ingestion Lambda) instead of `soc-copilot-query` (query Lambda). Chat queries were hitting the wrong function entirely. This bug kept recurring every `terraform apply` because `api.tf` was never permanently fixed.
**Fix:** Updated `api.tf` to point `aws_api_gateway_integration` and `aws_lambda_permission` to `aws_lambda_function.query_api`. Added a second `aws_lambda_permission.apigw_query` resource.

---

### Bug 3 — Wrong Bedrock Model ID
**Problem:** `query_handler.py` used `"llama-3.3-70b-instruct"` which is not a valid Bedrock model ID, causing all Bedrock calls to fail.
**Fix:** Changed to correct model ID: `"meta.llama3-70b-instruct-v1:0"`.

---

### Bug 4 — Wrong Bedrock Request Format
**Problem:** `query_handler.py` was using `inputText`/`maxOutputTokens` — the Titan model format. Llama on Bedrock requires `prompt`/`max_gen_len`.
**Fix:** Updated request body to use correct Llama format matching `app.py`.

---

### Bug 5 — Wrong Bedrock Response Field
**Problem:** Code was reading `result.get("outputText")` from Bedrock response. Llama returns `generation` not `outputText`, so every successful call silently returned "No analysis returned".
**Fix:** Changed to `result.get("generation", "No analysis returned")`.

---

### Bug 6 — Query Parsed from Wrong Location
**Problem:** `query_handler.py` read from `queryStringParameters` (GET style) but the frontend sends POST with a JSON body. Result was always a 400 "Missing query parameter".
**Fix:** Changed to `body = json.loads(event.get("body") or "{}")` then `body.get("query")`.

---

### Bug 7 — Lambda Timeout Too Short
**Problem:** Default Lambda timeout of 3 seconds wasn't enough for a DynamoDB scan + Bedrock LLM call (which takes 5-15 seconds). Both Lambdas were timing out consistently.
**Fix:** Increased timeout to 60 seconds and memory to 256MB for both Lambdas in `lambda.tf` and AWS Console.

---

### Bug 8 — Bedrock Token Limit Exceeded
**Problem:** DynamoDB scan with no limit returned all items. Including the `Analysis` field (500 tokens per item) caused the combined prompt to exceed Llama's 8192 token limit.
**Fix:** Added `Limit=20` to DynamoDB scan, removed `Analysis` field from context, added hard cap of 3000 characters on context text.

---

### Bug 9 — Broken Python Indentation
**Problem:** Multiple times throughout development, code was pasted into editors that stripped indentation. Python requires strict indentation — broken indentation causes immediate syntax errors and Lambda crashes.
**Fix:** Always use VS Code with Python extension which enforces correct indentation automatically.

---

### Bug 10 — Unnecessary Import Crashing Lambda
**Problem:** `from click import prompt` in `query_handler.py`. `click` is a CLI framework not installed in the Lambda Python runtime, causing cold-start crashes before any code ran.
**Fix:** Removed the import entirely.

---

### Bug 11 — Runaway Bedrock Costs ($60 bill)
**Problem:** `soc-copilot-analyzer` was calling Bedrock once per CloudTrail event during ingestion. CloudTrail generates hundreds of events per hour, resulting in hundreds of Bedrock API calls and a $60 bill.
**Fix:** Disabled LLM call during ingestion entirely. Analysis now only happens at query time when the user asks a question. Added retry with exponential backoff (1s, 2s, 4s) for throttling.

---

### Bug 12 — LLM Generating Quiz Questions
**Problem:** Llama was returning multiple-choice quiz questions instead of security analysis. The plain prompt format was matching training data patterns.
**Fix:** Wrapped prompts in `<s>[INST]...[/INST]` tags — Llama's instruction format — which signals the model is being given a direct instruction rather than a text completion task. (Later migrated to the Llama 3 chat template — see Bug 20.)

---

### Bug 13 — DynamoDB Filled with Noise
**Problem:** Every CloudTrail event was being stored — `InvokeModel`, `DescribeAlarms`, `ListManagedNotificationEvents`, `AssumeRole`, `Decrypt` etc. DynamoDB was full of low-value events creating a feedback loop where the chatbot reported on its own activity.
**Fix:** Switched from a blocklist to an allowlist approach. Only explicitly whitelisted high-value security events are stored. Additionally any `AccessDenied`/`UnauthorizedOperation` error is always stored regardless of event type.

---

### Bug 14 — `requestParameters` NullPointerError
**Problem:** Some CloudTrail events have `requestParameters: null` instead of an empty object. Calling `.get("bucketName")` on `None` caused `AttributeError: 'NoneType' object has no attribute 'get'` crashing the ingestion Lambda mid-batch.
**Fix:** Changed to `req_params = e.get("requestParameters") or {}` which safely handles null values.

---

### Bug 15 — `Source` and `Timestamp` Reserved Keywords in DynamoDB
**Problem:** DynamoDB query using GSI failed with `ValidationException: Attribute name is a reserved keyword` for both `Source` and `Timestamp`.
**Fix:** Added expression attribute name aliases: `"#src": "Source"` and `"#ts": "Timestamp"` in the KeyConditionExpression.

---

### Bug 16 — Two Different Frontend Files, Two Different APIs
**Problem:** `index.html` used a GET request to one API endpoint, `script.js` used a POST request to a completely different API ID. Neither matched what Terraform actually deployed.
**Fix:** Consolidated to one frontend using POST to the correct Terraform output URL.

---

### Bug 17 — No Time-Based Query Support
**Problem:** DynamoDB had no way to efficiently query by time range. All queries did full table scans returning random items regardless of date.
**Fix:** Added a GSI (`Source-Timestamp-Index`) with `Source` as hash key and `Timestamp` as sort key. Added `get_time_range()` function to `query_handler.py` that parses natural language time expressions ("today", "last week", "last month" etc.) and queries the GSI efficiently.

---

### Bug 18 — Terraform Provider Bug with Deployment Triggers
**Problem:** Adding a `triggers` block to `aws_api_gateway_deployment` caused `Provider produced inconsistent final plan` error due to a known bug in the AWS Terraform provider v6.
**Fix:** Removed the `triggers` block entirely. Manual redeployment via `aws apigateway create-deployment` when needed.

---

### Bug 19 — Terminal Frozen in Pager
**Problem:** AWS CLI output opened in `less` pager. Pressing Ctrl+C instead of `q` left the terminal in a broken state where subsequent commands failed.
**Fix:** Disabled pager permanently: `aws configure set cli_pager ""`

---

### Bug 20 — Bedrock Returning Empty Responses (Llama 2 vs Llama 3 template)
**Problem:** The Lambda was using the Llama 2 prompt format (`<s>[INST]...[/INST]`) against a Llama 3 model. Llama 3 uses a completely different token structure (`<|begin_of_text|>`, `<|start_header_id|>`, `<|eot_id|>`), so generations came back empty.
**Fix:** Switched to the correct Llama 3 chat template, which resolved the empty-generation issue.

---

### Bug 21 — API Gateway 29-Second Hard Timeout
**Problem:** AWS API Gateway enforces a hard 29-second maximum timeout regardless of Lambda configuration. The Llama 3 70B model was exceeding this limit when generating long responses.
**Fix:** Reduced `max_gen_len` to keep Bedrock responses within the API Gateway timeout window.

---

### Bug 22 — Terraform Not Detecting Frontend File Changes
**Problem:** `aws_s3_object` resources without an `etag` attribute do not detect when source files change on disk, causing stale frontend files to remain in S3.
**Fix:** Added `etag = filemd5(...)` to the S3 object resources so Terraform re-uploads files whenever content changes.

---

## Recent Changes — Authentication & Security Hardening (July 2026)

The following work was completed, committed, and deployed in July 2026 to move the project from a functional prototype to a properly authenticated and least-privilege production posture.

### Change 1 — Added Real Authentication with Amazon Cognito
**Problem:** The chatbot API was completely open — anyone with the CloudFront URL could POST to `/analyze` and query the organization's security events with no authentication whatsoever.
**Fix:** Added a Cognito user pool with a PKCE public client and a hosted UI domain. Wired a `COGNITO_USER_POOLS` authorizer into the API Gateway `/analyze` methods in `api.tf`. Rewrote `chat_ui/script.js` to run the PKCE login flow, obtain a JWT, and send it in the `Authorization` header on every request; the gateway now validates the JWT before the request ever reaches Lambda. `config.js` (Cognito IDs + API URL) is generated by Terraform (`s3.tf`) and CloudFront was configured to forward the `Authorization` header. Sign-up is admin-only via `admin-create-user` + `admin-set-user-password`.

---

### Change 2 — Locked Down CORS
**Problem:** CORS was wide open (`Access-Control-Allow-Origin: *`), so any website could call the API from a victim's browser.
**Fix:** Restricted CORS to the chat-UI CloudFront origin only — both in `api.tf` and via an `ALLOWED_ORIGIN` environment variable enforced in both Lambda handlers.

---

### Change 3 — IAM Least-Privilege on the Lambda Role
**Problem:** The Lambda execution role carried `AmazonDynamoDBFullAccess` and broad Bedrock access — far more than it needed, violating least privilege.
**Fix:** Removed `AmazonDynamoDBFullAccess`. Scoped DynamoDB permissions to the specific table ARN plus `/index/*`, and scoped Bedrock to the single model ARN the app actually invokes.

---

### Change 4 — Hardened Storage & Data Services
**Problem:** S3 buckets, DynamoDB, and CloudTrail lacked baseline data-protection controls.
**Fix:** Applied a public-access block, server-side encryption, versioning, and `SourceArn` conditions to S3; enabled SSE + point-in-time recovery (PITR) on DynamoDB; enabled log-file validation on CloudTrail (tamper detection).

---

### Change 5 — Prompt-Injection Sanitization
**Problem:** User queries were passed straight into the Bedrock prompt, allowing prompt-injection attacks to manipulate the model's behavior.
**Fix:** Added a `sanitize_query()` function to both handlers that cleans user input before it is embedded into the LLM prompt.

---

### Change 6 — Reliable Lambda Packaging
**Problem:** Python edits weren't reliably deploying because zips were built by hand outside of Terraform's dependency graph.
**Fix:** `lambda.tf` now builds the deployment zips via `archive_file` data sources (added the `archive` provider), so Python source edits are re-packaged and deployed automatically on `terraform apply`.

---

### Change 7 — "Option (b)" Hardening: Permission Boundary, Least-Privilege Deployer, Remote State, OIDC
This was a three-part hardening pass to lock down not just the running app but the deployment identity and state as well.

**b1 — Permission boundary + least-privilege deployer:**
- Added a permission boundary `soc-copilot-lambda-boundary` on the Lambda role (`boundary.tf`), defined as a superset of the role's inline policy so the role can never escalate beyond it.
- Created a `SOCCopilotDeployer` customer-managed policy (`deployer.tf`) scoped to only the 9 services the project actually uses (S3, DynamoDB, Lambda, IAM-role, CloudTrail scoped to `soc-copilot-*`/`SOCAnalysis`; CloudFront + Cognito left at `*` due to no resource-level scoping at create time; `iam:PassRole` limited to the Lambda role with `iam:PassedToService=lambda.amazonaws.com`). Attached it to both `terraform-user` and the OIDC deploy role.
- **Removed** the over-privileged `terraform-users-group` from `terraform-user`, dropping unused EC2/RDS/Route53 access plus full Dynamo/S3/IAM/Lambda/Bedrock/Cognito. Validated by a real `plan` + `apply` under the reduced permissions (exit 0). Rollback if a future permission gap appears: `aws iam add-user-to-group --group-name terraform-users-group --user-name terraform-user`.

**b2 — Remote state:**
- Migrated Terraform state to an S3 backend bucket `soc-copilot-tfstate-*` (versioned, SSE, public-access block, `prevent_destroy`) using **S3-native locking** (`use_lockfile = true` in the `main.tf` backend). The local `terraform.tfstate` remains as a backup. (An earlier DynamoDB lock table was used and then removed in favor of native locking.)

**b3 — GitHub OIDC deployment pipeline:**
- Added a GitHub OIDC provider and the `soc-copilot-github-deploy` role (`oidc.tf`), with trust scoped to the `jamesponce23/AWS-AI-SOC-Chatbot` repo on `refs/heads/main`.
- Added `.github/workflows/deploy.yml`: `terraform plan` on push/PR, `apply` only on manual `workflow_dispatch`. No long-lived AWS keys stored in GitHub.

New Terraform files from this pass: `boundary.tf`, `deployer.tf`, `remote_state.tf`, `oidc.tf`, `variables.tf`, plus edits to `iam.tf` / `main.tf` and the GitHub Actions workflow.

---

### Change 8 — localStorage Chat History Doubling (found during first real login)
**Problem:** `chat_ui/script.js` doubled `chatHistory` in localStorage on every page load — the replay path re-persisted the entire history each time, which grew unbounded and eventually froze the browser.
**Fix:** Added a `persist` flag to `appendMessage()`; the replay path passes `false` so re-rendered history is not re-saved. Redeployed via Terraform + a CloudFront invalidation.

---

### Change 9 — API Key + Usage Plan (rate limiting, quota, browser-invisible key)
**Problem:** Even behind Cognito, the API had no rate limiting or quota, and there was no defense-in-depth secret gating access to the gateway — a leaked or abused JWT could hammer the endpoint and run up Bedrock costs.
**Fix:** Added an API Gateway API key (`soc-copilot-api-key`) with `api_key_required = true` on the `/analyze` methods, backed by a usage plan (`soc-copilot-usage-plan`): **throttle** 10 req/s with a burst of 20, and a **quota** of 1000 requests/day, applied to both the dev and prod stages (`api.tf`).

Crucially, the key is **never exposed to the browser**. Instead of shipping the key in frontend JavaScript, the CloudFront distribution injects it as a custom `x-api-key` origin header (`cloudfront.tf`) — the key lives only in AWS config, and the browser talks to CloudFront, which adds the header before forwarding to API Gateway. The key value is exposed as a `sensitive` Terraform output (`api_key_value`) for operational use only.

---

## Lessons Learned

1. **Test each layer independently** — Lambda direct test → curl API Gateway → frontend. Don't debug frontend when backend is broken.
2. **CloudWatch logs are your best friend** — every bug was ultimately diagnosed from CloudWatch error messages.
3. **Allowlists beat blocklists** for event filtering — you can't predict all noisy events but you know exactly what matters.
4. **LLM costs can spiral fast** — never call an LLM inside an event-driven ingestion pipeline without strict rate controls.
5. **DynamoDB reserved keywords** are a common gotcha — always use expression attribute name aliases for field names.
6. **Use VS Code** for Python Lambda development — indentation errors are the #1 cause of silent failures.
7. **Terraform state and live AWS can drift** — always fix both the console AND the Terraform file or changes revert on next apply.
8. **Authenticate before you expose** — a security tool with an open API is itself an attack surface; put Cognito + an authorizer in front of anything internet-facing from day one.
9. **IAM is additive** — a user-level policy can't shrink a group's Allows; you must remove the group membership (or add an explicit Deny). Boundaries and SCPs only cap, never grant.
10. **Least privilege applies to the deployer too** — scope the deploy identity, use a permission boundary, keep state remote and encrypted, and prefer OIDC federation over long-lived keys.

---

## Infrastructure Files

| File | Purpose |
|---|---|
| `main.tf` | Provider config, S3 remote-state backend, DynamoDB table with GSI and TTL |
| `lambda.tf` | Both Lambda functions, built via `archive_file` |
| `api.tf` | API Gateway REST API, /analyze POST route, Cognito authorizer, API key + usage plan (rate limit/quota), CORS, dev/prod stages |
| `iam.tf` | IAM roles and policies (least-privilege) |
| `s3.tf` | S3 buckets, OAC, frontend + `config.js` uploads |
| `cloudfront.tf` | CloudFront distribution; injects the `x-api-key` header so the key never reaches the browser |
| `cloudtrail.tf` | CloudTrail trail configuration (log-file validation) |
| `cognito.tf` | Cognito user pool, PKCE client, hosted UI domain |
| `boundary.tf` | Permission boundary for the Lambda role |
| `deployer.tf` | `SOCCopilotDeployer` least-privilege deployer policy |
| `remote_state.tf` | S3 state bucket (versioned, SSE, PAB) |
| `oidc.tf` | GitHub OIDC provider + `soc-copilot-github-deploy` role |
| `variables.tf` | Input variables |
| `.github/workflows/deploy.yml` | CI/CD: plan on push/PR, apply on manual dispatch |

---

## Current Status: Fully Operational 

- Real CloudTrail events flowing through the pipeline
- Cognito authentication enforced end-to-end (PKCE → JWT → API Gateway authorizer)
- Only high-value security events stored in DynamoDB
- Time-based natural language queries working
- Unauthorized/denied access events automatically flagged
- 30-day TTL auto-cleanup configured
- Bedrock costs controlled — LLM only called at query time
- Least-privilege IAM on both the Lambda role and the deploy identity, with a permission boundary
- Remote encrypted Terraform state with S3-native locking
- GitHub OIDC deployment pipeline (no long-lived keys)
