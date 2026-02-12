#!/usr/bin/env python3
"""Bedrock converse-stream helper — outputs one JSON event per line to stdout.

Usage: bedrock_stream.py --model MODEL --region REGION --max-tokens N --prompt "text"

Requires boto3. Auto-bootstraps a venv in /tmp/sre-boto3-venv if needed.
"""
import argparse, json, sys

try:
    import boto3
except ImportError:
    print(json.dumps({"error": "boto3 not available"}), flush=True)
    sys.exit(1)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--region", required=True)
    p.add_argument("--max-tokens", type=int, required=True)
    p.add_argument("--prompt", required=True)
    args = p.parse_args()

    client = boto3.client("bedrock-runtime", region_name=args.region)
    resp = client.converse_stream(
        modelId=args.model,
        messages=[{"role": "user", "content": [{"text": args.prompt}]}],
        inferenceConfig={"maxTokens": args.max_tokens},
    )
    for event in resp["stream"]:
        print(json.dumps(event, default=str), flush=True)

if __name__ == "__main__":
    main()
