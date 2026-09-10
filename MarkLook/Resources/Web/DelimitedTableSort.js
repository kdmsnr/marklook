(() => {
  "use strict";

  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const decimalPattern = /^[+-]?(?:(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;

  function numericValue(text) {
    if (!decimalPattern.test(text)) return null;
    const normalized = text.replaceAll(",", "");
    // Preserve integer precision for identifiers and counts beyond Number.MAX_SAFE_INTEGER.
    if (/^[+-]?\d+$/.test(normalized)) return BigInt(normalized);
    const value = Number(normalized);
    return Number.isFinite(value) ? value : null;
  }

  function nextSort(current, column) {
    if (current?.column !== column) return { column, direction: "ascending" };
    if (current.direction === "ascending") return { column, direction: "descending" };
    return null;
  }

  function isSortableColumn(column) {
    // -1 selects the original row number; data columns start at zero.
    return Number.isInteger(column) && column >= -1;
  }

  // This module handles values and indices only; it never reads or operates a UI.
  function orderedIndices(values, direction) {
    const entries = values.map((value, index) => {
      const text = (value ?? "").trim();
      return { index, text, numeric: text === "" ? null : numericValue(text) };
    });
    if (!direction) return entries.map(entry => entry.index);
    const numericColumn = entries.every(entry => entry.text === "" || entry.numeric !== null);
    const sign = direction === "descending" ? -1 : 1;
    entries.sort((left, right) => {
      // Empty and missing cells stay last in both directions.
      if ((left.text === "") !== (right.text === "")) return left.text === "" ? 1 : -1;
      let comparison = 0;
      if (left.text !== "" && right.text !== "") {
        comparison = numericColumn
          ? (left.numeric < right.numeric ? -1 : left.numeric > right.numeric ? 1 : 0)
          : collator.compare(left.text, right.text);
      }
      return comparison * sign || left.index - right.index;
    });
    return entries.map(entry => entry.index);
  }

  globalThis.marklookTableSort = Object.freeze({ nextSort, orderedIndices, isSortableColumn });
})();
