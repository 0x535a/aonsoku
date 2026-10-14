import { HapticFeedbackSettings } from "./haptic-feedback";
import { HistorySettings } from "./history";
import { LockScreenArtworkSettings } from "./lock-screen-artwork";
import { LyricsSettings } from "./lyrics";
import { PipSettings } from "./pip-settings";
import { ReplayGainConfig } from "./replay-gain";

export function Audio() {
  return (
    <div className="space-y-4">
      <HapticFeedbackSettings />
      <PipSettings />
      <LockScreenArtworkSettings />
      <ReplayGainConfig />
      <LyricsSettings />
      <HistorySettings />
    </div>
  );
}
