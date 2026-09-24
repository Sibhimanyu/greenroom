#!/bin/bash
# usage: mcp.sh METHOD PARAMS_JSON
# Talks to the Illustrator MCP server. The token is never stored here: export ILLUSTRATOR_MCP_TOKEN first.
: "${ILLUSTRATOR_MCP_TOKEN:?set ILLUSTRATOR_MCP_TOKEN to the illustrator MCP bearer token}"
URL=${ILLUSTRATOR_MCP_URL:-http://localhost:18412/v1/mcp}
H=(-H "Authorization: Bearer $ILLUSTRATOR_MCP_TOKEN" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
SID=$(curl -s -D - -o /dev/null -X POST $URL "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cc","version":"1"}}}' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
curl -s -X POST $URL "${H[@]}" -H "Mcp-Session-Id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
curl -s -X POST $URL "${H[@]}" -H "Mcp-Session-Id: $SID" --max-time 600 -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$1\",\"params\":$2}"
