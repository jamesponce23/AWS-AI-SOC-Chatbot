import json
import os
import boto3
import time
from datetime import datetime, timezone, timedelta

# Initialize clients
ddb = boto3.client("dynamodb")
bedrock = boto3.client("bedrock-runtime")
DDB_TABLE = os.environ.get("DDB_TABLE", "SOCAnalysis")
GSI_NAME = "Source-Timestamp-Index"


def analyze_with_llama(prompt):
    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = bedrock.invoke_model(
                modelId="meta.llama3-70b-instruct-v1:0",
                contentType="application/json",
                accept="application/json",
                body=json.dumps({
                    "prompt": prompt,
                    "max_gen_len": 512,
                    "temperature": 0.2
                }),
            )
            result = json.loads(response["body"].read())
            return result.get("generation", "No analysis returned")
        except bedrock.exceptions.ThrottlingException:
            wait = 2 ** attempt
            print(f"Throttled, retrying in {wait}s...")
            time.sleep(wait)
        except Exception as e:
            print("LLM call failed:", e)
            return "No response from SOC Copilot."
    return "SOC Copilot is busy, please try again in a moment."


def get_time_range(user_query: str):
    now = datetime.now(timezone.utc)
    query_lower = user_query.lower()

    if "today" in query_lower:
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        end = now
    elif "yesterday" in query_lower:
        yesterday = now - timedelta(days=1)
        start = yesterday.replace(hour=0, minute=0, second=0, microsecond=0)
        end = yesterday.replace(hour=23, minute=59, second=59, microsecond=0)
    elif "last week" in query_lower or "past week" in query_lower:
        start = now - timedelta(days=7)
        end = now
    elif "last month" in query_lower or "past month" in query_lower:
        start = now - timedelta(days=30)
        end = now
    elif "last hour" in query_lower or "past hour" in query_lower:
        start = now - timedelta(hours=1)
        end = now
    elif "last 24 hours" in query_lower or "past 24 hours" in query_lower:
        start = now - timedelta(hours=24)
        end = now
    elif "last 48 hours" in query_lower or "past 48 hours" in query_lower:
        start = now - timedelta(hours=48)
        end = now
    else:
        # Default to last 7 days
        start = now - timedelta(days=7)
        end = now

    return start.strftime("%Y-%m-%dT%H:%M:%SZ"), end.strftime("%Y-%m-%dT%H:%M:%SZ")


def query_events(start: str, end: str):
    print(f"Querying GSI for events between {start} and {end}")
    try:
        response = ddb.query(
            TableName=DDB_TABLE,
            IndexName=GSI_NAME,
            KeyConditionExpression="#src = :src AND #ts BETWEEN :start AND :end",
            ExpressionAttributeNames={
                "#src": "Source",
                "#ts": "Timestamp"
            },
            ExpressionAttributeValues={
                ":src": {"S": "cloudtrail"},
                ":start": {"S": start},
                ":end": {"S": end}
            },
            ScanIndexForward=False,
            Limit=50
        )
        items = response.get("Items", [])
        print(f"GSI returned {len(items)} items")
        return items
    except Exception as e:
        print(f"GSI query failed: {e}, falling back to scan")
        response = ddb.scan(TableName=DDB_TABLE, Limit=50)
        all_items = response.get("Items", [])
        filtered = [
            item for item in all_items
            if start <= item.get("Timestamp", {}).get("S", "") <= end
        ]
        print(f"Scan fallback returned {len(filtered)} items")
        return filtered


def build_prompt(user_query: str, context_text: str) -> str:
    system = """You are a senior cloud security analyst reviewing AWS CloudTrail security events.

Here is an example of the exact output format I want:

---
EVENT: CreateUser - User: unknown - IP: 203.0.113.42
WHAT HAPPENED: A new IAM user was created from an unrecognized external IP address.
SEVERITY: High
ASSESSMENT: Suspicious. IAM user creation from an unknown IP could indicate unauthorized access or a compromised account.
REMEDIATION:
- Verify immediately whether this user creation was authorized by your team
- If unauthorized: disable the user with `aws iam update-login-profile --user-name <name> --no-password-reset-required` and delete any access keys with `aws iam delete-access-key`
- Investigate all other CloudTrail activity from IP 203.0.113.42
- Enable MFA enforcement for all IAM users via IAM policy
- Review and tighten IAM password policy
---

Now analyze the following real security events using that exact format. For each event provide WHAT HAPPENED, SEVERITY, ASSESSMENT, and REMEDIATION. If multiple events are present analyze each one separately. Plain text only, no markdown headers, no multiple choice."""

    user_message = f"User question: {user_query}\n\nSecurity Events:\n{context_text}"

    return (
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        f"{system}<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
        f"{user_message}<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
    )


def handler(event, context):
    body = json.loads(event.get("body") or "{}")
    user_query = body.get("query", "").strip()

    if not user_query:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Missing query parameter"})
        }

    # Get time range from query
    start, end = get_time_range(user_query)
    logs = query_events(start, end)

    # No events found
    if not logs:
        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            },
            "body": json.dumps({
                "query": user_query,
                "response": f"No security events found between {start} and {end}."
            })
        }

    # Build context for LLM
    context_lines = []
    for item in logs:
        error = item.get("ErrorCode", {}).get("S", "n/a")
        line = (
            f"{item.get('Timestamp', {}).get('S', '')} - "
            f"{item.get('EventName', {}).get('S', '')} - "
            f"User: {item.get('User', {}).get('S', '')} - "
            f"IP: {item.get('SourceIP', {}).get('S', '')}"
        )
        if error and error != "n/a":
            line += f" - Error: {error}"
        context_lines.append(line)

    context_text = "\n".join(context_lines)

    if len(context_text) > 3000:
        context_text = context_text[:3000]

    # No context after building
    if not context_text.strip():
        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            },
            "body": json.dumps({
                "query": user_query,
                "response": f"No security events found between {start} and {end}."
            })
        }

    # Build prompt with remediation instructions
    prompt = build_prompt(user_query, context_text)
    ai_response = analyze_with_llama(prompt)

    # Handle empty LLM response - fall back to raw logs
    if not ai_response or not ai_response.strip():
        ai_response = (
            f"Found {len(logs)} security event(s) between {start} and {end}. "
            f"AI analysis unavailable at this time.\n\n{context_text}"
        )

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps({"query": user_query, "response": ai_response})
    }