/** Read sealed YAML with its producer's scalar rules, as the Rust replay does. */
import { execFileSync } from "node:child_process";

export function readStagePayload(path: string): unknown {
  const json = execFileSync(
    "ruby",
    [
      "--disable-gems", "-rjson", "-ryaml", "-e",
      "puts JSON.generate(YAML.safe_load_file(ARGV.fetch(0), aliases: false))",
      "--", path,
    ],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] },
  );
  return JSON.parse(json);
}
