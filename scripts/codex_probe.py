#!/usr/bin/env python3
"""
codex app-server 协议探针。

目的：不用装机、不用等 15 分钟的 iOS 构建，就能验证"我们代码里发的那几个 JSON-RPC 请求
是否被官方 codex 接受"。跑在 ubuntu runner 上，用的是和随包内置运行时同一个 tag 的官方 CLI，
协议与平台无关。

只做三件事（都不需要登录、不调用模型）：
  1) initialize            —— clientInfo + capabilities.experimentalApi（dynamicTools 的授权前提）
  2) thread/start          —— cwd + dynamicTools[...] + baseInstructions/developerInstructions
  3) turn/start            —— threadId + input:[{type:text,text,text_elements:[]}]

判定：
  · 参数类错误（-32600 / -32602 / unknown field / experimentalApi 等）=> FAIL
  · 业务类错误（未登录 401、模型不可用等）=> 协议层 PASS（说明参数被接受了）
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

BIN = os.environ.get("CODEX_BIN", "./codex")
CODEX_HOME = tempfile.mkdtemp(prefix="codexprobe-")

DYNAMIC_TOOL = {
    "type": "function",
    "name": "device_info",
    "description": "probe fixture tool",
    "inputSchema": {
        "type": "object",
        "properties": {"verbose": {"type": "boolean", "description": "more detail"}},
    },
}

failures = []
notes = []


def say(msg):
    print(msg, flush=True)


def record_fail(msg):
    failures.append(msg)
    say("FAIL  " + msg)


def record_pass(msg):
    say("PASS  " + msg)


class Server:
    def __init__(self, binary):
        self.lines = []
        self.lock = threading.Lock()
        env = dict(os.environ)
        env["CODEX_HOME"] = CODEX_HOME
        env.setdefault("RUST_LOG", "warn")
        self.proc = subprocess.Popen(
            [binary, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        threading.Thread(target=self._read, daemon=True).start()
        self.next_id = 0

    def _read(self):
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            if not line:
                continue
            with self.lock:
                self.lines.append(line)

    def dump_notifications(self, label):
        """把非响应行（通知/服务端请求）原样打出来——用于观察 error 的真实结构"""
        with self.lock:
            snapshot = list(self.lines)
        interesting = []
        for line in snapshot:
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if isinstance(msg, dict) and "id" not in msg:
                interesting.append(msg)
        if not interesting:
            return
        say("      [%s] 收到通知 %d 条（最多显示 5 条原始 JSON）:" % (label, len(interesting)))
        for msg in interesting[:5]:
            text = json.dumps(msg, ensure_ascii=False)
            say("        " + (text[:600] + ("…" if len(text) > 600 else "")))

    def _take(self, rid):
        with self.lock:
            for i, line in enumerate(self.lines):
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                if isinstance(msg, dict) and msg.get("id") == rid and (
                    "result" in msg or "error" in msg
                ):
                    del self.lines[i]
                    return msg
        return None

    def request(self, method, params=None, timeout=40):
        self.next_id += 1
        rid = self.next_id
        payload = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        try:
            self.proc.stdin.write(json.dumps(payload) + "\n")
            self.proc.stdin.flush()
        except Exception as exc:  # 进程已退出
            return {"error": {"code": "io", "message": str(exc)}}
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self._take(rid)
            if msg is not None:
                return msg
            if self.proc.poll() is not None:
                return {"error": {"code": "exited", "message": "server exited"}}
            time.sleep(0.05)
        return {"error": {"code": "timeout", "message": "no response in %ss" % timeout}}

    def notify(self, method, params=None):
        try:
            self.proc.stdin.write(
                json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}}) + "\n"
            )
            self.proc.stdin.flush()
        except Exception:
            pass

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


def is_param_error(err):
    if not isinstance(err, dict):
        return False
    code = err.get("code")
    msg = str(err.get("message", "")).lower()
    if code in (-32600, -32602):
        return True
    for needle in ("unknown field", "invalid value", "invalid type", "missing field",
                   "experimentalapi", "expected", "unexpected", "requires"):
        if needle in msg:
            return True
    return False


def detail(msg):
    if "error" in msg:
        err = msg["error"]
        return "error %s: %s" % (err.get("code"), err.get("message"))
    return "result keys: " + ",".join(sorted((msg.get("result") or {}).keys()))


def main():
    if not os.path.exists(BIN):
        say("找不到可执行文件: %s" % BIN)
        return 2
    try:
        ver = subprocess.run([BIN, "--version"], capture_output=True, text=True, timeout=60)
        say("codex: " + (ver.stdout or ver.stderr).strip())
    except Exception as exc:
        say("版本读取失败: %s" % exc)

    srv = Server(BIN)
    try:
        # 1) initialize
        init = srv.request(
            "initialize",
            {
                "clientInfo": {"name": "trollcodex", "title": "TrollCodex", "version": "probe"},
                "capabilities": {"experimentalApi": True, "requestAttestation": False},
            },
        )
        if "error" in init:
            record_fail("initialize → " + detail(init))
        else:
            record_pass("initialize 接受 clientInfo + capabilities.experimentalApi")
            ua = (init.get("result") or {}).get("userAgent")
            if ua:
                say("      userAgent: " + str(ua))
        srv.notify("initialized", {})

        # 2) thread/start（含 dynamicTools —— 就是之前 -32600 的那一步）
        started = srv.request(
            "thread/start",
            {
                "cwd": CODEX_HOME,
                "dynamicTools": [DYNAMIC_TOOL],
                "baseInstructions": "probe instructions",
                "developerInstructions": "probe developer instructions",
            },
        )
        thread_id = None
        if "error" in started:
            record_fail("thread/start(dynamicTools) → " + detail(started))
        else:
            result = started.get("result") or {}
            thread = result.get("thread") or {}
            thread_id = thread.get("id") or result.get("threadId")
            if thread_id:
                record_pass("thread/start 接受 dynamicTools（threadId=%s…）" % str(thread_id)[:8])
            else:
                record_fail("thread/start 无 thread id，返回: " + json.dumps(result)[:300])

        # 3) turn/start（参数形状校验；无登录时预期是业务错误）
        if thread_id:
            turn = srv.request(
                "turn/start",
                {
                    "threadId": thread_id,
                    "input": [{"type": "text", "text": "probe", "text_elements": []}],
                },
            )
            if "error" in turn:
                if is_param_error(turn["error"]):
                    record_fail("turn/start → " + detail(turn))
                else:
                    record_pass("turn/start 参数被接受（业务错误属预期：%s）"
                                % str(turn["error"].get("message", ""))[:120])
            else:
                record_pass("turn/start 接受 text + text_elements")
            # 关键：把 turn 期间的 error 通知原样打出来，App 里那条 -7 就是它
            time.sleep(3)
            srv.dump_notifications("turn/start 之后")

        say("")
        if failures:
            say("结论：协议不匹配 %d 处" % len(failures))
            for f in failures:
                say("  - " + f)
            return 1
        say("结论：协议层全部通过（initialize / thread/start(dynamicTools) / turn/start）")
        return 0
    finally:
        srv.close()


if __name__ == "__main__":
    sys.exit(main())
