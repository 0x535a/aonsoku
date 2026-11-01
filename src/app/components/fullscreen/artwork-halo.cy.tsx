import { useState } from "react";
import { ArtworkHalo } from "./artwork-halo";
import { createArtworkHaloRenderer } from "./artwork-halo-renderer";

const colorImage = (color: string) =>
  `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><path fill="${color}" d="M0 0h100v100H0z"/></svg>`)}`;

function pixel(canvas: HTMLCanvasElement, x: number, y: number) {
  return Array.from(canvas.getContext("2d")!.getImageData(x, y, 1, 1).data);
}

function Fixture() {
  const [color, setColor] = useState("red");
  const [size, setSize] = useState(720);
  const [progress, setProgress] = useState(0);
  return (
    <>
      <div style={{ width: size, height: size }}>
        <ArtworkHalo variant="ambient">
          <img alt="" src={colorImage(color)} className="size-full" />
        </ArtworkHalo>
      </div>
      <button onClick={() => setColor("blue")}>change cover</button>
      <button onClick={() => setSize(180)}>resize</button>
      <button onClick={() => setProgress(progress + 1)}>
        progress {progress}
      </button>
    </>
  );
}

describe("rasterized artwork halos", () => {
  it("follows loaded covers and size changes without repainting for player updates", () => {
    cy.mount(<Fixture />);
    cy.get<HTMLCanvasElement>('[data-artwork-halo="ambient"]').should(
      ($canvas) => {
        const canvas = $canvas[0];
        expect(canvas.width).to.equal(256);
        const center = pixel(canvas, 128, 128);
        expect(center[0]).to.be.greaterThan(220);
        expect(center[3]).to.be.within(150, 175);
        expect(pixel(canvas, 0, 0)[3]).to.equal(0);
        expect(getComputedStyle(canvas).filter).to.equal("none");
        expect(getComputedStyle(canvas).maskImage).to.equal("none");
      },
    );
    cy.contains("change cover").click();
    cy.get<HTMLCanvasElement>('[data-artwork-halo="ambient"]').should(
      ($canvas) => {
        const center = pixel($canvas[0], 128, 128);
        expect(center[2]).to.be.greaterThan(220);
        expect(center[0]).to.be.lessThan(10);
      },
    );
    cy.contains("resize").click();
    cy.get<HTMLCanvasElement>('[data-artwork-halo="ambient"]').should(
      ($canvas) => {
        const canvas = $canvas[0];
        const ratio = canvas.ownerDocument.defaultView!.devicePixelRatio;
        expect(canvas.clientWidth).to.equal(180);
        expect(canvas.width).to.equal(Math.min(256, Math.round(180 * ratio)));
        const center = Math.floor(canvas.width / 2);
        expect(pixel(canvas, center, center)[2]).to.be.greaterThan(220);
      },
    );
    cy.get<HTMLCanvasElement>('[data-artwork-halo="ambient"]').then(
      ($canvas) => {
        cy.spy($canvas[0].getContext("2d")!, "drawImage").as("haloPaint");
      },
    );
    cy.contains("progress 0").click();
    cy.contains("progress 1").should("be.visible");
    // Covers/source transitions have settled; normal player updates stay idle.
    cy.wait(100);
    cy.get("@haloPaint").should("not.have.been.called");
  });

  it("blurs an edge and bakes the intersected cushion feather into alpha", () => {
    cy.document().then((doc) => {
      const source = doc.createElement("canvas");
      source.width = source.height = 200;
      source.style.width = source.style.height = "200px";
      doc.body.append(source);
      const context = source.getContext("2d")!;
      context.fillStyle = "red";
      context.fillRect(0, 0, 100, 200);
      context.fillStyle = "blue";
      context.fillRect(100, 0, 100, 200);
      const output = doc.createElement("canvas");
      const renderer = createArtworkHaloRenderer(output);
      renderer.paint(source, "cushion");
      const center = pixel(output, 100, 100);
      expect(center[0]).to.be.within(90, 165);
      expect(center[2]).to.be.within(90, 165);
      expect(center[3]).to.be.within(230, 250);
      expect(pixel(output, 20, 100)[3]).to.be.greaterThan(
        pixel(output, 20, 20)[3],
      );
      expect(pixel(output, 0, 0)[3]).to.equal(0);
      renderer.dispose();
      expect(output.width).to.equal(0);
      source.remove();
    });
  });

  it("can blur and mask a tainted cross-origin cover without reading pixels", () => {
    cy.intercept("GET", "https://halo-fixture.invalid/cover.svg", {
      headers: { "content-type": "image/svg+xml" },
      body: '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><path fill="red" d="M0 0h100v100H0z"/></svg>',
    });
    cy.document().then(
      (doc) =>
        new Cypress.Promise<void>((resolve, reject) => {
          const image = new Image();
          image.onerror = () => reject(new Error("fixture image did not load"));
          image.onload = () => {
            const source = doc.createElement("canvas");
            source.width = source.height = 200;
            source.style.width = source.style.height = "200px";
            doc.body.append(source);
            source.getContext("2d")!.drawImage(image, 0, 0, 200, 200);
            expect(() => pixel(source, 100, 100)).to.throw();
            const output = doc.createElement("canvas");
            const renderer = createArtworkHaloRenderer(output);
            expect(() => renderer.paint(source, "ambient")).not.to.throw();
            expect(output.width).to.equal(200);
            expect(() => pixel(output, 100, 100)).to.throw();
            renderer.dispose();
            source.remove();
            resolve();
          };
          image.src = "https://halo-fixture.invalid/cover.svg";
        }),
    );
  });

  it("renders a side-by-side visual comparison with the previous CSS glow", () => {
    const cover = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600"><defs><linearGradient id="sky" x2="0" y2="1"><stop stop-color="#263854"/><stop offset=".5" stop-color="#d18a85"/><stop offset="1" stop-color="#edbd74"/></linearGradient></defs><path fill="url(#sky)" d="M0 0h600v600H0z"/><circle fill="#ffdf96" cx="330" cy="360" r="100"/><path fill="#363148" d="M0 470l120-90 150 100 100-60 230 80v100H0z"/></svg>')}`;
    cy.mount(
      <div
        style={{ display: "flex", gap: 16, background: "#5c5660", padding: 20 }}
      >
        {["previous CSS", "rasterized"].map((label) => (
          <div key={label}>
            <p style={{ color: "white" }}>{label}</p>
            <div style={{ width: 600, height: 600, position: "relative" }}>
              {label === "previous CSS" ? (
                <div
                  className="size-full"
                  style={{
                    maskImage:
                      "radial-gradient(circle closest-side at center, black 18%, rgba(0,0,0,.85) 38%, rgba(0,0,0,.5) 62%, rgba(0,0,0,.15) 84%, transparent 98%)",
                  }}
                >
                  <div
                    className="size-full"
                    style={{
                      filter: "blur(96px)",
                      opacity: 0.65,
                      transform: "scale(1.06)",
                    }}
                  >
                    <img
                      alt=""
                      src={cover}
                      className="size-full"
                      style={{ transform: "scale(1.1)" }}
                    />
                  </div>
                </div>
              ) : (
                <ArtworkHalo variant="ambient">
                  <img alt="" src={cover} className="size-full" />
                </ArtworkHalo>
              )}
            </div>
          </div>
        ))}
      </div>,
    );
    cy.get<HTMLCanvasElement>('[data-artwork-halo="ambient"]').should(
      ($canvas) => {
        expect(pixel($canvas[0], 128, 128)[3]).to.be.greaterThan(100);
      },
    );
    cy.screenshot("artwork-halo-comparison");
  });
});
