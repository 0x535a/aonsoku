import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const root = fileURLToPath(new URL("../../", import.meta.url));
const pluralSuffix = /_(zero|one|two|few|many|other)$/;
const tokens = (value) =>
  (value.match(/\{\{[^{}]+\}\}|%[sd]/g) ?? []).sort().join("|");

export function flatten(value, prefix = "", result = {}) {
  for (const [key, entry] of Object.entries(value)) {
    const name = prefix ? `${prefix}.${key}` : key;
    if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      flatten(entry, name, result);
    } else {
      result[name] = entry;
    }
  }
  return result;
}

export function checkCatalog(locale, reference, catalog, shared = {}) {
  const errors = [];
  const pluralCategories = new Intl.PluralRules(locale).resolvedOptions()
    .pluralCategories;
  const required = new Set(Object.keys(reference));
  for (const key of Object.keys(reference)) {
    if (!key.endsWith("_other")) continue;
    for (const category of pluralCategories) {
      required.add(key.replace(/_other$/, `_${category}`));
    }
  }
  for (const key of required) {
    const source =
      reference[key] ?? reference[key.replace(pluralSuffix, "_other")];
    const value = catalog[key];
    if (typeof value !== "string" || value.trim() === "") {
      errors.push(`${locale}: missing or empty ${key}`);
      continue;
    }
    if (tokens(value) !== tokens(source)) {
      errors.push(`${locale}: interpolation mismatch in ${key}`);
    }
    if (
      locale !== "en" &&
      value === source &&
      !(shared["*"] ?? []).includes(source) &&
      !(shared[locale] ?? []).includes(key)
    ) {
      errors.push(`${locale}: untranslated ${key}`);
    }
  }
  // Check additional locale-specific plural forms as well as reference keys.
  for (const [key, value] of Object.entries(catalog)) {
    if (required.has(key)) continue;
    const source = reference[key.replace(pluralSuffix, "_other")];
    if (
      source &&
      (typeof value !== "string" || tokens(value) !== tokens(source))
    ) {
      errors.push(`${locale}: interpolation mismatch in ${key}`);
    }
  }
  return errors;
}

export function translationPatterns(source) {
  const file = ts.createSourceFile(
    "source.tsx",
    source,
    ts.ScriptTarget.Latest,
    true,
  );
  const constants = new Map();
  const collect = (node) => {
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer
    ) {
      constants.set(node.name.text, node.initializer);
    }
    ts.forEachChild(node, collect);
  };
  collect(file);
  const combine = (left, right) => left.flatMap((a) => right.map((b) => a + b));
  const resolve = (node, seen = new Set()) => {
    if (ts.isStringLiteralLike(node)) return [node.text];
    if (ts.isParenthesizedExpression(node))
      return resolve(node.expression, seen);
    if (ts.isConditionalExpression(node)) {
      return [
        ...resolve(node.whenTrue, seen),
        ...resolve(node.whenFalse, seen),
      ];
    }
    if (
      ts.isIdentifier(node) &&
      constants.has(node.text) &&
      !seen.has(node.text)
    ) {
      return resolve(constants.get(node.text), new Set([...seen, node.text]));
    }
    if (ts.isTemplateExpression(node)) {
      return node.templateSpans.reduce(
        (parts, span) =>
          combine(parts, resolve(span.expression, seen)).map(
            (part) => part + span.literal.text,
          ),
        [node.head.text],
      );
    }
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.PlusToken
    ) {
      return combine(resolve(node.left, seen), resolve(node.right, seen));
    }
    return ["*"];
  };
  const patterns = new Set();
  const visit = (node) => {
    if (
      ts.isCallExpression(node) &&
      ["t", "i18n.t", "i18next.t"].includes(node.expression.getText(file)) &&
      node.arguments[0]
    ) {
      for (const pattern of resolve(node.arguments[0])) {
        if (pattern !== "*") patterns.add(pattern);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  return [...patterns];
}

export function hasTranslation(pattern, reference) {
  if (!pattern.includes("*")) {
    return pattern in reference || `${pattern}_other` in reference;
  }
  const expression = new RegExp(
    `^${pattern
      .split("*")
      .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      .join(".*")}$`,
  );
  return Object.keys(reference).some((key) => expression.test(key));
}

export function checkProject(projectRoot = root) {
  const localeDirectory = path.join(projectRoot, "src/i18n/locales");
  const read = (name) => JSON.parse(readFileSync(name, "utf8"));
  const reference = flatten(read(path.join(localeDirectory, "en.json")));
  const shared = read(
    path.join(projectRoot, "scripts/i18n/shared-translations.json"),
  );
  const errors = [];
  const locales = readdirSync(localeDirectory).filter((name) =>
    name.endsWith(".json"),
  );
  for (const name of locales) {
    errors.push(
      ...checkCatalog(
        name.slice(0, -5),
        reference,
        flatten(read(path.join(localeDirectory, name))),
        shared,
      ),
    );
  }
  const scan = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const name = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(name);
      else if (/\.[cm]?[jt]sx?$/.test(name) && !/\.(test|spec)\./.test(name)) {
        for (const pattern of translationPatterns(readFileSync(name, "utf8"))) {
          if (!hasTranslation(pattern, reference)) {
            errors.push(
              `${path.relative(projectRoot, name)}: unknown translation ${pattern}`,
            );
          }
        }
      }
    }
  };
  scan(path.join(projectRoot, "src"));
  scan(path.join(projectRoot, "electron"));
  return {
    errors,
    localeCount: locales.length,
    keyCount: Object.keys(reference).length,
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const { errors, localeCount, keyCount } = checkProject();
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exitCode = 1;
  } else {
    console.log(
      `i18n: ${localeCount} locales, ${keyCount} reference keys; catalogs and source calls checked.`,
    );
  }
}
