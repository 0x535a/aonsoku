import { getRuntime } from "@/utils/capabilities";
import { isMacOS } from "@/utils/desktop";
import { getTauriInvoke } from "@/utils/tauri";
import type { DynamicCoverProvider } from "./types";

export function isMacArtworkAvailable(): boolean {
  return getRuntime() === "tauri" && isMacOS && getTauriInvoke() !== null;
}

export async function macArtworkCommand<T>(
  operation: string,
  payload: object = {},
): Promise<T> {
  if (!isMacArtworkAvailable())
    throw new Error("macOS artwork requires the Tauri native host.");
  const invoke = getTauriInvoke();
  if (!invoke) throw new Error("macOS artwork bridge is unavailable.");
  return invoke<T>("dynamic_cover_command", { operation, payload });
}

export const tauriDynamicCover: DynamicCoverProvider = {
  getCapabilities: () => macArtworkCommand("capabilities"),
  acquire: (request) => macArtworkCommand("acquire", request),
  release: (leaseId) => macArtworkCommand("release", { leaseId }),
};

export interface MacArtworkDiagnostics {
  source: string;
  revision: number;
  renderer: string;
  leases: number;
  depthPreview?: string;
  variants: Record<string, Record<string, string>>;
  phases: Record<string, Record<string, string>>;
}
