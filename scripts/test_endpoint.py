#!/usr/bin/env python3
"""
Test the Gemma 4 inference endpoint with streaming output.
Usage: python scripts/test_endpoint.py <api_url> <api_key> [prompt]
"""

import sys
import json
import time
import urllib.request
import urllib.error

def test_endpoint(api_url, api_key, prompt):
    url = f"{api_url}/generate_stream"

    payload = json.dumps({
        "inputs": prompt,
        "parameters": {
            "max_new_tokens": 256,
            "temperature": 0.7,
            "top_p": 0.9
        }
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key
    }

    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    print(f"API URL:  {url}")
    print(f"Prompt:   {prompt}")
    print(f"")
    print("Response:")
    print("-" * 40)

    start_time = time.time()
    token_count = 0
    full_text = ""

    try:
        with urllib.request.urlopen(req, timeout=300) as response:
            for line_bytes in response:
                line = line_bytes.decode("utf-8").strip()

                if not line.startswith("data:"):
                    continue

                data = line[5:].strip()
                if data == "[DONE]":
                    break

                try:
                    parsed = json.loads(data)
                    if "token" in parsed and "text" in parsed["token"]:
                        token_text = parsed["token"]["text"]
                        full_text += token_text
                        token_count += 1
                        print(token_text, end="", flush=True)
                except json.JSONDecodeError:
                    pass

    except urllib.error.HTTPError as e:
        if e.code == 401:
            print("ERROR: Invalid API key (401)")
        elif e.code == 503:
            print("ERROR: Service is starting up (503). Wait 3-5 minutes and retry.")
        else:
            print(f"ERROR: HTTP {e.code} — {e.reason}")
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"ERROR: Cannot reach the API — {e.reason}")
        print("The service may be starting up. Wait 3-5 minutes and retry.")
        sys.exit(1)

    elapsed = time.time() - start_time

    print("")
    print("-" * 40)
    print(f"Tokens:    {token_count}")
    print(f"Time:      {elapsed:.1f}s")
    if elapsed > 0 and token_count > 0:
        print(f"Speed:     {token_count / elapsed:.1f} tokens/sec")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python scripts/test_endpoint.py <api_url> <api_key> [prompt]")
        print('Example: python scripts/test_endpoint.py http://gemma4-alb-123.elb.amazonaws.com sk-gemma4-abc "What is cloud computing?"')
        sys.exit(1)

    api_url = sys.argv[1]
    api_key = sys.argv[2]
    prompt = sys.argv[3] if len(sys.argv) > 3 else "What is cloud computing? Explain in 3 sentences."

    test_endpoint(api_url, api_key, prompt)