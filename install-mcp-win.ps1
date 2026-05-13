$base = "D:\findrik\MCPserver\mcp-windows"

$paths = @(
    "$base",
    "$base\src",
    "$base\src\tools",
    "$base\src\services"
)

foreach ($p in $paths) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p | Out-Null
    }
}

function Write-File1250 {
    param(
        [string]$Path,
        [string]$Content
    )
    $bytes = [System.Text.Encoding]::GetEncoding(1250).GetBytes($Content)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

# server.json (volitelne, pre tooling)
Write-File1250 "$base\server.json" @'
{
  "name": "mcp-windows",
  "version": "1.0.0",
  "tools": {
    "windows.getProcesses": {
      "description": "List running processes",
      "input_schema": { "type": "object", "properties": {} }
    },
    "windows.getEventLog": {
      "description": "Read Windows Event Log",
      "input_schema": {
        "type": "object",
        "properties": {
          "logName": { "type": "string" },
          "lastMinutes": { "type": "number" }
        },
        "required": ["logName"]
      }
    },
    "windows.getServices": {
      "description": "List Windows services",
      "input_schema": { "type": "object", "properties": {} }
    },
    "windows.restartService": {
      "description": "Restart a Windows service",
      "input_schema": {
        "type": "object",
        "properties": {
          "name": { "type": "string" }
        },
        "required": ["name"]
      }
    },
    "windows.runScript": {
      "description": "Run a PowerShell script with arguments",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "args": { "type": "string" }
        },
        "required": ["path"]
      }
    }
  }
}
'@

# package.json
Write-File1250 "$base\package.json" @'
{
  "name": "mcp-windows",
  "version": "1.0.0",
  "type": "module",
  "main": "src/index.mjs",
  "dependencies": {}
}
'@

# .env (placeholder)
Write-File1250 "$base\.env" @'
# reserved for future use
'@

# src/services/powershell.mjs
Write-File1250 "$base\src\services\powershell.mjs" @'
import { spawn } from "child_process";

export async function runPS(command) {
  return new Promise((resolve) => {
    const ps = spawn("powershell.exe", [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-Command",
      command
    ], { windowsHide: true });

    let stdout = "";
    let stderr = "";

    ps.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    ps.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    ps.on("close", (code) => {
      if (code !== 0) {
        resolve({ error: true, code, stderr: stderr.trim() });
      } else {
        resolve({ error: false, stdout: stdout.trim() });
      }
    });
  });
}
'@

# src/tools/getProcesses.mjs
Write-File1250 "$base\src\tools\getProcesses.mjs" @'
import { runPS } from "../services/powershell.mjs";

export const getProcessesTool = {
  name: "windows.getProcesses",
  description: "List running processes",
  inputSchema: {
    type: "object",
    properties: {}
  },
  async call(_args = {}) {
    const cmd = "Get-Process | Select-Object Name,Id,CPU | ConvertTo-Json";
    const result = await runPS(cmd);

    if (result.error) {
      return { error: "powershell_error", detail: result.stderr };
    }

    try {
      return JSON.parse(result.stdout || "[]");
    } catch {
      return { error: "json_parse_error", raw: result.stdout };
    }
  }
};
'@

# src/tools/getEventLog.mjs
Write-File1250 "$base\src\tools\getEventLog.mjs" @'
import { runPS } from "../services/powershell.mjs";

const allowedLogs = ["System", "Application", "Security"];

export const getEventLogTool = {
  name: "windows.getEventLog",
  description: "Read Windows Event Log",
  inputSchema: {
    type: "object",
    properties: {
      logName: { type: "string" },
      lastMinutes: { type: "number" }
    },
    required: ["logName"]
  },
  async call(args = {}) {
    let { logName, lastMinutes = 60 } = args;

    if (!logName || typeof logName !== "string") {
      return { error: "invalid_input", message: "logName is required" };
    }

    if (!allowedLogs.includes(logName)) {
      return { error: "invalid_log", message: "logName not allowed" };
    }

    if (typeof lastMinutes !== "number" || lastMinutes <= 0 || lastMinutes > 1440) {
      lastMinutes = 60;
    }

    const cmd = `
      Get-WinEvent -LogName "${logName}" -MaxEvents 200 |
      Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-${lastMinutes}) } |
      Select-Object TimeCreated, Id, LevelDisplayName, Message |
      ConvertTo-Json -Depth 4
    `;

    const result = await runPS(cmd);

    if (result.error) {
      return { error: "powershell_error", detail: result.stderr };
    }

    try {
      return JSON.parse(result.stdout || "[]");
    } catch {
      return { error: "json_parse_error", raw: result.stdout };
    }
  }
};
'@

# src/tools/getServices.mjs
Write-File1250 "$base\src\tools\getServices.mjs" @'
import { runPS } from "../services/powershell.mjs";

export const getServicesTool = {
  name: "windows.getServices",
  description: "List Windows services",
  inputSchema: {
    type: "object",
    properties: {}
  },
  async call(_args = {}) {
    const cmd = "Get-Service | Select-Object Name,Status,DisplayName | ConvertTo-Json";
    const result = await runPS(cmd);

    if (result.error) {
      return { error: "powershell_error", detail: result.stderr };
    }

    try {
      return JSON.parse(result.stdout || "[]");
    } catch {
      return { error: "json_parse_error", raw: result.stdout };
    }
  }
};
'@

# src/tools/restartService.mjs
Write-File1250 "$base\src\tools\restartService.mjs" @'
import { runPS } from "../services/powershell.mjs";

export const restartServiceTool = {
  name: "windows.restartService",
  description: "Restart a Windows service",
  inputSchema: {
    type: "object",
    properties: {
      name: { type: "string" }
    },
    required: ["name"]
  },
  async call(args = {}) {
    const { name } = args;

    if (!name || typeof name !== "string") {
      return { error: "invalid_input", message: "name is required" };
    }

    const safeName = name.replace(/[^a-zA-Z0-9_\-\.]/g, "");
    if (!safeName) {
      return { error: "invalid_input", message: "name sanitized to empty" };
    }

    const cmd = `
      try {
        Restart-Service -Name "${safeName}" -Force -ErrorAction Stop;
        "Service restarted"
      } catch {
        $_ | Out-String
      }
    `;

    const result = await runPS(cmd);

    if (result.error) {
      return { error: "powershell_error", detail: result.stderr };
    }

    return { result: result.stdout };
  }
};
'@

# src/tools/runScript.mjs
Write-File1250 "$base\src\tools\runScript.mjs" @'
import { runPS } from "../services/powershell.mjs";
import path from "path";

const allowedRoot = "D:\\findrik\\scripts";

export const runScriptTool = {
  name: "windows.runScript",
  description: "Run a PowerShell script with arguments",
  inputSchema: {
    type: "object",
    properties: {
      path: { type: "string" },
      args: { type: "string" }
    },
    required: ["path"]
  },
  async call(args = {}) {
    let { path: scriptPath, args: scriptArgs = "" } = args;

    if (!scriptPath || typeof scriptPath !== "string") {
      return { error: "invalid_input", message: "path is required" };
    }

    if (scriptPath.length > 260) {
      return { error: "invalid_input", message: "path too long" };
    }

    const normalized = path.win32.resolve(scriptPath);
    const root = path.win32.resolve(allowedRoot);

    if (!normalized.toLowerCase().startsWith(root.toLowerCase())) {
      return { error: "invalid_input", message: "path outside allowed root" };
    }

    if (typeof scriptArgs !== "string") {
      scriptArgs = "";
    }

    if (/[;&|]/.test(scriptArgs)) {
      return { error: "invalid_input", message: "args contain forbidden characters" };
    }

    const cmd = `& "${normalized}" ${scriptArgs} | ConvertTo-Json -Depth 5`;

    const result = await runPS(cmd);

    if (result.error) {
      return { error: "powershell_error", detail: result.stderr };
    }

    try {
      return JSON.parse(result.stdout || "null");
    } catch {
      return { error: "json_parse_error", raw: result.stdout };
    }
  }
};
'@

# src/index.mjs – MCP stdio JSON-RPC server
Write-File1250 "$base\src\index.mjs" @'
import readline from "readline";

import { getProcessesTool } from "./tools/getProcesses.mjs";
import { getEventLogTool } from "./tools/getEventLog.mjs";
import { getServicesTool } from "./tools/getServices.mjs";
import { restartServiceTool } from "./tools/restartService.mjs";
import { runScriptTool } from "./tools/runScript.mjs";

const tools = [
  getProcessesTool,
  getEventLogTool,
  getServicesTool,
  restartServiceTool,
  runScriptTool
];

const toolMap = {};
for (const t of tools) {
  toolMap[t.name] = t;
}

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

function sendResponse(obj) {
  try {
    const line = JSON.stringify(obj);
    process.stdout.write(line + "\n");
  } catch {
    // ignore
  }
}

rl.on("line", async (line) => {
  let msg;

  try {
    msg = JSON.parse(line);
  } catch {
    sendResponse({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: "Parse error" }
    });
    return;
  }

  const { id, method, params } = msg;

  // Notifications (no id) must be ignored
  if (!("id" in msg)) {
    return;
  }

  if (method === "initialize") {
    sendResponse({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: "2024-11-05",
        serverInfo: {
          name: "mcp-windows",
          version: "1.0.0"
        },
        capabilities: {
          tools: {}
        }
      }
    });
    return;
  }

  if (method === "tools/list") {
    sendResponse({
      jsonrpc: "2.0",
      id,
      result: {
        tools: tools.map(t => ({
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema
        }))
      }
    });
    return;
  }

  if (method === "tools/call") {
    const { name, arguments: args } = params || {};

    if (!name || !toolMap[name]) {
      sendResponse({
        jsonrpc: "2.0",
        id,
        error: { code: -32601, message: "Tool not found" }
      });
      return;
    }

    try {
      const result = await toolMap[name].call(args || {});

      sendResponse({
        jsonrpc: "2.0",
        id,
        result: {
          content: [
            {
              type: "text",
              text: JSON.stringify(result, null, 2)
            }
          ]
        }
      });
    } catch (e) {
      sendResponse({
        jsonrpc: "2.0",
        id,
        error: { code: -32603, message: "Internal error", data: String(e) }
      });
    }
    return;
  }

  // Unknown method
  sendResponse({
    jsonrpc: "2.0",
    id,
    error: { code: -32601, message: "Method not found" }
  });
});
'@

Write-Host "MCP Windows stdio JSON-RPC server generated in $base"