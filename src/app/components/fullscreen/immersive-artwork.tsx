import { useReducedMotion } from "framer-motion";
import { type ReactNode, useEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { type DynamicCoverHandle, dynamicCover } from "@/native/artwork";

const rank = { static: 0, camera: 1, depth: 2 };

// A wide, smooth S-curve feather that dissolves the artwork perimeter into
// the underlying bokeh cushion and expansive ambient background, while
// keeping the central 64% crisp, focused, and vibrant (referencing iPadOS presentation).
const edgeFade =
  "transparent 0%, rgba(0,0,0,0.02) 2%, rgba(0,0,0,0.12) 5%, rgba(0,0,0,0.35) 9%, rgba(0,0,0,0.68) 13.5%, black 18%, black 82%, rgba(0,0,0,0.68) 86.5%, rgba(0,0,0,0.35) 91%, rgba(0,0,0,0.12) 95%, rgba(0,0,0,0.02) 98%, transparent 100%";
const edgeMask = `linear-gradient(to right, ${edgeFade}), linear-gradient(to bottom, ${edgeFade})`;

// Defocus cushion mask directly behind the foreground feather zone
const cushionFade =
  "transparent 0%, rgba(0,0,0,0.15) 3%, rgba(0,0,0,0.5) 8%, rgba(0,0,0,0.85) 14%, black 20%, black 80%, rgba(0,0,0,0.85) 86%, rgba(0,0,0,0.5) 92%, rgba(0,0,0,0.15) 97%, transparent 100%";
const cushionMask = `linear-gradient(to right, ${cushionFade}), linear-gradient(to bottom, ${cushionFade})`;

type Demand = Awaited<ReturnType<typeof dynamicCover.requestGeneration>>;

/** A square display mask over leased files. It never requests pixel dimensions. */
export function ImmersiveArtwork({
  coverArtId,
  active,
  playing,
  children,
  halo,
}: {
  coverArtId: string;
  active: boolean;
  playing: boolean;
  children: ReactNode;
  halo: ReactNode;
}) {
  const element = useRef<HTMLDivElement>(null);
  const [intersects, setIntersects] = useState(true);
  const [foreground, setForeground] = useState(
    document.visibilityState !== "hidden",
  );
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
    const update = () => setForeground(document.visibilityState !== "hidden");
    document.addEventListener("visibilitychange", update);
    const observer =
      typeof IntersectionObserver !== "undefined"
        ? new IntersectionObserver(([entry]) => {
            setIntersects(entry.isIntersecting);
          })
        : undefined;
    if (element.current) observer?.observe(element.current);
    return () => {
      document.removeEventListener("visibilitychange", update);
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
  useEffect(() => {
    for (const video of element.current?.querySelectorAll("video") ?? []) {
      if (canMove && video.dataset.stage !== "static")
        video.play().catch(() => {});
      else video.pause();
    }
  }, [canMove]);

  function ready(clip: DynamicCoverHandle, video: HTMLVideoElement) {
    if (!leases.current.has(clip) || clip.coverArtId !== currentCover.current)
      return;
    const old = display.current;
    display.current = clip;
    setDisplayId(clip.leaseId);
    setClips([clip]);
    if (canMove && clip.stage !== "static") video.play().catch(() => {});
    else video.pause();
    if (old && old !== clip) {
      leases.current.delete(old);
      old.release().catch(() => {});
    }
  }

  return (
    <div ref={element} className="relative isolate size-full aspect-square">
      {/* Layer 0: Expansive ambient atmosphere (iPad-style large-area soft blur) */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute -inset-[55%] sm:-inset-[70%] z-0 select-none"
        style={{
          maskImage:
            "radial-gradient(circle closest-side at center, black 22%, rgba(0,0,0,0.85) 42%, rgba(0,0,0,0.52) 65%, rgba(0,0,0,0.18) 84%, transparent 98%)",
          WebkitMaskImage:
            "radial-gradient(circle closest-side at center, black 22%, rgba(0,0,0,0.85) 42%, rgba(0,0,0,0.52) 65%, rgba(0,0,0,0.18) 84%, transparent 98%)",
        }}
      >
        <div
          className={cn(
            "size-full blur-[64px] sm:blur-[84px] transition-opacity duration-1000",
            canMove ? "animate-dreamy-breathe" : "opacity-50 scale-102",
          )}
        >
          <div className="size-full scale-110">{halo}</div>
        </div>
      </div>

      {/* Layer 1: Defocus cushion directly under the artwork feather zone */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute -inset-[10%] z-[1] select-none"
        style={{
          maskImage: cushionMask,
          maskComposite: "intersect",
          WebkitMaskImage: cushionMask,
          WebkitMaskComposite: "source-in",
        }}
      >
        <div className="size-full blur-2xl opacity-90 scale-105">{halo}</div>
      </div>

      {/* Layer 2: Foreground artwork with wide, dreamy transition into the blur */}
      <div
        className="relative z-[2] size-full overflow-hidden"
        style={{
          maskImage: edgeMask,
          maskComposite: "intersect",
          WebkitMaskImage: edgeMask,
          WebkitMaskComposite: "source-in",
        }}
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
  );
}
