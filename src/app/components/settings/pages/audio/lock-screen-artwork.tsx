import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import {
  Content,
  ContentItem,
  ContentItemForm,
  ContentItemTitle,
  ContentSeparator,
  Header,
  HeaderDescription,
  HeaderTitle,
  Root,
} from "@/app/components/settings/section";
import { Button } from "@/app/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/app/components/ui/select";
import { Switch } from "@/app/components/ui/switch";
import {
  type ArtworkOptions,
  type ArtworkTier,
  isLockScreenArtworkAvailable,
  lockScreenArtwork,
} from "@/native/audio/lock-screen-artwork";
import { formatBytes } from "@/utils/formatBytes";

const queryKey = ["ios-lock-screen-artwork"];
const activeStatuses = new Set([
  "queued",
  "downloading",
  "compiling",
  "waitingForWifi",
  "waitingForResources",
]);
const tierLabels = { fp16: "FP16", p8: "P8", p6: "P6" };

export function LockScreenArtworkSettings() {
  const { t } = useTranslation();
  const client = useQueryClient();
  const available = isLockScreenArtworkAvailable();
  const query = useQuery({
    queryKey,
    queryFn: lockScreenArtwork.getState,
    enabled: available,
    retry: false,
    refetchInterval: (query) =>
      query.state.data?.models.some((model) => activeStatuses.has(model.status))
        ? 1000
        : 5000,
  });
  const reportError = (error: Error) => toast.error(error.message);
  const configure = useMutation({
    mutationFn: (options: Partial<ArtworkOptions>) =>
      lockScreenArtwork.configure(options),
    onSuccess: (state) => client.setQueryData(queryKey, state),
    onError: reportError,
  });
  const action = useMutation({
    mutationFn: ({
      tier,
      command,
    }: {
      tier: ArtworkTier;
      command: "download" | "cancel" | "remove";
    }) => lockScreenArtwork[command](tier),
    onSuccess: () => client.invalidateQueries({ queryKey }),
    onError: reportError,
  });
  if (!available) return null;
  const state = query.data;
  const prefix = "settings.audio.lockScreenArtwork";
  const disabled = !state?.supported || configure.isPending;

  return (
    <Root>
      <Header>
        <HeaderTitle>{t(`${prefix}.group`)}</HeaderTitle>
        <HeaderDescription>{t(`${prefix}.description`)}</HeaderDescription>
      </Header>
      {query.isPending && (
        <p className="text-xs text-muted-foreground">
          {t(`${prefix}.loading`)}
        </p>
      )}
      {query.isError && (
        <div className="flex items-center justify-between gap-3">
          <p className="text-xs text-destructive">
            {t(`${prefix}.unavailable`)}
          </p>
          <Button size="sm" variant="outline" onClick={() => query.refetch()}>
            {t(`${prefix}.retry`)}
          </Button>
        </div>
      )}
      {state && (
        <Content>
          {!state.supported && (
            <p className="text-xs text-muted-foreground">
              {t(`${prefix}.unsupported`)}
            </p>
          )}
          <ContentItem>
            <ContentItemTitle info={t(`${prefix}.immersiveInfo`)}>
              {t(`${prefix}.immersive`)}
            </ContentItemTitle>
            <ContentItemForm>
              <Switch
                aria-label={t(`${prefix}.immersive`)}
                checked={state.options.immersiveEnabled}
                disabled={disabled}
                onCheckedChange={(immersiveEnabled) =>
                  configure.mutate({ immersiveEnabled })
                }
              />
            </ContentItemForm>
          </ContentItem>
          <ContentItem>
            <ContentItemTitle info={t(`${prefix}.dynamicInfo`)}>
              {t(`${prefix}.dynamic`)}
            </ContentItemTitle>
            <ContentItemForm>
              <Switch
                aria-label={t(`${prefix}.dynamic`)}
                checked={state.options.dynamicEnabled}
                disabled={disabled || !state.options.immersiveEnabled}
                onCheckedChange={(dynamicEnabled) =>
                  configure.mutate({ dynamicEnabled })
                }
              />
            </ContentItemForm>
          </ContentItem>
          <ContentItem>
            <ContentItemTitle info={t(`${prefix}.qualityInfo`)}>
              {t(`${prefix}.quality`)}
            </ContentItemTitle>
            <ContentItemForm>
              <Select
                value={state.options.quality}
                disabled={disabled}
                onValueChange={(quality) =>
                  configure.mutate({
                    quality: quality as ArtworkOptions["quality"],
                  })
                }
              >
                <SelectTrigger
                  className="h-8"
                  aria-label={t(`${prefix}.quality`)}
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="auto">
                    {t(`${prefix}.automatic`, {
                      tier: tierLabels[state.recommendedTier],
                    })}
                  </SelectItem>
                  {(["fp16", "p8", "p6"] as const).map((tier) => (
                    <SelectItem key={tier} value={tier}>
                      {tierLabels[tier]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </ContentItemForm>
          </ContentItem>
          <ContentItem>
            <ContentItemTitle info={t(`${prefix}.wifiInfo`)}>
              {t(`${prefix}.wifiOnly`)}
            </ContentItemTitle>
            <ContentItemForm>
              <Switch
                aria-label={t(`${prefix}.wifiOnly`)}
                checked={state.options.wifiOnly}
                disabled={disabled}
                onCheckedChange={(wifiOnly) => configure.mutate({ wifiOnly })}
              />
            </ContentItemForm>
          </ContentItem>
          <p className="text-xs text-muted-foreground" aria-live="polite">
            {t(`${prefix}.generation.${state.generationStatus}`)}
            {state.effectiveTier &&
              state.options.dynamicEnabled &&
              ` · ${t(`${prefix}.effectiveTier`, { tier: tierLabels[state.effectiveTier] })}`}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(`${prefix}.modelsInfo`)}
          </p>
          {state.models.map((model) => (
            <ContentItem key={model.tier}>
              <ContentItemTitle
                info={`${t(`${prefix}.model.${model.status}`)}${model.status === "downloading" ? ` ${Math.round(model.progress * 100)}%` : ""} · ${formatBytes(model.status === "ready" ? model.storedBytes : model.downloadBytes)}${model.error ? ` · ${model.error}` : ""}`}
              >
                Depth Anything V2 Small {tierLabels[model.tier]}
              </ContentItemTitle>
              <ContentItemForm>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={
                    action.isPending ||
                    (!state.supported && model.status !== "ready")
                  }
                  onClick={() =>
                    action.mutate({
                      tier: model.tier,
                      command: activeStatuses.has(model.status)
                        ? "cancel"
                        : model.status === "ready"
                          ? "remove"
                          : "download",
                    })
                  }
                >
                  {t(
                    `${prefix}.${activeStatuses.has(model.status) ? "cancel" : model.status === "ready" ? "remove" : "download"}`,
                  )}
                </Button>
              </ContentItemForm>
            </ContentItem>
          ))}
          <p className="text-xs text-muted-foreground">
            {t(`${prefix}.license`)}
          </p>
        </Content>
      )}
      <ContentSeparator />
    </Root>
  );
}
