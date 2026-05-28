#!/bin/bash
curl -X POST https://68pv702j3h.execute-api.us-east-1.amazonaws.com/dev/analyze \
  -H "Content-Type: application/json" \
  -d '{"query": "what happened in the last 30 days?"}'
