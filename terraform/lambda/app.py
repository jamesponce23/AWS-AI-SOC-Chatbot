import json
import boto3
import gzip
import os
import time
from datetime import datetime, timezone, timedelta

# =========================
# AWS Clients
# =========================
s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")
bedrock = boto3.client("bedrock-runtime")

# =========================
# Config
# =========================
DDB_TABLE = os.environ.get("DDB_TABLE", "SOCAnalysis")
MODEL_ID = "meta.llama3-70b-instruct-v1:0"
TTL_DAYS = 30

# =========================
# Only store these high-value security events
# =========================
ALLOW_EVENTS = {
    # IAM - user/role/key changes
    "CreateUser",
    "DeleteUser",
    "UpdateUser",
    "CreateRole",
    "DeleteRole",
    "AttachUserPolicy",
    "DetachUserPolicy",
    "AttachRolePolicy",
    "DetachRolePolicy",
    "CreateAccessKey",
    "DeleteAccessKey",
    "UpdateAccessKey",
    "CreateLoginProfile",
    "DeleteLoginProfile",
    "UpdateLoginProfile",
    # S3 - bucket level changes
    "CreateBucket",
    "DeleteBucket",
    "PutBucketPolicy",
    "DeleteBucketPolicy",
    "PutBucketAcl",
    "PutBucketPublicAccessBlock",
    # Console & auth
    "ConsoleLogin",
    "SwitchRole",
    # EC2
    "RunInstances",
    "TerminateInstances",
    "StopInstances",
    "AuthorizeSecurityGroupIngress",
    "RevokeSecurityGroupIngress",
    # Network
    "CreateVpc",
    "DeleteVpc",
    "CreateInternetGateway",
    # CloudTrail
    "StopLogging",
    "DeleteTrail",
    "UpdateTrail",
    # KMS
    "DisableKey",
    "ScheduleKeyDeletion",
    # Secrets
    "DeleteSecret",
    "PutSecretValue",
}

# Error codes that indicate unauthorized/denied access
DENY_CODES = {
    "AccessDenied",
    "AccessDeniedException",
    "Client.UnauthorizedAccess",
    "UnauthorizedOperation",
}

# =========================
# LLM Call with retry/backoff
# =========================
def analyze_with_llama(prompt: str) -> str:
    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = bedrock.invoke_model(
                modelId=MODEL_ID,
                contentType="application/json",
                accept="application/json",
                body=json.dumps({
                    "prompt": prompt,
                    "max_gen_len": 500,
                    "temperature": 0.2
                })
            )
            result = json.loads(response["body"].read())
            return result.get("generation", "No analysis returned")
        except bedrock.exceptions.ThrottlingException:
            wait = 2 ** attempt
            print(f"Throttled by Bedrock, retrying in {wait}s... (attempt {attempt + 1}/{max_retries})")
            time.sleep(wait)
        except Exception as e:
            print("LLM call failed:", e)
            return "No response from SOC Copilot."
    return "SOC Copilot is busy, please try again in a moment."

# =========================
# Helper to build DynamoDB entry
# =========================
def extract_event_fields(e: dict, override_name: str = None) -> dict:
    identity = e.get("userIdentity", {})

    user = (
        identity.get("userName") or
        identity.get("sessionContext", {}).get("sessionIssuer", {}).get("userName") or
        identity.get("arn", "").split("/")[-1] or
        identity.get("type", "unknown")
    )

    # Safely get requestParameters - can be None for some event types
    req_params = e.get("requestParameters") or {}

    ttl_timestamp = int((datetime.now(timezone.utc) + timedelta(days=TTL_DAYS)).timestamp())

    return {
        "EventId":   {"S": e.get("eventID", "unknown")},
        "Source":    {"S": "cloudtrail"},
        "EventName": {"S": override_name or e.get("eventName", "unknown")},
        "Timestamp": {"S": e.get("eventTime", "unknown")},
        "User":      {"S": user},
        "SourceIP":  {"S": e.get("sourceIPAddress", "unknown")},
        "Bucket":    {"S": req_params.get("bucketName", "n/a")},
        "ObjectKey": {"S": req_params.get("key", "n/a")},
        "ErrorCode": {"S": e.get("errorCode", "n/a")},
        "Analysis":  {"S": ""},
        "TTL":       {"N": str(ttl_timestamp)}
    }

# =========================
# S3 Event Handler
# =========================
def handle_s3(event):
    print("S3 event received")
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]

        obj = s3.get_object(Bucket=bucket, Key=key)
        data = obj["Body"].read()

        if key.endswith(".gz"):
            try:
                data = gzip.decompress(data)
            except Exception as e:
                print(f"Failed to decompress {key}: {e}")
                continue

        try:
            logs = json.loads(data.decode("utf-8"))
        except Exception as e:
            print(f"Failed to parse JSON from {key}: {e}")
            continue

        for e in logs.get("Records", []):
            event_name = e.get("eventName", "")
            error_code = e.get("errorCode", "")

            # Always store high-value security events
            if event_name in ALLOW_EVENTS:
                item = extract_event_fields(e)
                try:
                    ddb.put_item(TableName=DDB_TABLE, Item=item)
                    print(f"Stored security event: {event_name}")
                except Exception as ex:
                    print(f"DynamoDB write failed for {event_name}: {ex}")
                continue

            # Store ANY denied/unauthorized event - always suspicious
            if error_code in DENY_CODES:
                item = extract_event_fields(e, override_name=f"{event_name} (DENIED)")
                try:
                    ddb.put_item(TableName=DDB_TABLE, Item=item)
                    print(f"Stored denied event: {event_name} - {error_code}")
                except Exception as ex:
                    print(f"DynamoDB write failed for denied {event_name}: {ex}")
                continue

            print(f"Skipping low-value event: {event_name}")

    return {"statusCode": 200, "body": "S3 events processed."}

# =========================
# API Gateway Handler
# =========================
def handle_api(event):
    print("API request received")
    body = json.loads(event.get("body", "{}"))
    user_query = body.get("query", "").strip()
    if not user_query:
        return {"statusCode": 400, "body": "Missing query"}

    scan_resp = ddb.scan(TableName=DDB_TABLE, Limit=20)
    items = scan_resp.get("Items", [])

    context_lines = [
        f"{item.get('Timestamp', {}).get('S', '')} - "
        f"{item.get('EventName', {}).get('S', '')} - "
        f"User: {item.get('User', {}).get('S', '')} - "
        f"IP: {item.get('SourceIP', {}).get('S', '')} - "
        f"Error: {item.get('ErrorCode', {}).get('S', 'n/a')}"
        for item in items
    ]
    context_text = "\n".join(context_lines)

    if len(context_text) > 3000:
        context_text = context_text[:3000]

    combined_prompt = (
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        "You are a senior cloud security analyst. "
        "Use the provided SOC findings to answer in clear, human-readable text. "
        "No questions, no multiple choice, plain paragraphs only. "
        "Flag any DENIED events as suspicious."
        "<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
        f"User question: {user_query}\n\nLogs:\n{context_text}"
        "<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
    )

    try:
        answer = analyze_with_llama(combined_prompt)
    except Exception as e:
        print("LLM call failed:", e)
        answer = "No response from SOC Copilot."

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps({"query": user_query, "response": answer})
    }

# =========================
# Main Lambda Handler
# =========================
def handler(event, context):
    print("EVENT:", json.dumps(event)[:1000])
    if "httpMethod" in event:
        return handle_api(event)
    if "Records" in event:
        return handle_s3(event)
    return {"statusCode": 400, "body": "Unknown event type"}