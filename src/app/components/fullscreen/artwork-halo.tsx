import { type ReactNode, useEffect, useRef } from "react";
import {
  type ArtworkHaloVariant,
  createArtworkHaloRenderer,
} from "./artwork-halo-renderer";
import { renderArtworkRegion } from "./artwork-region-renderer";

/** Static cover glow shared by every runtime; no live DOM blur or halo mask. */
export function ArtworkHalo({
  children,
  variant,
}: {
  children: ReactNode;
  variant: ArtworkHaloVariant;
}) {
  const source = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLCanvasElement>(null);
  const output = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    if (!source.current || !input.current || !output.current) return;
    const renderer = createArtworkHaloRenderer(output.current);
    const stop = renderArtworkRegion(
      input.current,
      source.current,
      0,
      undefined,
      {
        maxSize: 256,
        onFrame: (frame) => renderer.paint(frame, variant),
      },
    );
    return () => {
      stop();
      renderer.dispose();
    };
  }, [variant]);

  return (
    <div aria-hidden="true" className="pointer-events-none relative size-full">
      <canvas
        ref={output}
        className="absolute inset-0 size-full"
        data-artwork-halo={variant}
      />
      <div className="absolute inset-0 size-full opacity-0">
        <canvas ref={input} className="absolute inset-0 size-full" />
        <div ref={source} className="absolute inset-0 size-full">
          {children}
        </div>
      </div>
    </div>
  );
}
