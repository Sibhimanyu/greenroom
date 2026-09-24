import json, subprocess, sys, time
def call(name, args, tries=10):
    for attempt in range(tries):
        r = subprocess.run(["./mcp.sh", "tools/call", json.dumps({"name": name, "arguments": args})], capture_output=True, text=True)
        j = json.loads(r.stdout)
        if "error" in j and "Rate limit" in j["error"].get("message", ""):
            time.sleep(3 * (attempt + 1)); continue
        if "error" in j:
            raise RuntimeError(f"{name}: {j['error']}")
        txt = j["result"]["content"][0]["text"]
        if j["result"].get("isError"): print("ERR", name, txt[:400])
        return txt
    raise RuntimeError(f"{name}: still rate limited")
if __name__ == "__main__":
    print(call(sys.argv[1], json.loads(sys.argv[2]))[:int(sys.argv[3]) if len(sys.argv) > 3 else 3000])
