"use strict";

// Pure value/ordering tests: no browser, DOM, app host, or UI automation.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const context = vm.createContext({ Intl });
const source = fs.readFileSync(path.join(__dirname, "../../MarkLook/Resources/Web/DelimitedTableSort.js"), "utf8");
vm.runInContext(source, context);
const sorting = context.marklookTableSort;
const sorted = (values, direction = "ascending") =>
  Array.from(sorting.orderedIndices(values, direction), index => values[index]);

test("numeric columns sort negative numbers and decimals numerically in both directions", () => {
  const values = ["10", "2", "-2", "1.2", "-10", ".5", "0", "-.5"];
  const ascending = ["-10", "-2", "-.5", "0", ".5", "1.2", "2", "10"];
  assert.deepEqual(sorted(values), ascending);
  assert.deepEqual(sorted(values, "descending"), ascending.toReversed());
});

test("numeric columns recognize grouping separators and scientific notation", () => {
  assert.deepEqual(sorted(["1,200", "12.5", "1e3", "+20", "-1,500.25"]),
    ["-1,500.25", "12.5", "+20", "1e3", "1,200"]);
});

test("large integers retain precision beyond the JavaScript safe integer range", () => {
  assert.deepEqual(sorted(["9007199254740993", "9007199254740992", "-9007199254740993", "1.5"]),
    ["-9007199254740993", "1.5", "9007199254740992", "9007199254740993"]);
});

test("equal numeric values keep source order in both directions", () => {
  const values = ["2.0", "02", "2", "+2", "1"];
  assert.deepEqual(sorted(values), ["1", "2.0", "02", "2", "+2"]);
  assert.deepEqual(sorted(values, "descending"), values);
});

test("empty and missing cells remain last in both directions", () => {
  const values = ["", "2", undefined, "1", "  ", null];
  assert.deepEqual(sorted(values), ["1", "2", "", undefined, "  ", null]);
  assert.deepEqual(sorted(values, "descending"), ["2", "1", "", undefined, "  ", null]);
});

test("text columns use natural order and retain case-insensitive ties", () => {
  const values = ["file10", "File2", "file1", "file2"];
  assert.deepEqual(sorted(values), ["file1", "File2", "file2", "file10"]);
  assert.deepEqual(sorted(values, "descending"), ["file10", "File2", "file2", "file1"]);
});

test("Japanese text and surrounding whitespace sort without changing cell content", () => {
  assert.deepEqual(sorted(["  い  ", "あ", "う"]), ["あ", "  い  ", "う"]);
});

test("a mixed text column does not coerce hexadecimal or other text into numbers", () => {
  assert.deepEqual(sorted(["10", "0x10", "2"]), ["0x10", "2", "10"]);
});

test("clearing the sort returns source indices without mutating the input", () => {
  const values = ["C", "A", "B"];
  assert.deepEqual(sorted(values, null), values);
  assert.deepEqual(sorted(values), ["A", "B", "C"]);
  assert.deepEqual(values, ["C", "A", "B"]);
});

test("the same column cycles ascending, descending, and source order", () => {
  const first = sorting.nextSort(null, 2);
  assert.equal(first.column, 2);
  assert.equal(first.direction, "ascending");
  const second = sorting.nextSort(first, 2);
  assert.equal(second.direction, "descending");
  assert.equal(sorting.nextSort(second, 2), null);
  const different = sorting.nextSort(second, 0);
  assert.equal(different.column, 0);
  assert.equal(different.direction, "ascending");
});

test("empty input and entirely empty columns retain their order", () => {
  assert.deepEqual(sorted([]), []);
  assert.deepEqual(sorted(["", " ", null], "descending"), ["", " ", null]);
});

test("a full 10,000-row preview produces one unique index per record", () => {
  const values = Array.from({ length: 10_000 }, (_, index) => String(index));
  const indices = Array.from(sorting.orderedIndices(values, "descending"));
  assert.equal(indices.length, values.length);
  assert.equal(new Set(indices).size, values.length);
  assert.equal(indices[0], 9_999);
  assert.equal(indices.at(-1), 0);
});
