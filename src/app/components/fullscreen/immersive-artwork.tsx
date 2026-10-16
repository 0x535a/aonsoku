import { App } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";
import { useReducedMotion } from "framer-motion";
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { type DynamicCoverHandle, dynamicCover } from "@/native/artwork";

const rank = { static: 0, camera: 1, depth: 2 };

/**
 * Mirror extension size ratio relative to the original album cover.
 * Adjust this value to manually control how much the mirrored edge extends outwards:
 * - 0.08 = 8% subtle extension
 * - 0.15 = 15% (recommended default: extends 15% mirrored border outwards,
 *               100% of the original cover remains pristine, fog only fades the mirror)
 * - 0.22 = 22% wide extension
 */
export const DYNAMIC_ARTWORK_MIRROR_RATIO = 0.15;

/**
 * Visual scale multiplier for the dynamic artwork presentation.
 * With the mirrored perimeter extending by default, 1.0 preserves the original
 * card size while the mirrored edges bloom outwards.
 */
export const DYNAMIC_ARTWORK_SCALE = 1.0;

/**
 * Generates an ultra-smooth Perlin Smootherstep (6t^5 - 15t^4 + 10t^3) fade mask
 * that keeps the central original artwork 100% opaque (0% fogged/clipped),
 * and smoothly dissolves ONLY the surrounding mirrored extension from 100% to 0%.
 */
function createMirrorEdgeMask(mirrorRatio: number) {
  // Relative width of the mirror border in the extended container:
  // e.g. for mirrorRatio = 0.15: extended size = 1 + 2 * 0.15 = 1.30
  // mirror border = 0.15 / 1.30 ≈ 11.538%
  const w = (mirrorRatio / (1 + 2 * mirrorRatio)) * 100;
  const leftSeam = w;
  const rightSeam = 100 - w;

  // Smootherstep samples for the fade band (zero 1st and 2nd derivatives at seams and outer edges)
  const stops = [
    { t: 0, alpha: 0 },
    { t: 0.1, alpha: 0.01 },
    { t: 0.2, alpha: 0.06 },
    { t: 0.35, alpha: 0.24 },
    { t: 0.5, alpha: 0.5 },
    { t: 0.65, alpha: 0.76 },
    { t: 0.8, alpha: 0.94 },
    { t: 0.9, alpha: 0.99 },
    { t: 1.0, alpha: 1.0 },
  ];

  const leftFade = stops
    .map(({ t, alpha }) => {
      const pos = (t * leftSeam).toFixed(2);
      return alpha === 0
        ? `transparent ${pos}%`
        : alpha === 1
          ? `black ${pos}%`
          : `rgba(0,0,0,${alpha}) ${pos}%`;
    })
    .join(", ");

  const rightFade = [...stops]
    .reverse()
    .map(({ t, alpha }) => {
      const pos = (rightSeam + (1 - t) * (100 - rightSeam)).toFixed(2);
      return alpha === 0
        ? `transparent ${pos}%`
        : alpha === 1
          ? `black ${pos}%`
          : `rgba(0,0,0,${alpha}) ${pos}%`;
    })
    .join(", ");

  const fadeString = `${leftFade}, black ${rightSeam.toFixed(2)}%, ${rightFade}`;
  const gradient = `linear-gradient(to right, ${fadeString}), linear-gradient(to bottom, ${fadeString})`;

  return {
    maskImage: gradient,
    WebkitMaskImage: gradient,
    maskComposite: "intersect" as const,
    WebkitMaskComposite: "source-in" as const,
  };
}

/**
 * Renders 8 directional mirrored reflection tiles surrounding the central artwork:
 * Top, Bottom, Left, Right edges and 4 Corners, matching the edge pixels 1:1.
 */
function MirroredPerimeter({
  halo,
  mirrorRatio,
}: {
  halo: ReactNode;
  mirrorRatio: number;
}) {
  const invM = (100 - mirrorRatio * 100).toFixed(2);

  return (
    <div
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 size-full select-none"
    >
      {/* 1. Top Edge */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(0% 0% ${invM}% 0%)`,
          WebkitClipPath: `inset(0% 0% ${invM}% 0%)`,
          transform: "scaleY(-1)",
          transformOrigin: "center top",
        }}
      >
        {halo}
      </div>

      {/* 2. Bottom Edge */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(${invM}% 0% 0% 0%)`,
          WebkitClipPath: `inset(${invM}% 0% 0% 0%)`,
          transform: "scaleY(-1)",
          transformOrigin: "center bottom",
        }}
      >
        {halo}
      </div>

      {/* 3. Left Edge */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(0% ${invM}% 0% 0%)`,
          WebkitClipPath: `inset(0% ${invM}% 0% 0%)`,
          transform: "scaleX(-1)",
          transformOrigin: "left center",
        }}
      >
        {halo}
      </div>

      {/* 4. Right Edge */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(0% 0% 0% ${invM}%)`,
          WebkitClipPath: `inset(0% 0% 0% ${invM}%)`,
          transform: "scaleX(-1)",
          transformOrigin: "right center",
        }}
      >
        {halo}
      </div>

      {/* 5. Top-Left Corner */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(0% ${invM}% ${invM}% 0%)`,
          WebkitClipPath: `inset(0% ${invM}% ${invM}% 0%)`,
          transform: "scale(-1, -1)",
          transformOrigin: "left top",
        }}
      >
        {halo}
      </div>

      {/* 6. Top-Right Corner */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(0% 0% ${invM}% ${invM}%)`,
          WebkitClipPath: `inset(0% 0% ${invM}% ${invM}%)`,
          transform: "scale(-1, -1)",
          transformOrigin: "right top",
        }}
      >
        {halo}
      </div>

      {/* 7. Bottom-Left Corner */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(${invM}% ${invM}% 0% 0%)`,
          WebkitClipPath: `inset(${invM}% ${invM}% 0% 0%)`,
          transform: "scale(-1, -1)",
          transformOrigin: "left bottom",
        }}
      >
        {halo}
      </div>

      {/* 8. Bottom-Right Corner */}
      <div
        className="pointer-events-none absolute inset-0 size-full select-none"
        style={{
          clipPath: `inset(${invM}% 0% 0% ${invM}%)`,
          WebkitClipPath: `inset(${invM}% 0% 0% ${invM}%)`,
          transform: "scale(-1, -1)",
          transformOrigin: "right bottom",
        }}
      >
        {halo}
      </div>
    </div>
  );
}

type Demand = Awaited<ReturnType<typeof dynamicCover.requestGeneration>>;

/** A square display mask over leased files. It never requests pixel dimensions. */
export function ImmersiveArtwork({
  coverArtId,
  active,
  playing,
  children,
  halo,
  scale = DYNAMIC_ARTWORK_SCALE,
  mirrorRatio = DYNAMIC_ARTWORK_MIRROR_RATIO,
}: {
  coverArtId: string;
  active: boolean;
  playing: boolean;
  children: ReactNode;
  halo: ReactNode;
  scale?: number;
  mirrorRatio?: number;
}) {
  const element = useRef<HTMLDivElement>(null);
  const [intersects, setIntersects] = useState(true);
  const [foreground, setForeground] = useState(
    document.visibilityState !== "hidden",
  );
  const [resumeRevision, setResumeRevision] = useState(0);
  const reduced = useReducedMotion() ?? false;
  const mode = playing && !reduced ? "dynamic" : "static";
  const modeRef = useRef<"dynamic" | "static">(mode);
  modeRef.current = mode;
  const [clips, setClips] = useState<DynamicCoverHandle[]>([]);
  const [displayId, setDisplayId] = useState<string>();
  const [nativeMotion, setNativeMotion] = useState({
    mode: "static",
    allowed: false,
  });
  const display = useRef<DynamicCoverHandle | undefined>(undefined);
  const leases = useRef(new Set<DynamicCoverHandle>());
  const currentCover = useRef(coverArtId);
  currentCover.current = coverArtId;
  const visible = active && intersects && foreground;

  useEffect(() => {
    let disposed = false;
    let nativeActive = true;
    const update = () => {
      if (disposed) return;
      const foreground = nativeActive && document.visibilityState !== "hidden";
      setForeground(foreground);
      // WebKit may pause media without changing our last rendered visibility.
      // An explicit resume must retry playback even if canMove stays true.
      if (foreground) setResumeRevision((revision) => revision + 1);
    };
    document.addEventListener("visibilitychange", update);
    window.addEventListener("pageshow", update);
    window.addEventListener("focus", update);
    const appStateHandle = Capacitor.isNativePlatform()
      ? App.addListener("appStateChange", ({ isActive }) => {
          nativeActive = isActive;
          update();
        }).catch((error: unknown) => {
          console.warn("[ImmersiveArtwork] App state listener failed", error);
        })
      : undefined;
    const observer =
      typeof IntersectionObserver !== "undefined"
        ? new IntersectionObserver(([entry]) => {
            setIntersects(entry.isIntersecting);
          })
        : undefined;
    if (element.current) observer?.observe(element.current);
    return () => {
      disposed = true;
      document.removeEventListener("visibilitychange", update);
      window.removeEventListener("pageshow", update);
      window.removeEventListener("focus", update);
      appStateHandle?.then((handle) => handle?.remove()).catch(() => {});
      observer?.disconnect();
    };
  }, []);

  useEffect(() => {
    if (!visible || !coverArtId) return;
    let canceled = false;
    let timer: ReturnType<typeof setTimeout>;
    let demand: Demand;
    let requestedMode: string | undefined;
    let candidate: DynamicCoverHandle | undefined;
    const release = (clip: DynamicCoverHandle) => {
      leases.current.delete(clip);
      clip.release().catch(() => {});
    };
    const poll = async () => {
      try {
        const mode = modeRef.current;
        const result = await dynamicCover.acquire({
          coverArtId,
          format: "any",
          mode,
        });
        if (canceled) {
          if (result.status === "ready") await result.release();
          return;
        }
        setNativeMotion({
          mode,
          allowed:
            result.motionAllowed ??
            (result.status === "ready" && result.stage !== "static"),
        });
        if (result.status === "ready") {
          const current =
            candidate && leases.current.has(candidate)
              ? candidate
              : display.current;
          if (
            current?.assetId === result.assetId ||
            (current && rank[result.stage] < rank[current.stage])
          ) {
            await result.release();
          } else {
            if (candidate && candidate !== display.current) release(candidate);
            candidate = result;
            leases.current.add(result);
            setClips(display.current ? [display.current, result] : [result]);
          }
        }
        // Explicit intent is separate from acquire. The native producer checks
        // existing assets before deciding whether any work is actually needed.
        if (!demand || requestedMode !== mode) {
          const next = await dynamicCover.requestGeneration({
            coverArtId,
            mode,
          });
          if (canceled) {
            await next?.release();
            return;
          }
          const old = demand;
          demand = next;
          requestedMode = mode;
          await old?.release();
        }
      } catch {
        // Original artwork remains usable while the native host is unavailable.
      } finally {
        if (!canceled) timer = setTimeout(poll, 1000);
      }
    };
    poll();
    return () => {
      canceled = true;
      clearTimeout(timer);
      demand?.release().catch(() => {});
      for (const clip of leases.current) release(clip);
      display.current = undefined;
      setDisplayId(undefined);
      setClips([]);
    };
  }, [visible, coverArtId]);

  const canMove =
    visible &&
    playing &&
    !reduced &&
    nativeMotion.mode === "dynamic" &&
    nativeMotion.allowed;
  // biome-ignore lint/correctness/useExhaustiveDependencies: Resume events and clip mounts must retry even when canMove is unchanged.
  useEffect(() => {
    // Include the resume signal and actual elements: neither an unchanged
    // permission nor an unchanged asset ID proves the video is still playing.
    const cleanups: (() => void)[] = [];
    for (const video of element.current?.querySelectorAll("video") ?? []) {
      if (!canMove || video.dataset.stage === "static") {
        video.pause();
        continue;
      }
      let disposed = false;
      let pending = false;
      let attempts = 0;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const delays = [300, 1000, 2500];
      const retry = () => {
        if (disposed || timer || attempts > delays.length) return;
        timer = setTimeout(
          () => {
            timer = undefined;
            play();
          },
          delays[Math.max(0, attempts - 1)],
        );
      };
      const play = () => {
        if (disposed || pending || !video.paused || attempts > delays.length)
          return;
        pending = true;
        attempts += 1;
        video
          .play()
          .catch((error: unknown) => {
            if (!disposed && attempts > delays.length) {
              console.warn("[ImmersiveArtwork] Video resume failed", error);
            }
          })
          .finally(() => {
            pending = false;
            if (video.paused) retry();
          });
      };
      const didPlay = () => {
        attempts = 0;
        clearTimeout(timer);
        timer = undefined;
      };
      video.addEventListener("canplay", play);
      video.addEventListener("pause", retry);
      video.addEventListener("playing", didPlay);
      play();
      cleanups.push(() => {
        disposed = true;
        clearTimeout(timer);
        video.removeEventListener("canplay", play);
        video.removeEventListener("pause", retry);
        video.removeEventListener("playing", didPlay);
      });
    }
    return () => {
      for (const cleanup of cleanups) cleanup();
    };
  }, [canMove, clips, resumeRevision]);

  function ready(clip: DynamicCoverHandle, video: HTMLVideoElement) {
    if (!leases.current.has(clip) || clip.coverArtId !== currentCover.current)
      return;
    const old = display.current;
    display.current = clip;
    setDisplayId(clip.leaseId);
    setClips([clip]);
    // Updating clips runs the playback effect after this element is mounted.
    if (!canMove || clip.stage === "static") video.pause();
    if (old && old !== clip) {
      leases.current.delete(old);
      old.release().catch(() => {});
    }
  }

  const extendedSize = 1 + 2 * mirrorRatio;
  const offsetPercent = `-${(mirrorRatio * 100).toFixed(4)}%`;
  const extendedSizePercent = `${(extendedSize * 100).toFixed(4)}%`;
  const centerInset = `${((mirrorRatio / extendedSize) * 100).toFixed(4)}%`;
  const mirrorMask = useMemo(
    () => createMirrorEdgeMask(mirrorRatio),
    [mirrorRatio],
  );

  return (
    <div
      ref={element}
      className="relative isolate size-full aspect-square transition-transform duration-500 ease-out"
      style={{
        transform: `scale(${scale})`,
        transformOrigin: "center center",
      }}
    >
      {/* Layer 1: Defocus cushion directly under the artwork feather zone */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute z-[1] select-none"
        style={{
          left: offsetPercent,
          top: offsetPercent,
          width: extendedSizePercent,
          height: extendedSizePercent,
          ...mirrorMask,
        }}
      >
        <div className="size-full blur-2xl opacity-90 scale-105">{halo}</div>
      </div>

      {/* Layer 2: Extended artwork container (Mirrored perimeter + Pristine central artwork) */}
      <div
        className="pointer-events-none absolute z-[2]"
        style={{
          left: offsetPercent,
          top: offsetPercent,
          width: extendedSizePercent,
          height: extendedSizePercent,
          ...mirrorMask,
        }}
      >
        {/* Mirrored perimeter reflections: 8 directions, matching edge pixels 1:1 */}
        <div
          className="pointer-events-none absolute select-none z-[1]"
          style={{ inset: centerInset }}
        >
          <MirroredPerimeter halo={halo} mirrorRatio={mirrorRatio} />
        </div>

        {/* Central original artwork: 100% crisp, unclipped corners, 100% opaque */}
        <div
          className="pointer-events-auto absolute overflow-hidden z-[2]"
          style={{ inset: centerInset }}
        >
          {children}
          {clips
            .filter((clip) => clip.coverArtId === coverArtId)
            .map((clip) => (
              <video
                key={clip.leaseId}
                src={clip.src}
                muted
                playsInline
                loop
                preload="auto"
                aria-hidden="true"
                data-stage={clip.stage}
                className="pointer-events-none absolute inset-0 size-full object-cover transition-opacity duration-1000 ease-in-out"
                style={{ opacity: displayId === clip.leaseId ? 1 : 0 }}
                onLoadedData={(event) => ready(clip, event.currentTarget)}
                onError={() => {
                  leases.current.delete(clip);
                  clip.release().catch(() => {});
                  if (display.current === clip) {
                    display.current = undefined;
                    setDisplayId(undefined);
                  }
                  setClips((items) => items.filter((item) => item !== clip));
                }}
              />
            ))}
        </div>
      </div>
    </div>
  );
}
