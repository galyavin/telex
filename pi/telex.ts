// telex for Pi: when this session is idle and its telex name has unread mail, send it the notice.
// `telex install` copies this file into ~/.pi/agent/extensions/. See README.md.
import { execFile } from "node:child_process";
import { statSync } from "node:fs";
import { homedir } from "node:os";

const dir = process.env.TELEX_DIR || `${homedir()}/.telex`;
const size = () => { try { return statSync(`${dir}/telex.jsonl`).size; } catch { return -1; } };   // by path: reads replace the file

export default function (pi: any) {
  let timer: ReturnType<typeof setInterval> | undefined;
  pi.on("session_start", (_event: any, ctx: any) => {         // Pi rebuilds extensions on /new, /resume and fork
    if (!ctx.hasUI) return;                                   // print and JSON runs are left alone
    const session = `pi:${ctx.sessionManager.getSessionId()}`;
    let seen = -1, asking = false;
    timer = setInterval(() => {
      try {
        const now = size();
        if (ctx.isIdle() && !asking && now !== seen) {       // only when the room changed: an aborted turn does not re-ring
          asking = true;
          execFile(`${dir}/telex`, ["_bell", session], (_err, out) => {
            asking = false;
            const notice = out.trim();
            try {                                             // mark the room seen only once it is handled:
              if (!notice) seen = now;                        // nothing for this session
              else if (ctx.isIdle()) { pi.sendUserMessage(notice); seen = now; }   // rung; busy or a failed send retries next tick
            } catch {}
          });
        }
      } catch {}
    }, 1000);
    timer.unref?.();                                          // never keeps Pi running
  });
  pi.on("session_shutdown", () => clearInterval(timer));
}
