import type { QueueTier } from "@/types/playerContext";

/** A queue contains occurrences: neither React nor drag-and-drop may key by song alone. */
export function queueRowID(
  tier: QueueTier,
  index: number,
  songId: string,
): string {
  return JSON.stringify([tier, index, songId]);
}
