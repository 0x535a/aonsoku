export type ArtworkHaloVariant = "ambient" | "cushion";

const cushionStops = [
  [0, 0],
  [0.04, 0.12],
  [0.1, 0.45],
  [0.18, 0.85],
  [0.26, 1],
  [0.74, 1],
  [0.82, 0.85],
  [0.9, 0.45],
  [0.96, 0.12],
  [1, 0],
] as const;

/**
 * A bounded, separable Gaussian made only of image draws. Unlike CSS filters
 * or context.filter, this also works in WebKit without filter support. No pixel
 * reads or exports: ordinary cross-origin <img> sources can taint these canvases
 * without preventing blur, masks or display.
 */
export function createArtworkHaloRenderer(canvas: HTMLCanvasElement) {
  const scaled = document.createElement("canvas");
  const horizontal = document.createElement("canvas");
  const blurred = document.createElement("canvas");
  const context = canvas.getContext("2d");
  const scaledContext = scaled.getContext("2d");
  const horizontalContext = horizontal.getContext("2d");
  const blurredContext = blurred.getContext("2d");

  function blurPass(
    target: CanvasRenderingContext2D,
    source: HTMLCanvasElement,
    sigma: number,
    vertical: boolean,
  ) {
    const samples = 24;
    let total = 0;
    for (let i = 0; i <= samples; i++) {
      const distance = (i / samples) * 6 - 3;
      total += Math.exp(-(distance * distance) / 2);
    }
    target.clearRect(0, 0, source.width, source.height);
    target.globalCompositeOperation = "lighter";
    for (let i = 0; i <= samples; i++) {
      const distance = (i / samples) * 6 - 3;
      target.globalAlpha = Math.exp(-(distance * distance) / 2) / total;
      target.drawImage(
        source,
        vertical ? 0 : distance * sigma,
        vertical ? distance * sigma : 0,
      );
    }
    target.globalAlpha = 1;
    target.globalCompositeOperation = "source-over";
  }

  return {
    paint(source: HTMLCanvasElement, variant: ArtworkHaloVariant) {
      if (!context || !scaledContext || !horizontalContext || !blurredContext)
        return;
      const size = source.width;
      const cssSize = source.clientWidth;
      if (!cssSize || !size) return;
      for (const buffer of [canvas, scaled, horizontal, blurred]) {
        if (buffer.width !== size || buffer.height !== size) {
          buffer.width = buffer.height = size;
        }
      }

      scaledContext.clearRect(0, 0, size, size);
      const sourceScale = variant === "ambient" ? 1.1 : 1;
      const sourceInset = ((1 - sourceScale) * size) / 2;
      scaledContext.drawImage(
        source,
        sourceInset,
        sourceInset,
        size * sourceScale,
        size * sourceScale,
      );
      const blur = variant === "ambient" ? (innerWidth >= 640 ? 96 : 72) : 24;
      const sigma = (blur * size) / cssSize;
      blurPass(horizontalContext, scaled, sigma, false);
      blurPass(blurredContext, horizontal, sigma, true);

      context.clearRect(0, 0, size, size);
      context.globalAlpha = variant === "ambient" ? 0.65 : 0.95;
      // Preserve the existing scale-106 outside the blur and inside the mask.
      context.drawImage(
        blurred,
        -size * 0.03,
        -size * 0.03,
        size * 1.06,
        size * 1.06,
      );
      context.globalAlpha = 1;
      context.globalCompositeOperation = "destination-in";
      if (variant === "ambient") {
        const mask = context.createRadialGradient(
          size / 2,
          size / 2,
          0,
          size / 2,
          size / 2,
          size / 2,
        );
        for (const [stop, alpha] of [
          [0.18, 1],
          [0.38, 0.85],
          [0.62, 0.5],
          [0.84, 0.15],
          [0.98, 0],
        ]) {
          mask.addColorStop(stop, `rgba(0,0,0,${alpha})`);
        }
        context.fillStyle = mask;
        context.fillRect(0, 0, size, size);
      } else {
        for (const vertical of [false, true]) {
          const mask = context.createLinearGradient(
            0,
            0,
            vertical ? 0 : size,
            vertical ? size : 0,
          );
          for (const [stop, alpha] of cushionStops) {
            mask.addColorStop(stop, `rgba(0,0,0,${alpha})`);
          }
          context.fillStyle = mask;
          context.fillRect(0, 0, size, size);
        }
      }
      context.globalCompositeOperation = "source-over";
    },
    dispose() {
      for (const buffer of [canvas, scaled, horizontal, blurred]) {
        buffer.width = buffer.height = 0;
      }
    },
  };
}
