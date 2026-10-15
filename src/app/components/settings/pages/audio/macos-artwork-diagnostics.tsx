import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import {
  isMacArtworkAvailable,
  type MacArtworkDiagnostics,
  macArtworkCommand,
} from "@/native/artwork/tauri";

export function MacArtworkDiagnostics() {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const available = isMacArtworkAvailable();
  const query = useQuery({
    queryKey: ["macos-artwork-diagnostics"],
    queryFn: () => macArtworkCommand<MacArtworkDiagnostics>("diagnostics"),
    enabled: available && open,
    refetchInterval: available && open ? 2000 : false,
    retry: false,
  });
  if (!available) return null;
  return (
    <details onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary className="cursor-pointer text-sm">
        {t("settings.audio.lockScreenArtwork.diagnostics")}
      </summary>
      {query.isError && (
        <p className="text-xs text-destructive">{query.error.message}</p>
      )}
      {query.data && (
        <div className="mt-2 space-y-2 text-xs text-muted-foreground">
          <p>
            {query.data.source} · revision {query.data.revision} · leases{" "}
            {query.data.leases}
          </p>
          <p>{query.data.renderer}</p>
          {query.data.depthPreview && (
            <img
              src={query.data.depthPreview}
              alt={t("settings.audio.lockScreenArtwork.depthPreview")}
              className="max-h-48 rounded"
            />
          )}
          {[
            ...Object.entries(query.data.variants),
            ...Object.entries(query.data.phases),
          ].map(([name, fields]) => (
            <div key={name} className="rounded border p-2">
              <p className="font-medium text-foreground">{name}</p>
              {Object.entries(fields).map(([key, value]) => (
                <p key={key} className="break-all">
                  {key}: {value}
                </p>
              ))}
            </div>
          ))}
        </div>
      )}
    </details>
  );
}
