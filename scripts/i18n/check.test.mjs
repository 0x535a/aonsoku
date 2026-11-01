import { readFileSync, readdirSync } from "node:fs";
import i18next from "i18next";
import { describe, expect, it } from "vitest";
import {
  checkCatalog,
  checkProject,
  flatten,
  hasTranslation,
  translationPatterns,
} from "./check.mjs";

describe("i18n validation", () => {
  it("rejects missing translations, empty strings and English copies", () => {
    expect(
      checkCatalog(
        "ja",
        { title: "Title", save: "Save", cancel: "Cancel" },
        { save: "", cancel: "Cancel" },
      ),
    ).toEqual([
      "ja: missing or empty title",
      "ja: missing or empty save",
      "ja: untranslated cancel",
    ]);
  });

  it("checks locale-specific plural forms and interpolation tokens", () => {
    const reference = {
      items_one: "{{count}} item",
      items_other: "{{count}} items",
    };
    expect(
      checkCatalog("ru", reference, {
        items_one: "{{count}} элемент",
        items_other: "{{count}} элемента",
        items_few: "{{total}} элемента",
      }),
    ).toEqual([
      "ru: interpolation mismatch in items_few",
      "ru: missing or empty items_many",
    ]);
    expect(
      checkCatalog("ja", { future: "in %s" }, { future: "%d 後" }),
    ).toEqual(["ja: interpolation mismatch in future"]);
  });

  it("allows explicitly shared names without exempting other English text", () => {
    expect(
      checkCatalog(
        "de",
        { name: "Navidrome", button: "Save" },
        { name: "Navidrome", button: "Save" },
        { "*": ["Navidrome"] },
      ),
    ).toEqual(["de: untranslated button"]);
  });

  it("extracts multiline calls, conditional keys and artwork template keys", () => {
    const patterns = translationPatterns(`
      const prefix = "artwork";
      t("settings.title", { defaultValue: "Settings" });
      t(
        "settings.description"
      );
      t(enabled ? "player.play" : "player.pause");
      t(\`\${prefix}.\${mac ? "macGroup" : "group"}\`);
      t(\`\${prefix}.generation.\${status}\`);
    `);
    expect(patterns).toEqual([
      "settings.title",
      "settings.description",
      "player.play",
      "player.pause",
      "artwork.macGroup",
      "artwork.group",
      "artwork.generation.*",
    ]);
    expect(hasTranslation("items", { items_other: "Items" })).toBe(true);
    expect(
      hasTranslation("artwork.missing", { "artwork.group": "Artwork" }),
    ).toBe(false);
    expect(
      hasTranslation("artwork.generation.*", {
        "artwork.generation.idle": "Idle",
      }),
    ).toBe(true);
  });

  it("keeps every shipped locale and translation call complete", () => {
    expect(checkProject().errors).toEqual([]);
  });

  it("resolves every catalog entry and plural without a fallback language", async () => {
    const directory = new URL("../../src/i18n/locales/", import.meta.url);
    const catalogs = Object.fromEntries(
      readdirSync(directory).map((file) => [
        file.slice(0, -5),
        JSON.parse(readFileSync(new URL(file, directory), "utf8")),
      ]),
    );
    const instance = i18next.createInstance();
    await instance.init({
      fallbackLng: false,
      resources: Object.fromEntries(
        Object.entries(catalogs).map(([locale, translation]) => [
          locale,
          { translation },
        ]),
      ),
    });
    const reference = flatten(catalogs.en);
    for (const locale of Object.keys(catalogs)) {
      const options = { lng: locale, returnDetails: true };
      for (const key of Object.keys(reference)) {
        expect(instance.t(key, options).usedLng, `${locale}: ${key}`).toBe(
          locale,
        );
      }
      for (const key of Object.keys(reference).filter((key) =>
        key.endsWith("_other"),
      )) {
        const base = key.slice(0, -6);
        for (const count of [0, 1, 2, 5, 21, 1.5, 1_000_000]) {
          const result = instance.t(base, { ...options, count });
          expect(result.usedLng, `${locale}: ${base} (${count})`).toBe(locale);
          expect(result.res).not.toBe(base);
        }
      }
    }
    expect(
      instance.t("settings.crossDevice.playback.willContinue", {
        lng: "ja",
        name: "My Mac",
      }),
    ).toBe("My Mac から再生を引き継ぐ");
  });
});
